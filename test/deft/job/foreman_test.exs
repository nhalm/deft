defmodule Deft.Job.ForemanTest do
  use ExUnit.Case, async: false

  alias Deft.Job.Foreman
  alias Deft.Project
  alias Deft.Store

  setup do
    # Create temporary directory for test files
    tmp_dir =
      Path.join(System.tmp_dir!(), "deft_foreman_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Set working directory to tmp for this test
    original_cwd = File.cwd!()
    File.cd!(tmp_dir)

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "site log instance creation" do
    test "creates site log on init", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      # Start a minimal Foreman (will fail in agent loop but site log should be created)
      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      # Get the Foreman's state to verify site log was created
      # :sys.get_state returns {state, data} for gen_statem
      {_state, data} = :sys.get_state(foreman_pid)
      assert data.site_log_pid != nil
      assert Process.alive?(data.site_log_pid)

      # Verify site log file was created
      sitelog_path =
        Path.join([Project.jobs_dir(tmp_dir), session_id, "sitelog.dets"])

      # Wait a bit for async operations
      Process.sleep(100)

      assert File.exists?(sitelog_path)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "site log is accessible to Foreman for writes", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)

      # Verify site log exists and get tid for reads
      tid = Store.tid(data.site_log_pid)

      # Foreman writes to site log via Lead messages
      # Send a decision message which auto-promotes to site log
      send(foreman_pid, {:lead_message, :decision, "Test decision", %{key: "test-decision"}})

      # Wait for processing
      Process.sleep(100)

      # Verify entry was written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "decision-") end)

      # Verify the entry content
      decision_key = Enum.find(keys, fn key -> String.starts_with?(key, "decision-") end)
      {:ok, entry} = Store.read(tid, decision_key)
      assert entry.value == "Test decision"
      assert entry.metadata.category == :decision

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end
  end

  describe "programmatic site log promotion" do
    test "auto-promotes decision messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a decision message from a Lead
      send(foreman_pid, {:lead_message, :decision, "Use PostgreSQL for persistence", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify decision was written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "decision-") end)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "auto-promotes contract messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a contract message from a Lead
      send(
        foreman_pid,
        {:lead_message, :contract, "API endpoint: POST /api/users", %{endpoint: "users"}}
      )

      # Wait for processing
      Process.sleep(100)

      # Verify contract was written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "contract-") end)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "auto-promotes critical_finding messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a critical_finding message from a Lead
      send(foreman_pid, {:lead_message, :critical_finding, "Security vulnerability found", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify critical_finding was written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "critical_finding-") end)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "auto-promotes correction messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a correction message
      send(foreman_pid, {:lead_message, :correction, "Actually use MySQL, not PostgreSQL", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify correction was written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "correction-") end)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "promotes finding messages only when tagged shared", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a non-shared finding message
      send(foreman_pid, {:lead_message, :finding, "Found local implementation detail", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify finding was NOT written to site log
      keys = Store.keys(tid)
      refute Enum.any?(keys, fn key -> String.starts_with?(key, "research-") end)

      # Send a shared finding message
      send(
        foreman_pid,
        {:lead_message, :finding, "Database uses connection pooling", %{shared: true}}
      )

      # Wait for processing
      Process.sleep(100)

      # Verify shared finding WAS written to site log
      keys = Store.keys(tid)
      assert Enum.any?(keys, fn key -> String.starts_with?(key, "research-") end)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "never promotes status messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a status message
      send(foreman_pid, {:lead_message, :status, "Working on database layer", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify status was NOT written to site log
      keys = Store.keys(tid)
      assert keys == []

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "never promotes blocker messages", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      {_state, data} = :sys.get_state(foreman_pid)
      tid = Store.tid(data.site_log_pid)

      # Send a blocker message
      send(foreman_pid, {:lead_message, :blocker, "Need API key configuration", %{}})

      # Wait for processing
      Process.sleep(100)

      # Verify blocker was NOT written to site log
      keys = Store.keys(tid)
      assert keys == []

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)
      # Give processes time to fully terminate
      Process.sleep(50)
    end
  end

  describe "Lead crash cleanup" do
    test "cleans up worktree when Lead crashes", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"
      lead_id = "lead-1"
      worktree_path = "/tmp/test-worktree"

      # Configure git mock to succeed on worktree remove
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      Application.put_env(:deft, :git_mock_responses, %{
        ["worktree", "remove", "--force", worktree_path] => {"", 0}
      })

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      # Get initial state and manually add a Lead to the leads map
      {_state, data} = :sys.get_state(foreman_pid)
      monitor_ref = make_ref()

      lead_info = %{
        pid: self(),
        monitor_ref: monitor_ref,
        worktree_path: worktree_path,
        deliverable: "test deliverable"
      }

      leads = Map.put(data.leads, lead_id, lead_info)
      data = %{data | leads: leads}
      :sys.replace_state(foreman_pid, fn {s, _d} -> {s, data} end)

      # Simulate Lead crash by sending DOWN message
      send(foreman_pid, {:DOWN, monitor_ref, :process, self(), :crash_reason})

      # Wait for processing
      Process.sleep(100)

      # Verify Lead was removed from tracking
      {_state, updated_data} = :sys.get_state(foreman_pid)
      refute Map.has_key?(updated_data.leads, lead_id)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)

      # Clean up git mock config
      Application.delete_env(:deft, :git_mock_responses)
      Application.put_env(:deft, :git_adapter, Deft.Git.System)

      # Give processes time to fully terminate
      Process.sleep(50)
    end

    test "handles worktree removal failure gracefully", %{tmp_dir: tmp_dir} do
      session_id = "test-job-#{:erlang.unique_integer([:positive])}"
      lead_id = "lead-2"
      worktree_path = "/tmp/test-worktree-fail"

      # Configure git mock to fail on worktree remove
      Application.put_env(:deft, :git_adapter, Deft.GitMock)

      Application.put_env(:deft, :git_mock_responses, %{
        ["worktree", "remove", "--force", worktree_path] => {"fatal: worktree removal failed", 1}
      })

      {:ok, foreman_pid} =
        Foreman.start_link(
          session_id: session_id,
          config: %{},
          prompt: "test prompt",
          rate_limiter_pid: self(),
          working_dir: tmp_dir
        )

      # Get initial state and manually add a Lead to the leads map
      {_state, data} = :sys.get_state(foreman_pid)
      monitor_ref = make_ref()

      lead_info = %{
        pid: self(),
        monitor_ref: monitor_ref,
        worktree_path: worktree_path,
        deliverable: "test deliverable"
      }

      leads = Map.put(data.leads, lead_id, lead_info)
      data = %{data | leads: leads}
      :sys.replace_state(foreman_pid, fn {s, _d} -> {s, data} end)

      # Simulate Lead crash by sending DOWN message
      send(foreman_pid, {:DOWN, monitor_ref, :process, self(), :crash_reason})

      # Wait for processing
      Process.sleep(100)

      # Verify Lead was still removed from tracking even though cleanup failed
      {_state, updated_data} = :sys.get_state(foreman_pid)
      refute Map.has_key?(updated_data.leads, lead_id)

      # Cleanup - stop Foreman and clean up site log
      {_state, data} = :sys.get_state(foreman_pid)
      Store.cleanup(data.site_log_pid)
      :gen_statem.stop(foreman_pid)

      # Clean up git mock config
      Application.delete_env(:deft, :git_mock_responses)
      Application.put_env(:deft, :git_adapter, Deft.Git.System)

      # Give processes time to fully terminate
      Process.sleep(50)
    end
  end
end
