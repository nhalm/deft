defmodule Deft.Job.RateLimiter do
  @moduledoc """
  Rate limiter with dual token-bucket algorithm for LLM API calls.

  Enforces per-provider rate limits using two token buckets:
  - RPM bucket: Requests per minute (deducts 1 per call)
  - TPM bucket: Tokens per minute (deducts estimated input tokens)

  A call proceeds only when both buckets have sufficient capacity.
  After API response, actual token usage is reconciled with credit-back
  capped at bucket maximum to prevent over-crediting.
  """

  use GenServer
  require Logger

  alias Deft.Provider.Anthropic

  # Provider rate limits (Anthropic Tier 1 defaults)
  # TODO: Move to configuration when providers.md spec is updated
  @default_rpm 50
  @default_tpm 40_000

  # Token estimation heuristic (chars / 4)
  @chars_per_token 4

  defmodule Bucket do
    @moduledoc """
    Token bucket state for rate limiting.
    """
    @type t :: %__MODULE__{
            tokens: float(),
            capacity: float(),
            refill_rate: float(),
            last_refill_at: integer()
          }

    defstruct [:tokens, :capacity, :refill_rate, :last_refill_at]

    @doc """
    Creates a new bucket with given capacity and refill rate.

    ## Parameters
    - capacity: Maximum tokens the bucket can hold
    - refill_rate: Tokens added per second
    """
    def new(capacity, refill_rate) do
      now = System.monotonic_time(:millisecond)

      %__MODULE__{
        tokens: capacity,
        capacity: capacity,
        refill_rate: refill_rate,
        last_refill_at: now
      }
    end

    @doc """
    Refills the bucket based on elapsed time since last refill.

    Returns updated bucket with refilled tokens (capped at capacity).
    """
    def refill(%__MODULE__{} = bucket) do
      now = System.monotonic_time(:millisecond)
      elapsed_ms = now - bucket.last_refill_at
      elapsed_seconds = elapsed_ms / 1000.0

      new_tokens =
        min(
          bucket.tokens + bucket.refill_rate * elapsed_seconds,
          bucket.capacity
        )

      %{bucket | tokens: new_tokens, last_refill_at: now}
    end

    @doc """
    Attempts to deduct tokens from the bucket.

    Returns {:ok, updated_bucket} if sufficient tokens available,
    {:error, :insufficient} otherwise.
    """
    def deduct(%__MODULE__{} = bucket, amount) do
      bucket = refill(bucket)

      if bucket.tokens >= amount do
        {:ok, %{bucket | tokens: bucket.tokens - amount}}
      else
        {:error, :insufficient}
      end
    end

    @doc """
    Credits tokens back to the bucket (capped at capacity).

    Used to reconcile estimated vs actual token usage after API response.
    """
    def credit(%__MODULE__{} = bucket, amount) do
      new_tokens = min(bucket.tokens + amount, bucket.capacity)
      %{bucket | tokens: new_tokens}
    end
  end

  defmodule ProviderBuckets do
    @moduledoc """
    RPM and TPM buckets for a single provider.
    """
    @type t :: %__MODULE__{
            rpm: Bucket.t(),
            tpm: Bucket.t(),
            rpm_original_capacity: float(),
            tpm_original_capacity: float(),
            last_429_at: integer() | nil,
            consecutive_429s: integer(),
            backoff_until: integer() | nil
          }

    defstruct [
      :rpm,
      :tpm,
      :rpm_original_capacity,
      :tpm_original_capacity,
      :last_429_at,
      consecutive_429s: 0,
      backoff_until: nil
    ]

    @doc """
    Creates new buckets for a provider.

    ## Parameters
    - rpm_limit: Requests per minute limit
    - tpm_limit: Tokens per minute limit
    """
    def new(rpm_limit, tpm_limit) do
      %__MODULE__{
        rpm: Bucket.new(rpm_limit, rpm_limit / 60.0),
        tpm: Bucket.new(tpm_limit, tpm_limit / 60.0),
        rpm_original_capacity: rpm_limit,
        tpm_original_capacity: tpm_limit,
        last_429_at: nil
      }
    end

    @doc """
    Reduces bucket capacity by 20% for 429 handling.

    Returns updated buckets with reduced capacity.
    """
    def reduce_capacity(%__MODULE__{} = buckets) do
      new_rpm_capacity = buckets.rpm.capacity * 0.8
      new_tpm_capacity = buckets.tpm.capacity * 0.8

      %{
        buckets
        | rpm: %{
            buckets.rpm
            | capacity: new_rpm_capacity,
              tokens: min(buckets.rpm.tokens, new_rpm_capacity)
          },
          tpm: %{
            buckets.tpm
            | capacity: new_tpm_capacity,
              tokens: min(buckets.tpm.tokens, new_tpm_capacity)
          }
      }
    end

    @doc """
    Restores bucket capacity by 10% toward original capacity.

    Returns updated buckets with increased capacity (capped at original).
    """
    def restore_capacity(%__MODULE__{} = buckets) do
      # Increase by 10% of current capacity
      new_rpm_capacity = min(buckets.rpm.capacity * 1.1, buckets.rpm_original_capacity)
      new_tpm_capacity = min(buckets.tpm.capacity * 1.1, buckets.tpm_original_capacity)

      %{
        buckets
        | rpm: %{buckets.rpm | capacity: new_rpm_capacity},
          tpm: %{buckets.tpm | capacity: new_tpm_capacity}
      }
    end
  end

  # Priority levels (higher number = higher priority)
  @priority_foreman 3
  @priority_runner 2
  @priority_lead 1

  # Starvation protection threshold (milliseconds)
  @starvation_threshold_ms 10_000

  # Queue processing check interval
  @queue_check_interval_ms 1_000

  # 429 handling constants
  @capacity_restore_grace_period_ms 60_000
  @max_backoff_seconds 60

  # Client API

  @doc """
  Starts the RateLimiter GenServer for a specific job.

  ## Parameters
  - opts: Keyword list with required :job_id and optional configuration
    - :job_id - Required job identifier
    - :foreman_pid - Optional Foreman process PID for cost reporting
    - :model - Optional model name for cost tracking (default: "claude-sonnet-4")
    - :time_source - Optional time source function for testing
  """
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    name = via_tuple(job_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Requests permission to make an LLM call.

  Deducts 1 token from RPM bucket and estimated tokens from TPM bucket.
  Blocks until both buckets have capacity (or timeout).

  ## Parameters
  - job_id: The job identifier for the RateLimiter instance
  - provider: Provider name (e.g., "anthropic")
  - messages: List of messages (used for token estimation)
  - caller_type: One of :foreman, :runner, or :lead (determines priority)
  - config: Optional config map (reserved for future use)

  ## Returns
  - {:ok, estimated_tokens} - Permission granted, tokens deducted
  - {:error, reason} - Failed to get permission
  """
  def request(job_id, provider, messages, caller_type \\ :lead, _config \\ %{}) do
    estimated_tokens = estimate_tokens(messages)
    priority = priority_for_caller(caller_type)
    GenServer.call(via_tuple(job_id), {:request, provider, estimated_tokens, priority}, :infinity)
  end

  @doc """
  Reconciles actual token usage after API response.

  Credits back the difference between estimated and actual usage,
  capped at bucket capacity to prevent over-crediting.

  ## Parameters
  - job_id: The job identifier for the RateLimiter instance
  - provider: Provider name
  - estimated_tokens: Tokens that were estimated/deducted
  - actual_usage: Map with :input and :output token counts from API response
  """
  def reconcile(job_id, provider, estimated_tokens, actual_usage) do
    GenServer.cast(via_tuple(job_id), {:reconcile, provider, estimated_tokens, actual_usage})
  end

  @doc """
  Reports a 429 rate limit error for a provider.

  Reduces bucket capacity by 20% and applies exponential backoff.
  Capacity is restored gradually after 60s without 429s.

  ## Parameters
  - job_id: The job identifier for the RateLimiter instance
  - provider: Provider name that returned the 429
  - retry_after: Optional Retry-After header value in seconds
  """
  def report_429(job_id, provider, retry_after \\ nil) do
    GenServer.cast(via_tuple(job_id), {:report_429, provider, retry_after})
  end

  # Private helper for Registry via tuple
  defp via_tuple(job_id) do
    {:via, Registry, {Deft.ProcessRegistry, {:rate_limiter, job_id}}}
  end

  # Server callbacks

  @impl true
  def init(opts) do
    time_source = Keyword.get(opts, :time_source, &System.monotonic_time/1)
    foreman_pid = Keyword.get(opts, :foreman_pid)
    model = Keyword.get(opts, :model, "claude-sonnet-4")

    state = %{
      providers: %{},
      queue: :gb_trees.empty(),
      next_queue_id: 0,
      time_source: time_source,
      foreman_pid: foreman_pid,
      model: model,
      cumulative_cost: 0.0,
      last_cost_report: 0.0
    }

    # Schedule periodic queue processing and starvation check
    schedule_queue_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:request, provider, estimated_tokens, priority}, from, state) do
    state = ensure_provider(state, provider)
    buckets = state.providers[provider]
    now = state.time_source.(:millisecond)

    # Check if provider is in backoff period
    if buckets.backoff_until != nil and now < buckets.backoff_until do
      # In backoff - enqueue the request
      new_state = enqueue_request(state, provider, estimated_tokens, priority, from)
      {:noreply, new_state}
    else
      # Clear backoff if we've passed the backoff period
      buckets =
        if buckets.backoff_until != nil and now >= buckets.backoff_until do
          %{buckets | backoff_until: nil}
        else
          buckets
        end

      state = put_in(state, [:providers, provider], buckets)

      # Try to deduct from both buckets
      with {:ok, rpm_bucket} <- Bucket.deduct(buckets.rpm, 1),
           {:ok, tpm_bucket} <- Bucket.deduct(buckets.tpm, estimated_tokens) do
        # Both buckets have capacity - update state and grant permission
        # Reset consecutive 429s on successful grant
        new_buckets = %{
          buckets
          | rpm: rpm_bucket,
            tpm: tpm_bucket,
            consecutive_429s: 0
        }

        new_state = put_in(state, [:providers, provider], new_buckets)

        {:reply, {:ok, estimated_tokens}, new_state}
      else
        {:error, :insufficient} ->
          # Not enough capacity - enqueue the request
          new_state = enqueue_request(state, provider, estimated_tokens, priority, from)
          {:noreply, new_state}
      end
    end
  end

  @impl true
  def handle_cast({:reconcile, provider, estimated_tokens, actual_usage}, state) do
    state = ensure_provider(state, provider)
    buckets = state.providers[provider]

    # Calculate actual tokens used (input only, since we estimated input tokens)
    actual_tokens = Map.get(actual_usage, :input, estimated_tokens)

    # Credit back the difference (estimated - actual), capped at bucket capacity
    credit_amount = max(0, estimated_tokens - actual_tokens)
    new_tpm_bucket = Bucket.credit(buckets.tpm, credit_amount)

    new_buckets = %{buckets | tpm: new_tpm_bucket}
    new_state = put_in(state, [:providers, provider], new_buckets)

    # Track cost from actual usage
    new_state = track_cost(new_state, actual_usage)

    # Process queue in case capacity became available
    new_state = process_queue(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_429, provider, retry_after}, state) do
    state = ensure_provider(state, provider)
    buckets = state.providers[provider]
    now = state.time_source.(:millisecond)

    # Reduce capacity by 20%
    reduced_buckets = ProviderBuckets.reduce_capacity(buckets)

    # Increment consecutive 429s counter
    consecutive = reduced_buckets.consecutive_429s + 1

    # Calculate exponential backoff: min(2^consecutive, 60) seconds
    backoff_seconds = min(:math.pow(2, consecutive - 1) |> trunc(), @max_backoff_seconds)

    # Use Retry-After header if provided and larger than exponential backoff
    backoff_seconds =
      if retry_after != nil and retry_after > backoff_seconds do
        retry_after
      else
        backoff_seconds
      end

    backoff_until = now + backoff_seconds * 1000

    # Update buckets with 429 tracking
    new_buckets = %{
      reduced_buckets
      | last_429_at: now,
        consecutive_429s: consecutive,
        backoff_until: backoff_until
    }

    new_state = put_in(state, [:providers, provider], new_buckets)

    Logger.warning(
      "Rate limit 429 for provider #{provider}, reduced capacity to #{trunc(new_buckets.rpm.capacity)} RPM, #{trunc(new_buckets.tpm.capacity)} TPM, backing off for #{backoff_seconds}s"
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_queue, state) do
    # Restore capacity for providers that haven't had 429s recently
    state = restore_provider_capacities(state)

    # Check for starvation and promote old requests
    state = promote_starved_requests(state)

    # Process any requests that can now be fulfilled
    state = process_queue(state)

    # Schedule next check
    schedule_queue_check()

    {:noreply, state}
  end

  # Private helpers

  # Cost tracking threshold ($0.50 increments)
  @cost_report_threshold 0.50

  defp track_cost(state, actual_usage) do
    input_tokens = Map.get(actual_usage, :input, 0)
    output_tokens = Map.get(actual_usage, :output, 0)

    # Calculate cost for this request
    cost = calculate_cost(state.model, input_tokens, output_tokens)

    # Update cumulative cost
    new_cumulative = state.cumulative_cost + cost

    # Check if we should report to Foreman (every $0.50 increment)
    new_state = %{state | cumulative_cost: new_cumulative}

    if should_report_cost?(state.last_cost_report, new_cumulative) do
      report_cost_to_foreman(new_state, new_cumulative)
      %{new_state | last_cost_report: new_cumulative}
    else
      new_state
    end
  end

  defp calculate_cost(model, input_tokens, output_tokens) do
    case Anthropic.model_config(model) do
      %{input_price_per_mtok: input_price, output_price_per_mtok: output_price} ->
        # Prices are per million tokens, convert to actual cost
        input_cost = input_tokens * input_price / 1_000_000
        output_cost = output_tokens * output_price / 1_000_000
        input_cost + output_cost

      {:error, :unknown_model} ->
        Logger.warning("Unknown model #{model} for cost tracking, using $0")
        0.0
    end
  end

  defp should_report_cost?(last_report, new_cumulative) do
    # Report if we've crossed a $0.50 threshold
    trunc(last_report / @cost_report_threshold) < trunc(new_cumulative / @cost_report_threshold)
  end

  defp report_cost_to_foreman(%{foreman_pid: nil}, _cost), do: :ok

  defp report_cost_to_foreman(%{foreman_pid: foreman_pid}, cost) do
    send(foreman_pid, {:rate_limiter, :cost, cost})
    :ok
  end

  defp ensure_provider(state, provider) do
    if Map.has_key?(state.providers, provider) do
      state
    else
      # Initialize buckets for this provider with default limits
      # TODO: Get limits from provider config when available
      buckets = ProviderBuckets.new(@default_rpm, @default_tpm)
      put_in(state, [:providers, provider], buckets)
    end
  end

  defp estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
  end

  defp estimate_message_tokens(%{content: content}) when is_binary(content) do
    div(String.length(content), @chars_per_token)
  end

  defp estimate_message_tokens(%{content: content}) when is_list(content) do
    content
    |> Enum.map(&estimate_content_block_tokens/1)
    |> Enum.sum()
  end

  defp estimate_message_tokens(_), do: 0

  defp estimate_content_block_tokens(%{text: text}) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  defp estimate_content_block_tokens(%{tool_use: %{input: input}}) when is_map(input) do
    # Estimate tool use content by encoding to JSON
    input
    |> Jason.encode!()
    |> byte_size()
    |> div(@chars_per_token)
  end

  defp estimate_content_block_tokens(_), do: 0

  defp priority_for_caller(:foreman), do: @priority_foreman
  defp priority_for_caller(:runner), do: @priority_runner
  defp priority_for_caller(:lead), do: @priority_lead
  defp priority_for_caller(_), do: @priority_lead

  defp schedule_queue_check do
    Process.send_after(self(), :check_queue, @queue_check_interval_ms)
  end

  defp restore_provider_capacities(state) do
    now = state.time_source.(:millisecond)

    # Iterate through providers and restore capacity where appropriate
    new_providers =
      Enum.reduce(state.providers, %{}, fn {provider, buckets}, acc ->
        if should_restore_capacity?(buckets, now) do
          restored_buckets = ProviderBuckets.restore_capacity(buckets)

          # Check if we've fully restored to original capacity
          if restored_buckets.rpm.capacity >= buckets.rpm_original_capacity and
               restored_buckets.tpm.capacity >= buckets.tpm_original_capacity do
            # Fully restored, clear last_429_at
            Map.put(acc, provider, %{restored_buckets | last_429_at: nil})
          else
            Map.put(acc, provider, restored_buckets)
          end
        else
          Map.put(acc, provider, buckets)
        end
      end)

    %{state | providers: new_providers}
  end

  defp should_restore_capacity?(buckets, now) do
    # Only restore if we had a 429 and it's been at least 60s
    buckets.last_429_at != nil and
      now - buckets.last_429_at >= @capacity_restore_grace_period_ms and
      (buckets.rpm.capacity < buckets.rpm_original_capacity or
         buckets.tpm.capacity < buckets.tpm_original_capacity)
  end

  defp enqueue_request(state, provider, estimated_tokens, priority, from) do
    now = state.time_source.(:millisecond)
    queue_id = state.next_queue_id

    request = %{
      provider: provider,
      estimated_tokens: estimated_tokens,
      priority: priority,
      from: from,
      enqueued_at: now
    }

    # Queue key: {-priority, queue_id} for proper ordering
    # Negative priority ensures higher priority values come first
    # queue_id ensures FIFO within same priority
    queue_key = {-priority, queue_id}
    new_queue = :gb_trees.insert(queue_key, request, state.queue)

    %{state | queue: new_queue, next_queue_id: queue_id + 1}
  end

  defp promote_starved_requests(state) do
    if :gb_trees.is_empty(state.queue) do
      state
    else
      now = state.time_source.(:millisecond)
      threshold = now - @starvation_threshold_ms

      # Scan queue for requests older than threshold
      queue_list = :gb_trees.to_list(state.queue)

      {to_promote, _remaining} =
        Enum.split_with(queue_list, fn {_key, request} ->
          request.enqueued_at < threshold
        end)

      if Enum.empty?(to_promote) do
        state
      else
        # Remove old keys and re-insert with highest priority
        new_queue =
          Enum.reduce(to_promote, state.queue, fn {key, _request}, acc ->
            :gb_trees.delete(key, acc)
          end)

        # Re-insert promoted requests with highest priority
        {new_queue, next_id} =
          Enum.reduce(to_promote, {new_queue, state.next_queue_id}, fn {_old_key, request},
                                                                       {queue_acc, id} ->
            promoted_request = %{request | priority: @priority_foreman}
            queue_key = {-@priority_foreman, id}
            new_queue_acc = :gb_trees.insert(queue_key, promoted_request, queue_acc)
            {new_queue_acc, id + 1}
          end)

        %{state | queue: new_queue, next_queue_id: next_id}
      end
    end
  end

  defp process_queue(state) do
    if :gb_trees.is_empty(state.queue) do
      state
    else
      {queue_key, request, remaining_queue} = :gb_trees.take_smallest(state.queue)
      state = %{state | queue: remaining_queue}
      process_request(state, queue_key, request)
    end
  end

  defp process_request(state, queue_key, request) do
    state = ensure_provider(state, request.provider)
    buckets = state.providers[request.provider]
    now = state.time_source.(:millisecond)

    if in_backoff?(buckets, now) do
      re_enqueue_request(state, queue_key, request)
    else
      state = clear_expired_backoff(state, request.provider, buckets, now)
      attempt_deduction(state, queue_key, request)
    end
  end

  defp in_backoff?(buckets, now) do
    buckets.backoff_until != nil and now < buckets.backoff_until
  end

  defp clear_expired_backoff(state, provider, buckets, now) do
    if buckets.backoff_until != nil and now >= buckets.backoff_until do
      updated_buckets = %{buckets | backoff_until: nil}
      put_in(state, [:providers, provider], updated_buckets)
    else
      state
    end
  end

  defp attempt_deduction(state, queue_key, request) do
    buckets = state.providers[request.provider]

    with {:ok, rpm_bucket} <- Bucket.deduct(buckets.rpm, 1),
         {:ok, tpm_bucket} <- Bucket.deduct(buckets.tpm, request.estimated_tokens) do
      grant_request_permission(state, request, rpm_bucket, tpm_bucket, buckets)
    else
      {:error, :insufficient} ->
        re_enqueue_request(state, queue_key, request)
    end
  end

  defp grant_request_permission(state, request, rpm_bucket, tpm_bucket, buckets) do
    new_buckets = %{
      buckets
      | rpm: rpm_bucket,
        tpm: tpm_bucket,
        consecutive_429s: 0
    }

    new_state = put_in(state, [:providers, request.provider], new_buckets)
    GenServer.reply(request.from, {:ok, request.estimated_tokens})
    process_queue(new_state)
  end

  defp re_enqueue_request(state, queue_key, request) do
    new_queue = :gb_trees.insert(queue_key, request, state.queue)
    %{state | queue: new_queue}
  end
end
