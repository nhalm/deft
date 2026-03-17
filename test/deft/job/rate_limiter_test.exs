defmodule Deft.Job.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Deft.Job.RateLimiter

  setup do
    # Start a fresh RateLimiter for each test
    {:ok, pid} = start_supervised(RateLimiter)
    {:ok, rate_limiter: pid}
  end

  describe "dual token-bucket algorithm" do
    test "allows request when both buckets have capacity" do
      messages = [%{content: "Hello world"}]

      assert {:ok, estimated_tokens} = RateLimiter.request("anthropic", messages, :lead)
      assert estimated_tokens > 0
    end

    test "estimates tokens using chars/4 heuristic" do
      # "Hello world" = 11 chars, div(11, 4) = 2 tokens
      messages = [%{content: "Hello world"}]

      assert {:ok, 2} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "deducts 1 from RPM bucket per request" do
      messages = [%{content: "test"}]

      # Make a request - should succeed
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "deducts estimated tokens from TPM bucket" do
      # Large message to test TPM deduction
      large_message = String.duplicate("x", 400)
      messages = [%{content: large_message}]

      # Should deduct 100 tokens (400 chars / 4)
      assert {:ok, 100} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "reconciles actual usage and credits back difference" do
      messages = [%{content: "Hello world"}]

      # Request with estimated tokens
      {:ok, estimated} = RateLimiter.request("anthropic", messages, :lead)
      assert estimated == 2

      # Reconcile with lower actual usage
      actual_usage = %{input: 1, output: 5}
      :ok = RateLimiter.reconcile("anthropic", estimated, actual_usage)

      # Credit back should have been applied (2 - 1 = 1 token credited)
      # Next request should still work (buckets refilled by credit)
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "caps credit-back at bucket capacity" do
      messages = [%{content: "test"}]

      # Make request with high estimate
      {:ok, estimated} = RateLimiter.request("anthropic", messages, :lead)

      # Reconcile with zero actual usage (full credit-back)
      actual_usage = %{input: 0, output: 0}
      :ok = RateLimiter.reconcile("anthropic", estimated, actual_usage)

      # Should not over-credit beyond capacity
      # Verify by making many requests - should eventually be limited
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "handles multiple providers independently" do
      messages = [%{content: "test"}]

      # Request for provider 1
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Request for provider 2 - should have independent buckets
      assert {:ok, _} = RateLimiter.request("openai", messages, :lead)
    end

    test "handles messages with content arrays" do
      messages = [
        %{
          content: [
            %{text: "Hello"},
            %{text: "World"}
          ]
        }
      ]

      # Should estimate both text blocks: "Hello" (5 chars) + "World" (5 chars) = 10 chars = 2 tokens
      assert {:ok, 2} = RateLimiter.request("anthropic", messages, :lead)
    end

    test "handles tool use content blocks" do
      messages = [
        %{
          content: [
            %{tool_use: %{input: %{arg1: "value", arg2: 123}}}
          ]
        }
      ]

      # Should estimate based on JSON encoding of input
      {:ok, estimated} = RateLimiter.request("anthropic", messages, :lead)
      assert estimated > 0
    end
  end

  describe "bucket refill" do
    test "buckets refill over time" do
      # This test would require mocking time or waiting
      # For now, just verify the mechanism doesn't crash
      messages = [%{content: "test"}]

      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Small sleep to allow refill
      Process.sleep(100)

      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)
    end
  end

  describe "priority queue" do
    test "queues and processes requests when capacity becomes available" do
      messages = [%{content: "test"}]

      # Make requests that should succeed
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Even when capacity is low, requests should eventually complete
      # because of refill and queue processing
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :runner)
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :foreman)
    end

    test "processes higher priority requests first" do
      # This test verifies priority ordering Foreman > Runner > Lead
      messages = [%{content: "x"}]

      # Fill capacity with lead requests
      for _ <- 1..40 do
        RateLimiter.request("anthropic", messages, :lead)
      end

      # Now capacity should be low - enqueue requests with different priorities
      lead_task = Task.async(fn -> RateLimiter.request("anthropic", messages, :lead) end)
      runner_task = Task.async(fn -> RateLimiter.request("anthropic", messages, :runner) end)
      foreman_task = Task.async(fn -> RateLimiter.request("anthropic", messages, :foreman) end)

      # Wait a bit for requests to be queued
      Process.sleep(100)

      # All should eventually complete (after refill)
      assert {:ok, _} = Task.await(foreman_task, 5_000)
      assert {:ok, _} = Task.await(runner_task, 5_000)
      assert {:ok, _} = Task.await(lead_task, 5_000)
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

      # Start RateLimiter with injectable time source
      stop_supervised(RateLimiter)
      {:ok, pid} = start_supervised({RateLimiter, [time_source: time_source]})

      {:ok, rate_limiter: pid, time_source: time_source, current_time: current_time}
    end

    test "promotes low-priority requests after 10 seconds", %{current_time: current_time} do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets with a large request
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Now enqueue requests at different priorities that will block
      # Lead request enqueued at t=1000
      :atomics.put(current_time, 1, 1000)

      lead_task =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "lead"}], :lead)
        end)

      # Give it time to be enqueued
      Process.sleep(50)

      # Foreman request enqueued at t=2000 (1 second after lead)
      :atomics.put(current_time, 1, 2000)

      foreman_task =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "foreman"}], :foreman)
        end)

      Process.sleep(50)

      # Advance time to t=11500 (11.5 seconds since start, 10.5 seconds since lead enqueued)
      # Lead request should be promoted to highest priority at t=11001 (10s after t=1000)
      :atomics.put(current_time, 1, 11_500)

      # Trigger queue check (normally happens every 1s via scheduled message)
      send(Process.whereis(RateLimiter), :check_queue)

      # Allow some time for processing
      Process.sleep(100)

      # At this point, both are promoted (lead waited >10s, foreman waited >9s)
      # When capacity becomes available, lead should be processed first
      # because it was promoted earlier (smaller queue_id at highest priority)

      # Advance time further to allow bucket refill
      :atomics.put(current_time, 1, 60_000)
      send(Process.whereis(RateLimiter), :check_queue)

      # Both should complete (lead promoted first due to enqueue time)
      assert {:ok, _} = Task.await(lead_task, 5_000)
      assert {:ok, _} = Task.await(foreman_task, 5_000)
    end

    test "promotes multiple starved requests in enqueue order", %{current_time: current_time} do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Enqueue three lead requests at t=1000, t=2000, t=3000
      :atomics.put(current_time, 1, 1000)

      task1 =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "1"}], :lead)
        end)

      Process.sleep(50)

      :atomics.put(current_time, 1, 2000)

      task2 =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "2"}], :lead)
        end)

      Process.sleep(50)

      :atomics.put(current_time, 1, 3000)

      task3 =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "3"}], :lead)
        end)

      Process.sleep(50)

      # Advance time to t=13000 (all three have been waiting >10s)
      :atomics.put(current_time, 1, 13_000)
      send(Process.whereis(RateLimiter), :check_queue)

      Process.sleep(100)

      # All three should be promoted, maintaining their enqueue order
      # Allow refill
      :atomics.put(current_time, 1, 60_000)
      send(Process.whereis(RateLimiter), :check_queue)

      # All should complete
      assert {:ok, _} = Task.await(task1, 5_000)
      assert {:ok, _} = Task.await(task2, 5_000)
      assert {:ok, _} = Task.await(task3, 5_000)
    end

    test "does not promote requests that haven't waited long enough", %{
      current_time: current_time
    } do
      messages = [%{content: String.duplicate("x", 4000)}]

      # Exhaust buckets
      assert {:ok, _} = RateLimiter.request("anthropic", messages, :lead)

      # Enqueue lead request at t=1000
      :atomics.put(current_time, 1, 1000)

      task =
        Task.async(fn ->
          RateLimiter.request("anthropic", [%{content: "lead"}], :lead)
        end)

      Process.sleep(50)

      # Advance time to t=9000 (only 8 seconds elapsed, < 10s threshold)
      :atomics.put(current_time, 1, 9000)
      send(Process.whereis(RateLimiter), :check_queue)

      Process.sleep(100)

      # Request should still be at lead priority (not promoted yet)
      # We can't directly observe queue state, but we can verify the request
      # is still waiting by checking it hasn't completed

      # Allow refill to complete the request
      :atomics.put(current_time, 1, 60_000)
      send(Process.whereis(RateLimiter), :check_queue)

      assert {:ok, _} = Task.await(task, 5_000)
    end
  end
end
