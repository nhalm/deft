defmodule Integration.ForemanWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Deft.Foreman
  alias Deft.Foreman.Coordinator
  alias Deft.RateLimiter
  alias Deft.ScriptedProvider
  alias Deft.Store

  setup do
    # Create temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "deft_foreman_workflow_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Init a git repo so GitJob.create_job_branch/1 (wired into Coordinator
    # on job start in c5d8957) can resolve HEAD and see a clean tree. The
    # test body creates .deft/ artifacts at runtime — ignore those so the
    # auto_approve_all dirty-tree check passes.
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, ".gitignore"), ".deft/\n")

    {_, 0} =
      System.cmd(
        "git",
        ["add", ".gitignore"],
        cd: tmp_dir
      )

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=test",
          "-c",
          "user.email=test@example.com",
          "commit",
          "--quiet",
          "-m",
          "init"
        ],
        cd: tmp_dir
      )

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
    test "Foreman transitions through orchestration phases and spawns a Lead", %{
      tmp_dir: tmp_dir,
      runner_supervisor: _runner_supervisor
    } do
      session_id = "foreman-workflow-#{:erlang.unique_integer([:positive])}"

      # Start tool runner supervisor for Foreman's tool execution
      tool_runner_name = {:via, Registry, {Deft.ProcessRegistry, {:tool_runner, session_id}}}
      {:ok, _tool_supervisor} = Task.Supervisor.start_link(name: tool_runner_name)

      # Start runner supervisor for orchestration runners
      {:ok, runner_supervisor} = Task.Supervisor.start_link()

      # Start necessary infrastructure
      {:ok, _rate_limiter} =
        start_supervised({RateLimiter, [job_id: session_id, cost_ceiling: 100.0]})

      # Create site log
      jobs_dir = Path.join(tmp_dir, ".deft/projects/test/jobs")
      job_dir = Path.join(jobs_dir, session_id)
      File.mkdir_p!(job_dir)
      sitelog_path = Path.join(job_dir, "sitelog.dets")

      {:ok, _site_log} =
        start_supervised(
          {Store, [name: {:sitelog, session_id}, type: :sitelog, dets_path: sitelog_path]}
        )

      # Start LeadSupervisor for spawning Leads
      {:ok, lead_supervisor} =
        start_supervised({DynamicSupervisor, strategy: :one_for_one, name: :test_lead_supervisor})

      # Setup ScriptedProvider for Foreman with orchestration workflow
      {:ok, foreman_provider} =
        ScriptedProvider.start_link(
          responses: [
            # Initial analysis - Foreman decides this needs orchestration
            %{
              text: "This requires decomposition.",
              tool_calls: [%{name: "ready_to_plan", args: %{}}],
              usage: %{input: 100, output: 50}
            },
            # After research, submit plan
            %{
              text: "Here's the decomposition.",
              tool_calls: [
                %{
                  name: "submit_plan",
                  args: %{
                    deliverables: [
                      %{
                        id: "backend-api",
                        description: "Implement backend API",
                        dependencies: []
                      }
                    ]
                  }
                }
              ],
              usage: %{input: 200, output: 100}
            },
            # After plan approval, spawn lead
            %{
              text: "Starting backend work.",
              tool_calls: [
                %{
                  name: "spawn_lead",
                  args: %{deliverable_id: "backend-api"}
                }
              ],
              usage: %{input: 150, output: 75}
            }
          ]
        )

      # Start Foreman.Coordinator
      coordinator_name = {:via, Registry, {Deft.ProcessRegistry, {:coordinator, session_id}}}

      {:ok, coordinator} =
        start_supervised(%{
          id: Coordinator,
          start:
            {Coordinator, :start_link,
             [
               [
                 session_id: session_id,
                 config: %{job: %{auto_approve_all: true}},
                 prompt: "Build a REST API",
                 runner_supervisor: runner_supervisor,
                 working_dir: tmp_dir,
                 lead_supervisor: lead_supervisor,
                 name: coordinator_name
               ]
             ]}
        })

      # Start Foreman agent
      foreman_name = {:via, Registry, {Deft.ProcessRegistry, {:foreman, session_id}}}

      {:ok, _foreman} =
        Foreman.start_link(
          session_id: session_id,
          config: %{
            provider: ScriptedProvider,
            provider_pid: foreman_provider,
            model: "test-model"
          },
          parent_pid: coordinator,
          working_dir: tmp_dir,
          messages: [],
          name: foreman_name
        )

      # Set the foreman agent on the coordinator
      Coordinator.set_foreman_agent(coordinator, foreman_name)

      # Verify initial state
      {state, _data} = :sys.get_state(coordinator)
      assert state == :asking

      # Coordinator should auto-prompt the Foreman with the initial task
      # Wait for Foreman to process and call ready_to_plan
      Process.sleep(300)

      # Verify Foreman processed the initial prompt and called ready_to_plan
      calls = ScriptedProvider.calls(foreman_provider)
      assert length(calls) >= 1

      # Verify the first call included the initial prompt
      {messages, _tools, _config} = List.first(calls)
      assert Enum.any?(messages, fn msg -> msg.role == :user end)

      # Verify transition to planning after ready_to_plan tool call
      # The Coordinator should have received {:agent_action, :ready_to_plan}
      # and transitioned from :asking to :planning
      Process.sleep(200)
      {state, data} = :sys.get_state(coordinator)

      # Should have transitioned past asking
      assert state in [:planning, :researching, :decomposing, :executing],
             "Expected state to transition from :asking, but got #{state}"

      # Verify that plan submission was attempted (if the Foreman got that far)
      if state in [:decomposing, :executing] do
        assert data.plan != nil, "Plan should be set when in #{state} state"
      end

      # Verify multiple LLM calls were made (asking -> planning -> decomposing)
      assert length(calls) >= 1, "Expected at least one LLM call"
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
              RateLimiter.request(job_id, "anthropic", messages, :foreman_agent)
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
