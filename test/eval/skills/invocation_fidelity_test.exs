defmodule Deft.Eval.Skills.InvocationFidelityTest do
  @moduledoc """
  Eval tests for skill invocation fidelity.

  Tests that the agent correctly follows multi-step instructions defined in skills.
  Per spec section 8.2, when a skill definition is injected into context with
  multi-step instructions, the agent should follow the steps in order.

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.Eval.Helpers
  alias Deft.Provider.Anthropic
  alias Deft.Provider.Event.{TextDelta, Done, Error}

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "skill invocation fidelity - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "follows multi-step skill instructions in order", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_skill_invocation_conversation()

          # Collect response text
          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response follow the steps in order?
          judge_step_order(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill invocation fidelity (step order): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Skill invocation fidelity below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "follows skill with verification steps", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_verification_skill_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response follow verification steps?
          judge_verification_steps(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill invocation fidelity (verification): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "follows skill with conditional steps", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_conditional_skill_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response handle conditional logic?
          judge_conditional_steps(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill invocation fidelity (conditional): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "completes all required steps in skill", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_complete_skill_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response complete all required steps?
          judge_completeness(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill invocation fidelity (completeness): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build conversation with multi-step skill definition
  defp build_skill_invocation_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          SKILL DEFINITION: /code-review
          When the user invokes /code-review, follow these steps IN ORDER:
          1. Read the code file mentioned by the user
          2. Check for common issues (syntax, style, performance)
          3. Summarize findings
          4. Suggest improvements

          Follow these steps precisely when /code-review is invoked.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "/code-review lib/auth.ex"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build conversation with verification skill
  defp build_verification_skill_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          SKILL DEFINITION: /deploy-check
          When the user invokes /deploy-check, follow these steps IN ORDER:
          1. Check that tests pass
          2. Verify no uncommitted changes
          3. Check deployment config exists
          4. Report status

          Follow these steps precisely when /deploy-check is invoked.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "/deploy-check"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build conversation with conditional skill
  defp build_conditional_skill_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          SKILL DEFINITION: /smart-commit
          When the user invokes /smart-commit, follow these steps IN ORDER:
          1. Check git status
          2. If there are changes:
             a. Generate commit message
             b. Create commit
          3. If there are no changes:
             a. Report "Nothing to commit"

          Follow these steps precisely when /smart-commit is invoked.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "/smart-commit"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build conversation testing completeness
  defp build_complete_skill_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant.

          SKILL DEFINITION: /full-setup
          When the user invokes /full-setup, follow ALL these steps IN ORDER:
          1. Install dependencies
          2. Set up database
          3. Run migrations
          4. Seed test data
          5. Verify setup

          You MUST complete ALL steps. Do not skip any step.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "/full-setup"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Call provider and collect text response
  defp call_provider_and_collect_text(messages, config) do
    case Anthropic.stream(messages, [], config) do
      {:ok, stream_ref} ->
        collect_text(stream_ref, "", 60_000)

      {:error, _reason} ->
        ""
    end
  end

  # Collect text from stream
  defp collect_text(stream_ref, accumulated, timeout) do
    receive do
      {:provider_event, %TextDelta{delta: text}} ->
        collect_text(stream_ref, accumulated <> text, timeout)

      {:provider_event, %Done{}} ->
        accumulated

      {:provider_event, %Error{}} ->
        accumulated
    after
      timeout ->
        Anthropic.cancel_stream(stream_ref)
        accumulated
    end
  end

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Judge: Does response follow steps in order?
  defp judge_step_order(response_text) do
    prompt = """
    You are evaluating whether an AI assistant followed skill instructions in order.

    SKILL DEFINITION: /code-review
    Steps (IN ORDER):
    1. Read the code file
    2. Check for common issues
    3. Summarize findings
    4. Suggest improvements

    USER REQUEST: "/code-review lib/auth.ex"

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response follow these steps IN ORDER?

    Good execution:
    - Mentions reading/checking the file FIRST
    - Then checks for issues
    - Then summarizes
    - Then suggests improvements
    - Steps appear in the correct sequence

    Bad execution:
    - Skips steps
    - Does steps out of order
    - Only does some steps

    Respond with ONLY one word:
    - "PASS" if the response follows the steps in order
    - "FAIL" if the response skips steps or does them out of order

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Does response follow verification steps?
  defp judge_verification_steps(response_text) do
    prompt = """
    You are evaluating whether an AI assistant followed verification steps.

    SKILL DEFINITION: /deploy-check
    Steps (IN ORDER):
    1. Check that tests pass
    2. Verify no uncommitted changes
    3. Check deployment config exists
    4. Report status

    USER REQUEST: "/deploy-check"

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response follow these verification steps?

    Good execution mentions:
    - Checking tests
    - Checking git status for uncommitted changes
    - Checking deployment config
    - Reporting the overall status

    Respond with ONLY one word:
    - "PASS" if the response follows all verification steps
    - "FAIL" if the response skips verification steps

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Does response handle conditional logic?
  defp judge_conditional_steps(response_text) do
    prompt = """
    You are evaluating whether an AI assistant handled conditional logic.

    SKILL DEFINITION: /smart-commit
    Steps:
    1. Check git status
    2. IF there are changes: generate message and commit
    3. IF no changes: report "Nothing to commit"

    USER REQUEST: "/smart-commit"

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response handle the conditional logic?

    Good execution:
    - Mentions checking git status FIRST
    - Then either commits (if changes) OR reports nothing to commit (if no changes)
    - Shows understanding of the conditional branch

    Respond with ONLY one word:
    - "PASS" if the response handles conditional logic correctly
    - "FAIL" if the response doesn't handle conditionals

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Does response complete all required steps?
  defp judge_completeness(response_text) do
    prompt = """
    You are evaluating whether an AI assistant completed ALL required steps.

    SKILL DEFINITION: /full-setup
    Required steps (ALL must be done):
    1. Install dependencies
    2. Set up database
    3. Run migrations
    4. Seed test data
    5. Verify setup

    USER REQUEST: "/full-setup"

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response mention ALL 5 steps?

    Check that the response includes:
    1. Installing dependencies
    2. Setting up database
    3. Running migrations
    4. Seeding test data
    5. Verifying setup

    ALL steps must be present (not just some).

    Respond with ONLY one word:
    - "PASS" if ALL 5 steps are mentioned/performed
    - "FAIL" if any step is missing

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end
end
