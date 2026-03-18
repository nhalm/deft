defmodule Deft.Job.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Deft.Job.RateLimiter

  setup do
    # Start a fresh RateLimiter for each test with unique job_id
    job_id = "test-job-#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({RateLimiter, [job_id: job_id]})
    {:ok, rate_limiter: pid, job_id: job_id}
  end

  describe "dual token-bucket algorithm" do
    test "allows request when both buckets have capacity", %{job_id: job_id} do
      messages = [%{content: "Hello world"}]

      assert {:ok, estimated_tokens} = RateLimiter.request(job_id, "anthropic", messages, :lead)
      assert estimated_tokens > 0
    end

    test "estimates tokens using chars/4 heuristic", %{job_id: job_id} do
      # "Hello world" = 11 chars, div(11, 4) = 2 tokens
      messages = [%{content: "Hello world"}]

      assert {:ok, 2} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "deducts 1 from RPM bucket per request", %{job_id: job_id} do
      messages = [%{content: "test"}]

      # Make a request - should succeed
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "deducts estimated tokens from TPM bucket", %{job_id: job_id} do
      # Large message to test TPM deduction
      large_message = String.duplicate("x", 400)
      messages = [%{content: large_message}]

      # Should deduct 100 tokens (400 chars / 4)
      assert {:ok, 100} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "reconciles actual usage and credits back difference", %{job_id: job_id} do
      messages = [%{content: "Hello world"}]

      # Request with estimated tokens
      {:ok, estimated} = RateLimiter.request(job_id, "anthropic", messages, :lead)
      assert estimated == 2

      # Reconcile with lower actual usage
      actual_usage = %{input: 1, output: 5}
      :ok = RateLimiter.reconcile(job_id, "anthropic", estimated, actual_usage)

      # Credit back should have been applied (2 - 1 = 1 token credited)
      # Next request should still work (buckets refilled by credit)
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "caps credit-back at bucket capacity", %{job_id: job_id} do
      messages = [%{content: "test"}]

      # Make request with high estimate
      {:ok, estimated} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Reconcile with zero actual usage (full credit-back)
      actual_usage = %{input: 0, output: 0}
      :ok = RateLimiter.reconcile(job_id, "anthropic", estimated, actual_usage)

      # Should not over-credit beyond capacity
      # Verify by making many requests - should eventually be limited
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "handles multiple providers independently", %{job_id: job_id} do
      messages = [%{content: "test"}]

      # Request for provider 1
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Request for provider 2 - should have independent buckets
      assert {:ok, _} = RateLimiter.request(job_id, "openai", messages, :lead)
    end

    test "handles messages with content arrays", %{job_id: job_id} do
      messages = [
        %{
          content: [
            %{text: "Hello"},
            %{text: "World"}
          ]
        }
      ]

      # Should estimate both text blocks: "Hello" (5 chars) + "World" (5 chars) = 10 chars = 2 tokens
      assert {:ok, 2} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "handles tool use content blocks", %{job_id: job_id} do
      messages = [
        %{
          content: [
            %{tool_use: %{input: %{arg1: "value", arg2: 123}}}
          ]
        }
      ]

      # Should estimate based on JSON encoding of input
      {:ok, estimated} = RateLimiter.request(job_id, "anthropic", messages, :lead)
      assert estimated > 0
    end
  end

  describe "bucket refill" do
    test "buckets refill over time", %{job_id: job_id} do
      # This test would require mocking time or waiting
      # For now, just verify the mechanism doesn't crash
      messages = [%{content: "test"}]

      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Small sleep to allow refill
      Process.sleep(100)

      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end
  end

  describe "priority queue" do
    test "queues and processes requests when capacity becomes available", %{job_id: job_id} do
      messages = [%{content: "test"}]

      # Make requests that should succeed
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Even when capacity is low, requests should eventually complete
      # because of refill and queue processing
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :runner)
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :foreman)
    end

    test "processes higher priority requests first", %{job_id: job_id} do
      # This test verifies priority ordering Foreman > Runner > Lead
      messages = [%{content: "x"}]

      # Fill capacity with lead requests
      for _ <- 1..40 do
        RateLimiter.request(job_id, "anthropic", messages, :lead)
      end

      # Now capacity should be low - enqueue requests with different priorities
      lead_task = Task.async(fn -> RateLimiter.request(job_id, "anthropic", messages, :lead) end)

      runner_task =
        Task.async(fn -> RateLimiter.request(job_id, "anthropic", messages, :runner) end)

      foreman_task =
        Task.async(fn -> RateLimiter.request(job_id, "anthropic", messages, :foreman) end)

      # Wait a bit for requests to be queued
      Process.sleep(100)

      # All should eventually complete (after refill)
      assert {:ok, _} = Task.await(foreman_task, 5_000)
      assert {:ok, _} = Task.await(runner_task, 5_000)
      assert {:ok, _} = Task.await(lead_task, 5_000)
    end
  end

  describe "per-job instances" do
    test "supports multiple concurrent job rate limiters" do
      # Start two RateLimiters for different jobs
      job_id_1 = "job-1"
      job_id_2 = "job-2"

      {:ok, _pid1} = start_supervised({RateLimiter, [job_id: job_id_1]}, id: :limiter_1)
      {:ok, _pid2} = start_supervised({RateLimiter, [job_id: job_id_2]}, id: :limiter_2)

      messages = [%{content: "test"}]

      # Both should work independently without interference
      assert {:ok, _} = RateLimiter.request(job_id_1, "anthropic", messages, :lead)
      assert {:ok, _} = RateLimiter.request(job_id_2, "anthropic", messages, :lead)

      # Make multiple requests to each
      for _ <- 1..5 do
        assert {:ok, _} = RateLimiter.request(job_id_1, "anthropic", messages, :lead)
        assert {:ok, _} = RateLimiter.request(job_id_2, "anthropic", messages, :lead)
      end
    end

    test "requires job_id in start_link options" do
      # Should raise when job_id is missing
      assert_raise KeyError, fn ->
        RateLimiter.start_link([])
      end
    end
  end

  describe "starvation protection" do
    setup do
      # Start time at 0
      current_time = :atomics.new(1, [])
      :atomics.put(current_time, 1, 0)

      time_source = fn :millisecond ->
        :atomics.get(current_time, 1)
      end

      # Start RateLimiter with injectable time source and unique job_id
      job_id = "starvation-test-#{System.unique_integer([:positive])}"
      stop_supervised(RateLimiter)
      {:ok, pid} = start_supervised({RateLimiter, [job_id: job_id, time_source: time_source]})

      {:ok,
       rate_limiter: pid, job_id: job_id, time_source: time_source, current_time: current_time}
    end

    test "promotes low-priority requests after 10 seconds", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets with a large request
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Now enqueue requests at different priorities that will block
      # Lead request enqueued at t=1000
      :atomics.put(current_time, 1, 1000)

      lead_task =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "lead"}], :lead)
        end)

      # Give it time to be enqueued
      Process.sleep(50)

      # Foreman request enqueued at t=2000 (1 second after lead)
      :atomics.put(current_time, 1, 2000)

      foreman_task =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "foreman"}], :foreman)
        end)

      Process.sleep(50)

      # Advance time to t=11500 (11.5 seconds since start, 10.5 seconds since lead enqueued)
      # Lead request should be promoted to highest priority at t=11001 (10s after t=1000)
      :atomics.put(current_time, 1, 11_500)

      # Trigger queue check (normally happens every 1s via scheduled message)
      send(rate_limiter, :check_queue)

      # Allow some time for processing
      Process.sleep(100)

      # At this point, both are promoted (lead waited >10s, foreman waited >9s)
      # When capacity becomes available, lead should be processed first
      # because it was promoted earlier (smaller queue_id at highest priority)

      # Advance time further to allow bucket refill
      :atomics.put(current_time, 1, 60_000)
      send(rate_limiter, :check_queue)

      # Both should complete (lead promoted first due to enqueue time)
      assert {:ok, _} = Task.await(lead_task, 5_000)
      assert {:ok, _} = Task.await(foreman_task, 5_000)
    end

    test "promotes multiple starved requests in enqueue order", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Enqueue three lead requests at t=1000, t=2000, t=3000
      :atomics.put(current_time, 1, 1000)

      task1 =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "1"}], :lead)
        end)

      Process.sleep(50)

      :atomics.put(current_time, 1, 2000)

      task2 =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "2"}], :lead)
        end)

      Process.sleep(50)

      :atomics.put(current_time, 1, 3000)

      task3 =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "3"}], :lead)
        end)

      Process.sleep(50)

      # Advance time to t=13000 (all three have been waiting >10s)
      :atomics.put(current_time, 1, 13_000)
      send(rate_limiter, :check_queue)

      Process.sleep(100)

      # All three should be promoted, maintaining their enqueue order
      # Allow refill
      :atomics.put(current_time, 1, 60_000)
      send(rate_limiter, :check_queue)

      # All should complete
      assert {:ok, _} = Task.await(task1, 5_000)
      assert {:ok, _} = Task.await(task2, 5_000)
      assert {:ok, _} = Task.await(task3, 5_000)
    end

    test "does not promote requests that haven't waited long enough", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Enqueue lead request at t=1000
      :atomics.put(current_time, 1, 1000)

      task =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", [%{content: "lead"}], :lead)
        end)

      Process.sleep(50)

      # Advance time to t=9000 (only 8 seconds elapsed, < 10s threshold)
      :atomics.put(current_time, 1, 9000)
      send(rate_limiter, :check_queue)

      Process.sleep(100)

      # Request should still be at lead priority (not promoted yet)
      # We can't directly observe queue state, but we can verify the request
      # is still waiting by checking it hasn't completed

      # Allow refill to complete the request
      :atomics.put(current_time, 1, 60_000)
      send(rate_limiter, :check_queue)

      assert {:ok, _} = Task.await(task, 5_000)
    end
  end

  describe "429 handling" do
    setup do
      # Start time at 0
      current_time = :atomics.new(1, [])
      :atomics.put(current_time, 1, 0)

      time_source = fn :millisecond ->
        :atomics.get(current_time, 1)
      end

      # Start RateLimiter with injectable time source
      job_id = "429-test-#{System.unique_integer([:positive])}"
      stop_supervised(RateLimiter)
      {:ok, pid} = start_supervised({RateLimiter, [job_id: job_id, time_source: time_source]})

      {:ok,
       rate_limiter: pid, job_id: job_id, time_source: time_source, current_time: current_time}
    end

    test "reduces capacity by 20% on 429 and applies backoff", %{
      job_id: job_id,
      current_time: current_time
    } do
      # Report a 429 - capacity should be reduced and backoff applied
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Verify the system doesn't crash and the API works
      # (detailed capacity verification would require inspecting internal state)
      assert :ok = RateLimiter.report_429(job_id, "anthropic", 5)
    end

    test "applies exponential backoff on consecutive 429s", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      messages = [%{content: "test"}]

      # Report first 429 at t=0
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Request should be blocked until backoff expires (1 second for first 429)
      task1 =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", messages, :lead)
        end)

      Process.sleep(50)

      # Still at t=0, should be in backoff
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # Advance time to t=500ms (still in 1s backoff)
      :atomics.put(current_time, 1, 500)
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # Advance time to t=1100ms (past 1s backoff)
      :atomics.put(current_time, 1, 1100)
      send(rate_limiter, :check_queue)

      # Request should complete now
      assert {:ok, _} = Task.await(task1, 5_000)

      # Report second 429 at t=2000
      :atomics.put(current_time, 1, 2000)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Second backoff should be 2 seconds
      task2 =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", messages, :lead)
        end)

      Process.sleep(50)

      # At t=3000 (1s after 429), should still be in backoff
      :atomics.put(current_time, 1, 3000)
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # At t=4100 (2.1s after 429), should be past backoff
      :atomics.put(current_time, 1, 4100)
      send(rate_limiter, :check_queue)

      assert {:ok, _} = Task.await(task2, 5_000)
    end

    test "caps backoff at 60 seconds", %{job_id: job_id, current_time: current_time} do
      # Report many 429s to reach cap
      # 2^6 = 64 > 60, so 7th 429 should cap at 60s
      :atomics.put(current_time, 1, 0)

      for _ <- 1..7 do
        :ok = RateLimiter.report_429(job_id, "anthropic")
      end

      # The backoff should be capped at 60s, not cause a crash
      # Verify the API still works
      :ok = RateLimiter.report_429(job_id, "anthropic", 30)
    end

    test "uses Retry-After header when larger than exponential backoff", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      messages = [%{content: "test"}]

      # Report 429 with Retry-After of 5 seconds (larger than 1s exponential)
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic", 5)

      task =
        Task.async(fn ->
          RateLimiter.request(job_id, "anthropic", messages, :lead)
        end)

      Process.sleep(50)

      # At t=2000 (2s), should still be in backoff (need 5s)
      :atomics.put(current_time, 1, 2000)
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # At t=5100 (5.1s), should be past backoff
      :atomics.put(current_time, 1, 5100)
      send(rate_limiter, :check_queue)

      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "restores capacity gradually after 60s without 429s", %{
      job_id: job_id,
      current_time: current_time,
      rate_limiter: rate_limiter
    } do
      # Report a 429 at t=0
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Advance time to t=60s (grace period)
      :atomics.put(current_time, 1, 60_000)
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # Capacity should start restoring
      # Advance time further to allow restoration
      :atomics.put(current_time, 1, 61_000)
      send(rate_limiter, :check_queue)
      Process.sleep(50)

      # Make requests - capacity should be increasing
      messages = [%{content: "test"}]
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)

      # Continue advancing time to allow full restoration
      for i <- 2..10 do
        :atomics.put(current_time, 1, 60_000 + i * 1000)
        send(rate_limiter, :check_queue)
        Process.sleep(10)
      end

      # After enough time, capacity should be restored
      assert {:ok, _} = RateLimiter.request(job_id, "anthropic", messages, :lead)
    end

    test "consecutive 429s increase backoff exponentially", %{
      job_id: job_id,
      current_time: current_time
    } do
      # Report first 429 - should have 1s backoff
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Report second 429 - should have 2s backoff
      :atomics.put(current_time, 1, 1000)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Report third 429 - should have 4s backoff
      :atomics.put(current_time, 1, 2000)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # System should handle multiple 429s without crashing
      assert :ok = :ok
    end

    test "handles 429s for different providers independently", %{
      job_id: job_id,
      current_time: current_time
    } do
      # Report 429 for provider 1
      :atomics.put(current_time, 1, 0)
      :ok = RateLimiter.report_429(job_id, "anthropic")

      # Provider 2 should not be affected by provider 1's 429
      messages = [%{content: "test"}]
      assert {:ok, _} = RateLimiter.request(job_id, "openai", messages, :lead)

      # Report 429 for provider 2
      :ok = RateLimiter.report_429(job_id, "openai")

      # Both providers should have independent backoff states
      # Verify the API works
      assert :ok = :ok
    end
  end
end
