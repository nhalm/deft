defmodule Deft.Job.LeadAgentTest do
  use ExUnit.Case, async: true

  alias Deft.Job.LeadAgent

  describe "start_link/1" do
    test "starts a LeadAgent with required options" do
      session_id = "test-job-123-lead-a"
      parent_pid = self()
      working_dir = "/tmp/test-repo"
      worktree_path = "/tmp/test-repo/deft/lead-a"

      deliverable = %{
        name: "API Module",
        description: "Implement the REST API module"
      }

      config = %{
        model: "claude-sonnet-4",
        tools: []
      }

      opts = [
        session_id: session_id,
        config: config,
        parent_pid: parent_pid,
        working_dir: working_dir,
        worktree_path: worktree_path,
        deliverable: deliverable
      ]

      {:ok, pid} = LeadAgent.start_link(opts)
      assert Process.alive?(pid)

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "LeadAgent has OM enabled" do
      session_id = "test-job-124-lead-b"
      parent_pid = self()
      working_dir = "/tmp/test-repo"
      worktree_path = "/tmp/test-repo/deft/lead-b"

      deliverable = %{
        name: "Database Module",
        description: "Implement database access layer"
      }

      config = %{
        model: "claude-sonnet-4",
        tools: []
      }

      opts = [
        session_id: session_id,
        config: config,
        parent_pid: parent_pid,
        working_dir: working_dir,
        worktree_path: worktree_path,
        deliverable: deliverable
      ]

      {:ok, pid} = LeadAgent.start_link(opts)

      # Get the agent's state to verify OM is enabled
      # :sys.get_state returns {state_name, data} for gen_statem
      {_state_name, data} = :sys.get_state(pid)
      assert data.config.om_enabled == true

      # Cleanup
      Process.exit(pid, :normal)
    end

    test "LeadAgent has Lead-specific tools" do
      session_id = "test-job-125-lead-c"
      parent_pid = self()
      working_dir = "/tmp/test-repo"
      worktree_path = "/tmp/test-repo/deft/lead-c"

      deliverable = %{
        name: "Testing Module",
        description: "Add test coverage"
      }

      config = %{
        model: "claude-sonnet-4",
        tools: []
      }

      opts = [
        session_id: session_id,
        config: config,
        parent_pid: parent_pid,
        working_dir: working_dir,
        worktree_path: worktree_path,
        deliverable: deliverable
      ]

      {:ok, pid} = LeadAgent.start_link(opts)

      # Get the agent's state to verify tools are configured
      # :sys.get_state returns {state_name, data} for gen_statem
      {_state_name, data} = :sys.get_state(pid)
      tools = data.config.tools

      # Verify Lead-specific tools are present
      tool_modules = Enum.map(tools, & &1)

      assert Deft.Job.LeadAgent.Tools.SpawnRunner in tool_modules
      assert Deft.Job.LeadAgent.Tools.PublishContract in tool_modules
      assert Deft.Job.LeadAgent.Tools.ReportStatus in tool_modules
      assert Deft.Job.LeadAgent.Tools.RequestHelp in tool_modules

      # Cleanup
      Process.exit(pid, :normal)
    end
  end

  describe "build_system_prompt/3" do
    test "includes deliverable information" do
      working_dir = "/tmp/test-repo"
      worktree_path = "/tmp/test-repo/deft/lead-a"

      deliverable = %{
        name: "API Module",
        description: "Implement the REST API"
      }

      prompt = LeadAgent.build_system_prompt(working_dir, worktree_path, deliverable)

      assert prompt =~ "API Module"
      assert prompt =~ "Implement the REST API"
      assert prompt =~ worktree_path
    end

    test "includes tool descriptions" do
      working_dir = "/tmp/test-repo"
      worktree_path = "/tmp/test-repo/deft/lead-a"
      deliverable = %{name: "Test", description: "Test deliverable"}

      prompt = LeadAgent.build_system_prompt(working_dir, worktree_path, deliverable)

      assert prompt =~ "spawn_runner"
      assert prompt =~ "publish_contract"
      assert prompt =~ "report_status"
      assert prompt =~ "request_help"
    end
  end
end
