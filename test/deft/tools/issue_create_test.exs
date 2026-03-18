defmodule Deft.Tools.IssueCreateTest do
  use ExUnit.Case, async: true

  alias Deft.Tools.IssueCreate
  alias Deft.Tool.Context
  alias Deft.Message.Text
  alias Deft.Issues

  setup do
    # Create temp directory for test working directory
    working_dir =
      System.tmp_dir!() |> Path.join("deft_issue_create_test_#{:rand.uniform(100_000)}")

    File.mkdir_p!(working_dir)
    File.mkdir_p!(Path.join(working_dir, ".deft"))

    # Start Issues GenServer for this test
    issues_file = Path.join([working_dir, ".deft", "issues.jsonl"])
    {:ok, _pid} = Issues.start_link(file_path: issues_file)

    # Track emitted output
    {:ok, emit_agent} = Agent.start_link(fn -> [] end)

    emit = fn text ->
      Agent.update(emit_agent, &[text | &1])
      :ok
    end

    context = %Context{
      working_dir: working_dir,
      session_id: "test-session",
      emit: emit,
      file_scope: nil,
      bash_timeout: 120_000
    }

    on_exit(fn ->
      pid = Process.whereis(Deft.Issues)

      if pid && Process.alive?(pid) do
        GenServer.stop(Deft.Issues)
      end

      File.rm_rf(working_dir)

      if Process.alive?(emit_agent) do
        Agent.stop(emit_agent)
      end
    end)

    %{context: context, working_dir: working_dir}
  end

  describe "behaviour implementation" do
    test "implements Deft.Tool behaviour" do
      Code.ensure_loaded!(Deft.Tools.IssueCreate)
      assert function_exported?(Deft.Tools.IssueCreate, :name, 0)
      assert function_exported?(Deft.Tools.IssueCreate, :description, 0)
      assert function_exported?(Deft.Tools.IssueCreate, :parameters, 0)
      assert function_exported?(Deft.Tools.IssueCreate, :execute, 2)
    end

    test "name/0 returns 'issue_create'" do
      assert IssueCreate.name() == "issue_create"
    end

    test "description/0 returns a non-empty string" do
      desc = IssueCreate.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters/0 returns valid JSON schema" do
      params = IssueCreate.parameters()
      assert is_map(params)
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert is_list(params["required"])
      assert "title" in params["required"]
      assert "context" in params["required"]
    end
  end

  describe "execute/2" do
    @tag :skip_async
    test "starts Issues GenServer if not already running" do
      # Create a fresh test environment without starting Issues GenServer in setup
      working_dir =
        System.tmp_dir!() |> Path.join("deft_issue_create_nostart_test_#{:rand.uniform(100_000)}")

      File.mkdir_p!(working_dir)
      File.mkdir_p!(Path.join(working_dir, ".deft"))

      # Track emitted output
      {:ok, emit_agent} = Agent.start_link(fn -> [] end)

      emit = fn text ->
        Agent.update(emit_agent, &[text | &1])
        :ok
      end

      context = %Context{
        working_dir: working_dir,
        session_id: "test-session-nostart",
        emit: emit,
        file_scope: nil,
        bash_timeout: 120_000
      }

      # Stop Issues GenServer if it's running from other tests
      existing_pid = Process.whereis(Deft.Issues)

      if existing_pid && Process.alive?(existing_pid) do
        GenServer.stop(Deft.Issues)
        # Wait a bit for it to stop
        Process.sleep(10)
      end

      # Verify Issues GenServer is NOT running
      assert Process.whereis(Deft.Issues) == nil

      args = %{
        "title" => "Test auto-start",
        "context" => "Testing that the tool auto-starts the Issues GenServer."
      }

      # Execute the tool - it should start the GenServer automatically
      assert {:ok, [%Text{text: result}]} = IssueCreate.execute(args, context)
      assert result =~ "Created issue"
      assert result =~ "Test auto-start"

      # Verify Issues GenServer is NOW running
      assert Process.whereis(Deft.Issues) != nil

      # Clean up
      pid = Process.whereis(Deft.Issues)

      if pid && Process.alive?(pid) do
        GenServer.stop(Deft.Issues)
      end

      File.rm_rf(working_dir)

      if Process.alive?(emit_agent) do
        Agent.stop(emit_agent)
      end
    end

    test "creates an issue with minimal required fields", %{context: context} do
      args = %{
        "title" => "Fix bug in authentication",
        "context" => "The login endpoint returns 500 instead of 401 for invalid credentials."
      }

      assert {:ok, [%Text{text: result}]} = IssueCreate.execute(args, context)
      assert result =~ "Created issue"
      assert result =~ "Fix bug in authentication"

      # Verify issue was created in the Issues GenServer
      issues = Issues.list()
      assert length(issues) == 1

      issue = hd(issues)
      assert issue.title == "Fix bug in authentication"

      assert issue.context ==
               "The login endpoint returns 500 instead of 401 for invalid credentials."

      assert issue.source == :agent
      assert issue.priority == 3
      assert issue.acceptance_criteria == []
      assert issue.constraints == []
    end

    test "creates an issue with all fields", %{context: context} do
      args = %{
        "title" => "Refactor authentication module",
        "context" => "Current auth code is tightly coupled. Need to decouple for testability.",
        "acceptance_criteria" => [
          "Auth logic extracted to separate module",
          "Unit tests added for auth module"
        ],
        "constraints" => [
          "Don't change public API",
          "Keep backward compatibility"
        ],
        "priority" => 2
      }

      assert {:ok, [%Text{text: result}]} = IssueCreate.execute(args, context)
      assert result =~ "Created issue"
      assert result =~ "Refactor authentication module"
      assert result =~ "medium"

      # Verify issue was created correctly
      issues = Issues.list()
      assert length(issues) == 1

      issue = hd(issues)
      assert issue.title == "Refactor authentication module"
      assert issue.priority == 2
      assert issue.source == :agent
      assert length(issue.acceptance_criteria) == 2
      assert length(issue.constraints) == 2
    end

    test "defaults to priority 3 (low)", %{context: context} do
      args = %{
        "title" => "Add logging to user service",
        "context" => "Need better visibility into user service operations."
      }

      assert {:ok, [%Text{text: result}]} = IssueCreate.execute(args, context)
      assert result =~ "low"

      issues = Issues.list()
      issue = hd(issues)
      assert issue.priority == 3
    end

    test "allows higher priority for critical bugs", %{context: context} do
      args = %{
        "title" => "Critical: User data leak in API",
        "context" =>
          "The /users endpoint exposes password hashes. This is a critical security issue affecting current functionality.",
        "priority" => 0
      }

      assert {:ok, [%Text{text: result}]} = IssueCreate.execute(args, context)
      assert result =~ "critical"

      issues = Issues.list()
      issue = hd(issues)
      assert issue.priority == 0
    end

    test "returns error when title is missing", %{context: context} do
      args = %{
        "context" => "Some context"
      }

      assert {:error, reason} = IssueCreate.execute(args, context)
      assert reason =~ "Title is required"
    end

    test "returns error when context is missing", %{context: context} do
      args = %{
        "title" => "Some title"
      }

      assert {:error, reason} = IssueCreate.execute(args, context)
      assert reason =~ "Context is required"
    end

    test "returns error when title is empty", %{context: context} do
      args = %{
        "title" => "",
        "context" => "Some context"
      }

      assert {:error, reason} = IssueCreate.execute(args, context)
      assert reason =~ "Title must be a non-empty string"
    end

    test "returns error when priority is out of range", %{context: context} do
      args = %{
        "title" => "Test issue",
        "context" => "Test context",
        "priority" => 5
      }

      assert {:error, reason} = IssueCreate.execute(args, context)
      assert reason =~ "Priority must be an integer between 0 and 4"
    end

    test "returns error when acceptance_criteria is not a list", %{context: context} do
      args = %{
        "title" => "Test issue",
        "context" => "Test context",
        "acceptance_criteria" => "not a list"
      }

      assert {:error, reason} = IssueCreate.execute(args, context)
      assert reason =~ "Acceptance criteria must be a list"
    end

    test "creates multiple issues successfully", %{context: context} do
      # First issue
      args1 = %{
        "title" => "Issue 1",
        "context" => "Context 1"
      }

      assert {:ok, _} = IssueCreate.execute(args1, context)

      # Second issue
      args2 = %{
        "title" => "Issue 2",
        "context" => "Context 2"
      }

      assert {:ok, _} = IssueCreate.execute(args2, context)

      # Verify both issues were created
      issues = Issues.list()
      assert length(issues) == 2
    end
  end
end
