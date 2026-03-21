defmodule Deft.Eval.Spilling.ThresholdCalibrationTest do
  @moduledoc """
  Eval tests for tool result spilling threshold calibration.

  This test uses a grid search methodology to find optimal spilling thresholds
  per tool type. It's expensive (~$20-30 per full grid run) and should only be
  run during calibration, not on every push.

  Methodology:
  1. Build 20 realistic tasks where the agent needs tool results
  2. For each tool, test thresholds at [2k, 4k, 8k, 12k, 16k, 24k] tokens
  3. Measure per threshold:
     - Task completion rate (did the agent produce the correct answer?)
     - Context window consumption (tokens used by tool results)
     - Cache retrieval rate (what fraction of cache:// references did the agent follow?)
     - Cost (fewer spills = larger context = higher cost per turn)
  4. Plot the knee in the tradeoff curve — that's the default threshold
  5. Run separately per tool (grep vs read have different information densities)

  This eval is tagged :calibration and is excluded from normal eval runs.
  Run with: mix test --only calibration
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers
  alias Deft.Message.Text
  alias Deft.Store
  alias Deft.Tool.Context
  alias Deft.Tools.{Grep, Ls, Read}

  @moduletag :eval
  @moduletag :expensive
  @moduletag :calibration

  # Thresholds to test (in tokens)
  @thresholds [2_000, 4_000, 8_000, 12_000, 16_000, 24_000]

  # Number of tasks to test per threshold
  @tasks_per_threshold 20

  setup do
    # Start a test cache store
    session_id = "spilling-calibration-#{:erlang.unique_integer([:positive])}"

    {:ok, registry_pid} =
      Registry.start_link(keys: :unique, name: :"registry_#{session_id}")

    dets_path = Path.join(System.tmp_dir!(), "threshold_calibration_test_#{session_id}.dets")

    working_dir = File.cwd!()

    on_exit(fn ->
      if Process.alive?(registry_pid), do: GenServer.stop(registry_pid)
      if File.exists?(dets_path), do: File.rm(dets_path)
    end)

    {:ok,
     session_id: session_id,
     registry_name: :"registry_#{session_id}",
     dets_path: dets_path,
     working_dir: working_dir}
  end

  describe "grep threshold calibration - grid search" do
    @tag timeout: 600_000
    test "measures tradeoff curve across thresholds", context do
      results = run_threshold_grid_search("grep", context)

      # Log results for analysis
      IO.puts("\n=== GREP THRESHOLD CALIBRATION RESULTS ===")
      print_calibration_results(results)

      # Validate we got results for all thresholds
      assert length(results) == length(@thresholds)

      # Find the knee in the curve
      optimal_threshold = find_optimal_threshold(results)
      IO.puts("\nOptimal threshold for grep: #{optimal_threshold} tokens")

      # Store results for future reference
      store_calibration_results("grep", results, optimal_threshold)
    end
  end

  describe "read threshold calibration - grid search" do
    @tag timeout: 600_000
    test "measures tradeoff curve across thresholds", context do
      results = run_threshold_grid_search("read", context)

      IO.puts("\n=== READ THRESHOLD CALIBRATION RESULTS ===")
      print_calibration_results(results)

      assert length(results) == length(@thresholds)

      optimal_threshold = find_optimal_threshold(results)
      IO.puts("\nOptimal threshold for read: #{optimal_threshold} tokens")

      store_calibration_results("read", results, optimal_threshold)
    end
  end

  describe "ls threshold calibration - grid search" do
    @tag timeout: 600_000
    test "measures tradeoff curve across thresholds", context do
      results = run_threshold_grid_search("ls", context)

      IO.puts("\n=== LS THRESHOLD CALIBRATION RESULTS ===")
      print_calibration_results(results)

      assert length(results) == length(@thresholds)

      optimal_threshold = find_optimal_threshold(results)
      IO.puts("\nOptimal threshold for ls: #{optimal_threshold} tokens")

      store_calibration_results("ls", results, optimal_threshold)
    end
  end

  # Helper: Run grid search across all thresholds for a given tool
  defp run_threshold_grid_search(tool_name, context) do
    Enum.map(@thresholds, fn threshold ->
      IO.puts("\nTesting threshold: #{threshold} tokens for #{tool_name}")

      # Run tasks for this threshold
      task_results = run_tasks_for_threshold(tool_name, threshold, context)

      # Aggregate metrics
      completion_rate = calculate_completion_rate(task_results)
      avg_context_consumption = calculate_avg_context_consumption(task_results)
      cache_retrieval_rate = calculate_cache_retrieval_rate(task_results)
      avg_cost = calculate_avg_cost(task_results)

      %{
        threshold: threshold,
        completion_rate: completion_rate,
        avg_context_consumption: avg_context_consumption,
        cache_retrieval_rate: cache_retrieval_rate,
        avg_cost: avg_cost,
        task_count: length(task_results)
      }
    end)
  end

  # Helper: Run tasks for a specific threshold
  defp run_tasks_for_threshold(tool_name, threshold, context) do
    Enum.map(1..@tasks_per_threshold, fn task_num ->
      # Start a store with the specific threshold
      {:ok, store_pid} =
        Store.start_link(
          name:
            {:via, Registry,
             {context.registry_name, {:cache, context.session_id, "#{threshold}-#{task_num}"}}},
          type: :cache,
          dets_path: "#{context.dets_path}.#{threshold}.#{task_num}"
        )

      task_context = %Context{
        session_id: context.session_id,
        working_dir: context.working_dir,
        emit: fn _ -> :ok end,
        bash_timeout: 120_000,
        cache_tid: store_pid,
        cache_config: %{
          tool_name => threshold,
          "default" => threshold
        }
      }

      # Generate a realistic task
      task = generate_task(tool_name, task_num)

      # Execute the task and measure outcomes
      result = execute_task(task, task_context, tool_name)

      # Cleanup
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)

      result
    end)
  end

  # Helper: Generate a realistic task for the given tool
  defp generate_task(tool_name, task_num) do
    case tool_name do
      "grep" ->
        %{
          type: :grep,
          description: "Search for pattern in large codebase",
          size: Enum.random([2_000, 5_000, 10_000, 15_000, 20_000]),
          expected_answer: "Pattern found in #{Enum.random(10..50)} files",
          task_num: task_num
        }

      "read" ->
        %{
          type: :read,
          description: "Read large file to extract specific information",
          size: Enum.random([2_000, 5_000, 10_000, 15_000, 20_000]),
          expected_answer: "File contains #{Enum.random(100..500)} lines",
          task_num: task_num
        }

      "ls" ->
        %{
          type: :ls,
          description: "List large directory to find specific files",
          size: Enum.random([2_000, 5_000, 10_000, 15_000, 20_000]),
          expected_answer: "Directory contains #{Enum.random(50..200)} files",
          task_num: task_num
        }
    end
  end

  # Helper: Execute a task and measure outcomes
  defp execute_task(task, context, tool_name) do
    # Generate tool result based on task
    tool_result = generate_tool_result(task)

    # Get summary (if size exceeds threshold)
    threshold = Map.get(context.cache_config, tool_name, 4_000)
    result_size = estimate_tokens(tool_result)

    {summary, was_spilled} =
      if result_size > threshold do
        cache_key = "task-#{task.task_num}-#{:erlang.unique_integer([:positive])}"
        summary = generate_summary(tool_name, tool_result, cache_key)
        {summary, true}
      else
        {tool_result, false}
      end

    # Simulate agent decision-making with LLM judge
    agent_completed = judge_task_completion(task, summary, was_spilled)
    agent_retrieved_cache = was_spilled && judge_cache_retrieval(task, summary)

    # Calculate metrics
    context_tokens = if was_spilled, do: estimate_tokens(summary), else: result_size
    # Rough cost estimate: $3 per 1M input tokens (Claude Sonnet)
    cost_usd = context_tokens * 3 / 1_000_000

    %{
      completed: agent_completed,
      was_spilled: was_spilled,
      retrieved_cache: agent_retrieved_cache || false,
      context_tokens: context_tokens,
      cost_usd: cost_usd,
      result_size: result_size
    }
  end

  # Helper: Generate tool result based on task
  defp generate_tool_result(task) do
    case task.type do
      :grep ->
        generate_grep_result(task.size)

      :read ->
        generate_read_result(task.size)

      :ls ->
        generate_ls_result(task.size)
    end
  end

  # Helper: Generate summary using the appropriate tool's summarize function
  defp generate_summary("grep", result, cache_key) do
    Grep.summarize([%Text{text: result}], cache_key)
  end

  defp generate_summary("read", result, cache_key) do
    Read.summarize([%Text{text: result}], cache_key)
  end

  defp generate_summary("ls", result, cache_key) do
    Ls.summarize([%Text{text: result}], cache_key)
  end

  # Helper: Judge if agent completed the task successfully
  defp judge_task_completion(task, result_or_summary, was_spilled) do
    prompt = """
    You are evaluating whether an AI agent can complete a task given the tool result.

    TASK: #{task.description}
    EXPECTED ANSWER: #{task.expected_answer}

    TOOL RESULT #{if was_spilled, do: "(SUMMARY)", else: "(FULL)"}:
    #{String.slice(result_or_summary, 0, 2000)}

    QUESTION: Based on this #{if was_spilled, do: "summary", else: "full result"}, can the agent answer the task correctly?

    Respond with ONLY one word:
    - "PASS" if the agent can complete the task with this information
    - "FAIL" if the agent would need more information to complete the task

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Helper: Judge if agent would retrieve the cache
  defp judge_cache_retrieval(task, summary) do
    prompt = """
    You are evaluating whether an AI agent would retrieve a cached full result.

    TASK: #{task.description}

    SUMMARY (truncated):
    #{String.slice(summary, 0, 1000)}

    QUESTION: Would an intelligent agent recognize that this summary is not sufficient
    and retrieve the full cached result to complete the task?

    Respond with ONLY one word:
    - "YES" if the agent should retrieve the cache
    - "NO" if the summary is sufficient

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/YES/

      {:error, _reason} ->
        false
    end
  end

  # Helper: Calculate completion rate
  defp calculate_completion_rate(task_results) do
    completed = Enum.count(task_results, & &1.completed)
    completed / length(task_results)
  end

  # Helper: Calculate average context consumption
  defp calculate_avg_context_consumption(task_results) do
    total = Enum.sum(Enum.map(task_results, & &1.context_tokens))
    total / length(task_results)
  end

  # Helper: Calculate cache retrieval rate
  defp calculate_cache_retrieval_rate(task_results) do
    spilled_results = Enum.filter(task_results, & &1.was_spilled)

    if length(spilled_results) == 0 do
      0.0
    else
      retrieved = Enum.count(spilled_results, & &1.retrieved_cache)
      retrieved / length(spilled_results)
    end
  end

  # Helper: Calculate average cost
  defp calculate_avg_cost(task_results) do
    total = Enum.sum(Enum.map(task_results, & &1.cost_usd))
    total / length(task_results)
  end

  # Helper: Print calibration results
  defp print_calibration_results(results) do
    IO.puts("\nThreshold | Completion | Context (avg) | Cache Retrieval | Cost (avg)")
    IO.puts("----------------------------------------------------------------------")

    Enum.each(results, fn r ->
      IO.puts(
        "#{String.pad_leading(to_string(r.threshold), 9)} | " <>
          "#{String.pad_leading(Float.to_string(Float.round(r.completion_rate * 100, 1)), 9)}% | " <>
          "#{String.pad_leading(to_string(round(r.avg_context_consumption)), 13)} | " <>
          "#{String.pad_leading(Float.to_string(Float.round(r.cache_retrieval_rate * 100, 1)), 14)}% | " <>
          "$#{Float.to_string(Float.round(r.avg_cost, 6))}"
      )
    end)
  end

  # Helper: Find optimal threshold (knee in the curve)
  defp find_optimal_threshold(results) do
    # Strategy: Find the threshold where completion rate is high (>= 85%)
    # and context consumption is minimized (more spilling)
    acceptable = Enum.filter(results, fn r -> r.completion_rate >= 0.85 end)

    if length(acceptable) > 0 do
      # Among acceptable thresholds, pick the one with lowest context consumption
      # (which means more spilling, which is the goal)
      optimal = Enum.min_by(acceptable, & &1.avg_context_consumption)
      optimal.threshold
    else
      # If no threshold meets the bar, pick the one with highest completion rate
      best = Enum.max_by(results, & &1.completion_rate)
      best.threshold
    end
  end

  # Helper: Store calibration results
  defp store_calibration_results(tool_name, results, optimal_threshold) do
    # Store in test/eval/results/ directory
    results_dir = Path.join([File.cwd!(), "test", "eval", "results"])
    File.mkdir_p(results_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    filename = "threshold_calibration_#{tool_name}_#{timestamp}.json"
    filepath = Path.join(results_dir, filename)

    data = %{
      tool: tool_name,
      timestamp: timestamp,
      optimal_threshold: optimal_threshold,
      results: results
    }

    File.write!(filepath, Jason.encode!(data, pretty: true))
    IO.puts("\nCalibration results saved to: #{filepath}")
  end

  # Helper: Estimate token count (rough approximation)
  defp estimate_tokens(text) do
    # Rough estimate: byte_size / 4
    div(byte_size(text), 4)
  end

  # Helper: Generate realistic grep output
  defp generate_grep_result(target_tokens) do
    target_words = round(target_tokens * 1.3)
    lines_needed = div(target_words, 10)

    1..lines_needed
    |> Enum.map(fn i ->
      file = "src/module#{rem(i, 20)}.ex"
      line_num = 100 + i * 5
      content = "defmodule Something#{i} do # Some code here that matches pattern"
      "#{file}:#{line_num}:#{content}"
    end)
    |> Enum.join("\n")
  end

  # Helper: Generate realistic read output
  defp generate_read_result(target_tokens) do
    target_words = round(target_tokens * 1.3)
    lines_needed = div(target_words, 8)

    lines =
      1..lines_needed
      |> Enum.map(fn i ->
        "#{String.pad_leading(to_string(i), 6)}→  # This is line #{i} of the file with some code"
      end)
      |> Enum.join("\n")

    lines <> "\n\n(#{lines_needed} of #{lines_needed} lines)"
  end

  # Helper: Generate realistic ls output
  defp generate_ls_result(target_tokens) do
    target_words = round(target_tokens * 1.3)
    entries_needed = div(target_words, 6)

    1..entries_needed
    |> Enum.map(fn i ->
      type = if rem(i, 4) == 0, do: "d", else: "-"
      perms = "rwxr-xr-x"
      size = :rand.uniform(100_000)
      date = "Mar 18 14:30"
      name = "file_#{i}.ex"
      "#{type}#{perms}  1 user  staff  #{size}  #{date}  #{name}"
    end)
    |> Enum.join("\n")
  end
end
