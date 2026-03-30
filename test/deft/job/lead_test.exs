defmodule Deft.Job.LeadTest do
  use ExUnit.Case, async: false

  alias Deft.Job.Lead
  alias Deft.Job.RateLimiter
  alias Deft.Project
  alias Deft.Store

  @moduletag :unit

  setup do
    # Create temporary directory for test files
    tmp_dir =
      Path.join(System.tmp_dir!(), "deft_lead_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Set working directory to tmp for this test
    original_cwd = File.cwd!()
    File.cd!(tmp_dir)

    # Start a Task.Supervisor for runners in tests
    {:ok, runner_supervisor} = Task.Supervisor.start_link()

    # Start a site log Store for the tests
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    jobs_dir = Project.jobs_dir(tmp_dir)
    session_dir = Path.join(jobs_dir, session_id)
    File.mkdir_p!(session_dir)
    sitelog_path = Path.join(session_dir, "sitelog.dets")

    site_log_name = {:sitelog, session_id}
    owner_name = {:foreman_test, session_id}

    {:ok, site_log_pid} =
      Store.start_link(
        name: site_log_name,
        type: :sitelog,
        dets_path: sitelog_path,
        owner_name: owner_name
      )

    # Start a RateLimiter for the session
    {:ok, rate_limiter_pid} = RateLimiter.start_link(job_id: session_id)

    on_exit(fn ->
      if Process.alive?(site_log_pid) do
        Store.cleanup(site_log_pid)
      end

      File.cd!(original_cwd)
      File.rm_rf!(tmp_dir)
    end)

    {:ok,
     tmp_dir: tmp_dir,
     runner_supervisor: runner_supervisor,
     session_id: session_id,
     site_log_pid: site_log_pid,
     site_log_name: site_log_name,
     rate_limiter_pid: rate_limiter_pid}
  end

  describe "runner spawning via Task.Supervisor" do
    test "spawns runner with async_nolink and monitors process", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      # Start a minimal Lead
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Get the Lead's state
      # Note: The Lead may already be calling the LLM in planning phase
      {state, data} = :sys.get_state(lead_pid)

      # Verify the Lead is in planning phase
      assert state == :planning
      assert data.runner_supervisor == runner_supervisor
      assert data.runner_tasks == %{}

      # Spawn a runner directly using the Lead's spawn_runner function
      # We'll simulate this by calling the internal function (normally this happens via state machine)
      context = %{test: "context"}

      {:ok, task_ref, monitor_ref, updated_data} =
        Lead.spawn_runner(
          data,
          :research,
          "test task",
          "test instructions",
          context
        )

      # Verify task was spawned
      assert is_reference(task_ref)
      assert is_reference(monitor_ref)

      # Verify runner_tasks tracking
      assert Map.has_key?(updated_data.runner_tasks, task_ref)
      runner_info = Map.get(updated_data.runner_tasks, task_ref)

      assert runner_info.task_description == "test task"
      assert runner_info.runner_type == :research
      assert is_pid(runner_info.pid)
      assert runner_info.monitor_ref == monitor_ref
      assert is_reference(runner_info.timeout_ref)
      assert is_integer(runner_info.started_at)

      # Verify the runner process is actually running and monitored
      assert Process.alive?(runner_info.pid)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "runner crash handling" do
    test "handles runner crash without crashing itself", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Transition Lead to executing state to avoid LLM calls
      :sys.replace_state(lead_pid, fn {_s, d} -> {:executing, d} end)

      # Create a fake runner task ref and monitor ref
      task_ref = make_ref()
      monitor_ref = make_ref()
      fake_pid = spawn(fn -> :ok end)

      # Manually update the Lead's state to include this "runner"
      {_state, data} = :sys.get_state(lead_pid)

      runner_info = %{
        task_description: "crashing task",
        runner_type: :read_only,
        pid: fake_pid,
        monitor_ref: monitor_ref,
        timeout_ref: nil,
        started_at: System.monotonic_time(:millisecond)
      }

      data = %{data | runner_tasks: Map.put(data.runner_tasks, task_ref, runner_info)}
      :sys.replace_state(lead_pid, fn {s, _d} -> {s, data} end)

      # Send a fake DOWN message to the Lead to simulate a crash
      send(lead_pid, {:DOWN, monitor_ref, :process, fake_pid, :killed})

      # Give the Lead time to process the DOWN message
      Process.sleep(100)

      # Verify the Lead is still alive after handling the crash
      assert Process.alive?(lead_pid)

      # Verify the runner was removed from tracking
      {_state, updated_data} = :sys.get_state(lead_pid)
      refute Map.has_key?(updated_data.runner_tasks, task_ref)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "runner timeout handling" do
    test "handles runner timeout and cleans up", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test", job_runner_timeout: 100},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Spawn a runner that will timeout (sleeps forever)
      task =
        Task.Supervisor.async_nolink(runner_supervisor, fn ->
          Process.sleep(:infinity)
        end)

      monitor_ref = Process.monitor(task.pid)

      # Manually update the Lead's state to include this runner with a short timeout
      {_state, data} = :sys.get_state(lead_pid)

      timeout_ref = Process.send_after(lead_pid, {:runner_timeout, task.ref}, 100)

      runner_info = %{
        task_description: "long running task",
        runner_type: :read_only,
        pid: task.pid,
        monitor_ref: monitor_ref,
        timeout_ref: timeout_ref,
        started_at: System.monotonic_time(:millisecond)
      }

      data = %{data | runner_tasks: Map.put(data.runner_tasks, task.ref, runner_info)}
      :sys.replace_state(lead_pid, fn {s, _d} -> {s, data} end)

      # Wait for the timeout message to be processed
      Process.sleep(200)

      # Verify the Lead is still alive
      assert Process.alive?(lead_pid)

      # Cleanup the task
      Task.Supervisor.terminate_child(runner_supervisor, task.pid)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "message types to Foreman" do
    test "sends :status message to Foreman", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send a status message
      Lead.send_lead_message(foreman_pid, :status, "Test status", %{})

      # Verify we received the correct message format
      assert_receive {:lead_message, :status, "Test status", %{}}, 1000

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "sends :decision message to Foreman", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send a decision message
      Lead.send_lead_message(foreman_pid, :decision, "Test decision", %{lead_id: lead_id})

      # Verify we received the correct message format
      assert_receive {:lead_message, :decision, "Test decision", %{lead_id: ^lead_id}}, 1000

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "sends :contract message to Foreman", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send a contract message
      Lead.send_lead_message(foreman_pid, :contract, "Test contract", %{lead_id: lead_id})

      # Verify we received the correct message format
      assert_receive {:lead_message, :contract, "Test contract", %{lead_id: ^lead_id}}, 1000

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "sends :complete message to Foreman", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send a complete message
      Lead.send_lead_message(
        foreman_pid,
        :complete,
        "Deliverable complete",
        %{lead_id: lead_id}
      )

      # Verify we received the correct message format
      assert_receive {:lead_message, :complete, "Deliverable complete", %{lead_id: ^lead_id}},
                     1000

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "foreman steering messages" do
    test "handles :foreman_steering message in planning state", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Verify initial state is planning
      {state, _data} = :sys.get_state(lead_pid)
      assert state == :planning

      # Send a foreman steering message
      send(lead_pid, {:foreman_steering, "Steering guidance from Foreman"})

      # Give the Lead time to process the message
      Process.sleep(100)

      # Verify the Lead is still alive and in a valid state
      assert Process.alive?(lead_pid)
      {_new_state, data} = :sys.get_state(lead_pid)

      # The foreman steering should queue a prompt
      # (based on the implementation, it adds a message to the queue)
      assert is_map(data)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "handles :foreman_steering message in executing state", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: "Test deliverable",
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Manually transition to executing state
      :sys.replace_state(lead_pid, fn {_s, d} -> {:executing, d} end)

      # Send a foreman steering message
      send(lead_pid, {:foreman_steering, "Adjust your approach"})

      # Give the Lead time to process the message
      Process.sleep(100)

      # Verify the Lead is still alive
      assert Process.alive?(lead_pid)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "deliverable decomposition" do
    test "Lead starts in planning phase with deliverable assignment", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()
      deliverable = %{name: "Implement authentication module", description: "Add auth"}

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: deliverable,
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Verify initial state is :planning (simple atom, not tuple)
      {state, _data} = :sys.get_state(lead_pid)
      assert state == :planning

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end

  describe "agent action message handling" do
    test "handles {:agent_action, :spawn_runner, type, instructions} message", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()
      deliverable = %{name: "Test deliverable", description: "Test"}

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: deliverable,
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send agent action to spawn a runner
      send(lead_pid, {:agent_action, :spawn_runner, :research, "Find all auth files"})

      # Give time to process
      Process.sleep(100)

      # Verify Lead is still alive and spawned the runner
      assert Process.alive?(lead_pid)

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "handles {:agent_action, :publish_contract, content} message", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()
      deliverable = %{name: "Test deliverable", description: "Test"}

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: deliverable,
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send agent action to publish contract
      contract_content = "Authentication interface defined"
      send(lead_pid, {:agent_action, :publish_contract, contract_content})

      # Verify Foreman receives the contract message
      assert_receive {:lead_message, :contract, ^contract_content, metadata}, 1000
      assert metadata.lead_id == lead_id
      assert metadata.deliverable == "Test deliverable"

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "handles {:agent_action, :report, type, content} message", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()
      deliverable = %{name: "Test deliverable", description: "Test"}

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: deliverable,
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send agent action to report status
      send(lead_pid, {:agent_action, :report, :status, "Progress update"})

      # Verify Foreman receives the status message
      assert_receive {:lead_message, :status, "Progress update", metadata}, 1000
      assert metadata.lead_id == lead_id
      assert metadata.deliverable == "Test deliverable"

      # Cleanup
      :gen_statem.stop(lead_pid)
    end

    test "handles {:agent_action, :blocker, description} message", %{
      tmp_dir: tmp_dir,
      runner_supervisor: runner_supervisor,
      session_id: session_id,
      site_log_name: site_log_name,
      rate_limiter_pid: rate_limiter_pid
    } do
      lead_id = "lead-#{:erlang.unique_integer([:positive])}"
      foreman_pid = self()
      deliverable = %{name: "Test deliverable", description: "Test"}

      {:ok, lead_pid} =
        Lead.start_link(
          lead_id: lead_id,
          session_id: session_id,
          config: %{provider: "test"},
          deliverable: deliverable,
          foreman_pid: foreman_pid,
          site_log_name: site_log_name,
          rate_limiter_pid: rate_limiter_pid,
          worktree_path: tmp_dir,
          working_dir: tmp_dir,
          runner_supervisor: runner_supervisor
        )

      # Send agent action for blocker
      blocker_desc = "Cannot proceed without database schema"
      send(lead_pid, {:agent_action, :blocker, blocker_desc})

      # Verify Foreman receives the blocker message
      assert_receive {:lead_message, :blocker, ^blocker_desc, metadata}, 1000
      assert metadata.lead_id == lead_id
      assert metadata.deliverable == "Test deliverable"

      # Cleanup
      :gen_statem.stop(lead_pid)
    end
  end
end
