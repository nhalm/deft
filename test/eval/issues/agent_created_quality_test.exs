defmodule Deft.Eval.Issues.AgentCreatedQualityTest do
  @moduledoc """
  Eval tests for agent-created issue quality.

  Tests that when an agent discovers out-of-scope work during a session,
  it creates issues that have enough context to be actionable — not just
  a title. Validates source is :agent and priority is 3 by default.

  Pass rate: 80% over 20 iterations (statistical eval)
  """

  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.Eval.Helpers
  alias Deft.Issues
  alias Deft.Message
  alias Deft.Message.Text

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.80

  setup do
    # Ensure Issues GenServer is running
    case Process.whereis(Issues) do
      nil ->
        {:ok, _pid} = Issues.start_link(compaction_days: 90)

      _pid ->
        :ok
    end

    # Create a unique session ID for this test
    session_id = "agent-issue-#{:erlang.unique_integer([:positive])}"

    {:ok, session_id: session_id}
  end

  describe "agent-created issue quality - 80% over 20 iterations" do
    @tag timeout: 300_000
    test "agent creates issues with actionable context", %{session_id: session_id} do
      results =
        Enum.map(1..@iterations, fn i ->
          # Generate a scenario for out-of-scope work discovery
          scenario = generate_scenario(i)

          # Run the agent and check if it creates a quality issue
          agent_creates_quality_issue?(session_id, scenario, i)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nAgent-created issue quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Agent-created issue quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end
  end

  # Generate different scenarios for out-of-scope work discovery
  defp generate_scenario(iteration) do
    scenarios = [
      # Bug discovery scenarios
      %{
        task: "Implement user login with email verification",
        discovery:
          "While reviewing the code, you notice that the password reset endpoint doesn't validate email format and accepts any string, potentially causing database errors. This is out of scope but should be tracked."
      },
      %{
        task: "Add API rate limiting middleware",
        discovery:
          "You discover that the existing authentication middleware has a memory leak - it doesn't close Redis connections properly. This needs fixing but is separate from your current task."
      },
      %{
        task: "Refactor user profile controller",
        discovery:
          "You find a race condition in the order processing code where concurrent requests can create duplicate orders. This is a critical bug but outside your current scope."
      },
      # Refactor needs
      %{
        task: "Add new payment gateway integration",
        discovery:
          "The same email validation logic is duplicated in 5 different controllers. This should be extracted to a shared module for maintainability."
      },
      %{
        task: "Implement search functionality",
        discovery:
          "Database queries are embedded directly in controller actions throughout the codebase. These should be moved to a repository layer following proper architecture."
      },
      # TODO items found
      %{
        task: "Add user profile picture upload",
        discovery:
          "There's a TODO comment in the API controller noting that rate limiting hasn't been implemented. The endpoints are vulnerable to abuse."
      },
      %{
        task: "Implement OAuth login",
        discovery:
          "You find a TODO about adding logging for failed auth attempts for security monitoring. This is needed for detecting brute force attacks."
      },
      # Follow-up work
      %{
        task: "Add JWT authentication",
        discovery:
          "After implementing the auth middleware, you realize it needs comprehensive test coverage including edge cases for expired and malformed tokens."
      },
      %{
        task: "Create new REST endpoints",
        discovery:
          "The API documentation needs updating for the new /auth/refresh endpoint you added, including request/response examples and error codes."
      },
      %{
        task: "Upgrade password hashing to argon2",
        discovery:
          "Now that argon2 is implemented, existing users with bcrypt passwords need a migration strategy to rehash on next login."
      }
    ]

    # Cycle through scenarios
    index = rem(iteration - 1, length(scenarios))
    Enum.at(scenarios, index)
  end

  # Check if agent creates a quality issue
  defp agent_creates_quality_issue?(session_id, scenario, iteration) do
    # Get issue count before
    issues_before = Issues.list()
    count_before = length(issues_before)

    # Start agent with real provider and issue_create tool
    initial_messages = [
      %Message{
        id: "msg_system_1",
        role: :system,
        content: [
          %Text{
            text: """
            You are a coding assistant. When you discover out-of-scope work during a task,
            you MUST use the issue_create tool to track it for later. This includes:
            - Bugs you discover
            - Needed refactors
            - TODO items found in code
            - Follow-up work

            For this scenario:
            Your task: #{scenario.task}
            Discovery: #{scenario.discovery}

            Since this discovery is out of scope, create an issue for it using the issue_create tool.
            Make sure to provide actionable context that explains what needs to be done and why.
            """
          }
        ],
        timestamp: DateTime.utc_now()
      }
    ]

    config = %{
      model: "claude-sonnet-4",
      max_tokens: 2048
    }

    {:ok, agent} =
      Agent.start_link(
        session_id: "#{session_id}_iter_#{iteration}",
        config: config,
        messages: initial_messages
      )

    # Trigger the agent with a simple prompt
    task_prompt = "Please create an issue for the out-of-scope work you discovered."

    Agent.prompt(agent, task_prompt)

    # Wait for the agent to process (allow time for LLM call and tool execution)
    Process.sleep(5_000)

    # Get issues after
    issues_after = Issues.list()
    count_after = length(issues_after)

    # Clean up agent
    Agent.abort(agent)
    Process.sleep(100)

    # Check if a new issue was created
    cond do
      count_after <= count_before ->
        IO.puts("  ⚠️  Iteration #{iteration}: No issue created")
        false

      true ->
        # Find the newly created issue
        new_issues = issues_after -- issues_before
        issue = List.first(new_issues)

        if issue do
          # Validate the issue properties
          result = validate_issue_quality(issue)

          if result do
            IO.puts("  ✅ Iteration #{iteration}: Quality issue created")
          end

          result
        else
          IO.puts("  ⚠️  Iteration #{iteration}: Could not find new issue")
          false
        end
    end
  end

  # Validate issue quality using deterministic checks and LLM-as-judge
  defp validate_issue_quality(issue) do
    # Deterministic checks
    cond do
      issue.source != :agent ->
        IO.puts("     ❌ Issue source is #{issue.source}, expected :agent")
        false

      issue.priority != 3 ->
        IO.puts("     ❌ Issue priority is #{issue.priority}, expected 3 (low)")
        false

      String.trim(issue.context) == "" ->
        IO.puts("     ❌ Issue context is empty")
        false

      true ->
        # Use LLM-as-judge to evaluate if context is actionable
        evaluate_with_judge(issue)
    end
  end

  defp evaluate_with_judge(issue) do
    judge_prompt = """
    Evaluate if this issue has enough context to be actionable for a developer.

    Title: #{issue.title}
    Context: #{issue.context}

    An issue is actionable if:
    - The context explains WHAT the problem or need is
    - The context explains WHY it matters or what triggered the discovery
    - A developer could understand what needs to be done from the context alone

    An issue is NOT actionable if:
    - The context just restates the title
    - The context is too vague (e.g., "needs fixing")
    - Missing critical information about what's wrong or why it's needed

    Answer with ONLY "Yes" if the issue is actionable, or "No" if it's not actionable.
    """

    case Helpers.call_llm_judge(judge_prompt) do
      {:ok, judgment} ->
        # Parse the judgment
        is_actionable =
          judgment
          |> String.trim()
          |> String.downcase()
          |> String.starts_with?("yes")

        unless is_actionable do
          IO.puts("     ❌ LLM judge: issue context not actionable")
          IO.puts("        Title: #{issue.title}")
          IO.puts("        Context: #{String.slice(issue.context, 0..100)}...")
        end

        is_actionable

      {:error, reason} ->
        IO.puts("     ⚠️  LLM judge error: #{inspect(reason)}, counting as failure")
        # On judge failure, we count this as a failure
        false
    end
  end
end
