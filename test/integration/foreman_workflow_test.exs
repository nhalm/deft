defmodule Integration.ForemanWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Deft.Job.RateLimiter

  setup do
    # Create temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "deft_foreman_workflow_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Set working directory
    original_cwd = File.cwd!()
    File.cd!(tmp_dir)

    # Start a Task.Supervisor for Foreman runners
    {:ok, runner_supervisor} = Task.Supervisor.start_link()

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, runner_supervisor: runner_supervisor}
  end

  describe "Foreman Research → Decompose → Execute workflow (scenario 2.2)" do
    @tag :skip
    test "placeholder for full workflow test", %{} do
      # This test is skipped for now - needs more work to handle Foreman/Runner interaction
      # The challenge is coordinating ScriptedProvider responses between Foreman and multiple Runner tasks
      assert true
    end
  end

  describe "Partial Unblocking Flow (scenario 2.3)" do
    @tag :skip
    test "Lead B starts with contract context from Lead A", %{} do
      # Scripted: Lead A publishes contract → Foreman receives → Lead B starts with contract context
      # Verify: Lead B's starting context includes the contract from Lead A
      # Verify: Lead B started before Lead A completes
      assert true
    end
  end

  describe "Resume from Saved State (scenario 2.4)" do
    @tag :skip
    test "Foreman resumes from mid-job state", %{} do
      # Setup: persist a mid-job state (site log + plan.json + completed deliverables)
      # Start a new Foreman with resume: true
      # Verify: Foreman reads persisted state
      # Verify: Only incomplete deliverables get fresh Leads
      # Verify: Completed work is not repeated
      assert true
    end
  end

  describe "Rate Limiter Integration (scenario 2.5)" do
    test "RateLimiter integrates with provider calls and enforces cost ceiling", %{
      tmp_dir: _tmp_dir
    } do
      job_id = "test-job-#{:erlang.unique_integer([:positive])}"

      # Start RateLimiter with a low cost ceiling to trigger pause quickly
      # Note: RateLimiter has a $1.0 buffer, so ceiling - $1.0 = actual threshold
      # Claude Sonnet 4 pricing: $3/MTok input, $15/MTok output
      # 100 input + 50 output tokens = $0.001050 per call
      # Cost ceiling of $1.02 - $1.0 buffer = $0.02 threshold
      # Should allow ~19 calls before pause
      {:ok, rate_limiter_pid} =
        start_supervised(
          {RateLimiter,
           [
             job_id: job_id,
             cost_ceiling: 1.02,
             cost_warning: 0.50
           ]}
        )

      # Verify initial state
      initial_state = :sys.get_state(rate_limiter_pid)
      assert initial_state.cumulative_cost == 0.0
      refute initial_state.cost_ceiling_reached

      # Simulate the integration pattern: request → LLM call → reconcile
      # This is how Foreman/Lead/Runner use RateLimiter with ScriptedProvider
      completed_requests =
        Enum.reduce_while(1..100, 0, fn i, count ->
          messages = [%{role: :user, content: "Request #{i}"}]

          # Use a short timeout so we don't wait forever when enqueued
          task =
            Task.async(fn ->
              RateLimiter.request(job_id, "anthropic", messages, :foreman)
            end)

          case Task.yield(task, 100) || Task.shutdown(task) do
            {:ok, {:ok, estimated_tokens}} ->
              # Verify request was successful and got estimated tokens
              assert estimated_tokens > 0

              # Simulate LLM call with ScriptedProvider usage metadata
              # In real integration, Provider returns this usage data
              actual_usage = %{input: 100, output: 50}

              # Reconcile to credit back any over-estimation
              # This tests the credit-back mechanism
              :ok = RateLimiter.reconcile(job_id, "anthropic", estimated_tokens, actual_usage)

              # Check if cost ceiling was hit after this reconcile
              current_state = :sys.get_state(rate_limiter_pid)

              if current_state.cost_ceiling_reached do
                # Cost ceiling hit - verify call count is around expected (~19)
                assert i >= 15 and i <= 25,
                       "Cost ceiling should trigger around call 19, got #{i}"

                {:halt, count + 1}
              else
                {:cont, count + 1}
              end

            _other ->
              # Request timed out (enqueued due to cost ceiling) or failed
              # This happens when cost ceiling has already been set
              {:halt, count}
          end
        end)

      # Verify we completed at least some requests before hitting ceiling
      assert completed_requests >= 15, "Should complete at least 15 requests"

      # Verify final RateLimiter state
      final_state = :sys.get_state(rate_limiter_pid)

      # 1. Cost ceiling flag is set
      assert final_state.cost_ceiling_reached

      # 2. Total cost is near the threshold (ceiling - buffer = $1.02 - $1.0 = $0.02)
      assert final_state.cumulative_cost >= 0.01 and final_state.cumulative_cost <= 0.03

      # 3. Credit-back worked - TPM bucket should have tokens
      # If reconcile didn't credit back, TPM bucket would be exhausted
      anthropic_buckets = Map.get(final_state.providers, "anthropic")
      assert anthropic_buckets.tpm.tokens > 0, "TPM bucket should have tokens from credit-back"

      # 4. RPM bucket also has tokens from refill/credit
      assert anthropic_buckets.rpm.tokens > 0, "RPM bucket should have tokens"
    end
  end
end
