defmodule Deft.Eval.Skills.SuggestionTest do
  @moduledoc """
  Eval tests for skill suggestion (auto-selection).

  Tests that the agent suggests appropriate skills when relevant contexts arise.
  Per spec section 8.1, the agent should:
  - Suggest `/commit` or `/review` when user indicates code is ready
  - Suggest `/deploy-check` when user asks about deployment readiness
  - Suggest `/review` when user discusses code quality
  - NOT spam suggestions during normal coding work

  Pass rate: 80% over 20 iterations
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
  @pass_threshold 0.80

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "skill suggestion - LLM judge (80% over 20 iterations)" do
    @tag timeout: 180_000
    test "suggests commit skill when user indicates readiness", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_commit_ready_conversation()

          # Collect response text
          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response suggest /commit or /review?
          judge_commit_suggestion(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill suggestion (commit): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Skill suggestion below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "suggests deploy-check when asked about deployment", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_deployment_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response suggest /deploy-check?
          judge_deploy_suggestion(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill suggestion (deploy): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "suggests review when discussing code quality", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_quality_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Does the response suggest /review?
          judge_review_suggestion(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill suggestion (review): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "does NOT spam suggestions during normal work", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = build_normal_coding_conversation()

          response_text = call_provider_and_collect_text(messages, config)

          # Judge: Response should NOT suggest skills
          judge_no_spam(response_text)
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nSkill suggestion (no spam): #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build conversation where user indicates code is ready to commit
  defp build_commit_ready_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant. You have access to these skills:
          - /commit: Create a git commit with changes
          - /review: Review code quality and suggest improvements
          - /deploy-check: Check if code is ready for deployment

          When appropriate, you can suggest these skills to the user by mentioning them in your response.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "I think this is ready to commit. What do you think?"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build conversation about deployment readiness
  defp build_deployment_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant. You have access to these skills:
          - /commit: Create a git commit with changes
          - /review: Review code quality and suggest improvements
          - /deploy-check: Check if code is ready for deployment

          When appropriate, you can suggest these skills to the user by mentioning them in your response.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "Is this code ready for deployment to production?"}],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build conversation about code quality
  defp build_quality_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant. You have access to these skills:
          - /commit: Create a git commit with changes
          - /review: Review code quality and suggest improvements
          - /deploy-check: Check if code is ready for deployment

          When appropriate, you can suggest these skills to the user by mentioning them in your response.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [
        %Text{
          text:
            "I'm concerned about the quality of this code. Are there any improvements we should make?"
        }
      ],
      timestamp: DateTime.utc_now()
    }

    [system_message, user_message]
  end

  # Helper: Build normal coding conversation (no skill needed)
  defp build_normal_coding_conversation do
    system_message = %Message{
      id: "sys_prompt",
      role: :system,
      content: [
        %Text{
          text: """
          You are a helpful AI coding assistant. You have access to these skills:
          - /commit: Create a git commit with changes
          - /review: Review code quality and suggest improvements
          - /deploy-check: Check if code is ready for deployment

          When appropriate, you can suggest these skills to the user by mentioning them in your response.
          """
        }
      ],
      timestamp: DateTime.utc_now()
    }

    user_message = %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: "What's the difference between a GenServer and a Task?"}],
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

  # Judge: Does response suggest /commit or /review for commit-ready scenario?
  defp judge_commit_suggestion(response_text) do
    prompt = """
    You are evaluating whether an AI assistant appropriately suggested a skill.

    USER CONTEXT: User said "I think this is ready to commit. What do you think?"
    AVAILABLE SKILLS: /commit, /review, /deploy-check

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response suggest using /commit or /review?

    A good suggestion might say:
    - "You can use /commit to create a commit"
    - "Try /review to check the code first"
    - "Would you like me to run /commit?"

    Respond with ONLY one word:
    - "PASS" if the response suggests /commit or /review
    - "FAIL" if the response doesn't suggest either skill

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Does response suggest /deploy-check for deployment scenario?
  defp judge_deploy_suggestion(response_text) do
    prompt = """
    You are evaluating whether an AI assistant appropriately suggested a skill.

    USER CONTEXT: User asked "Is this code ready for deployment to production?"
    AVAILABLE SKILLS: /commit, /review, /deploy-check

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response suggest using /deploy-check?

    A good suggestion might say:
    - "You can use /deploy-check to verify deployment readiness"
    - "Try /deploy-check to check"
    - "Would you like me to run /deploy-check?"

    Respond with ONLY one word:
    - "PASS" if the response suggests /deploy-check
    - "FAIL" if the response doesn't suggest /deploy-check

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Does response suggest /review for quality scenario?
  defp judge_review_suggestion(response_text) do
    prompt = """
    You are evaluating whether an AI assistant appropriately suggested a skill.

    USER CONTEXT: User said "I'm concerned about the quality of this code. Are there any improvements we should make?"
    AVAILABLE SKILLS: /commit, /review, /deploy-check

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response suggest using /review?

    A good suggestion might say:
    - "You can use /review to check code quality"
    - "Try /review for quality improvements"
    - "Would you like me to run /review?"

    Respond with ONLY one word:
    - "PASS" if the response suggests /review
    - "FAIL" if the response doesn't suggest /review

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        false
    end
  end

  # Judge: Response should NOT spam skill suggestions during normal work
  defp judge_no_spam(response_text) do
    prompt = """
    You are evaluating whether an AI assistant inappropriately spammed skill suggestions.

    USER CONTEXT: User asked "What's the difference between a GenServer and a Task?"
    This is a normal technical question - NO skill suggestion is needed.

    AVAILABLE SKILLS: /commit, /review, /deploy-check

    ASSISTANT RESPONSE:
    #{response_text}

    QUESTION: Does the assistant's response avoid suggesting skills when none are relevant?

    The assistant SHOULD:
    - Answer the question about GenServer vs Task
    - NOT mention /commit, /review, or /deploy-check

    Respond with ONLY one word:
    - "PASS" if the response doesn't suggest any skills (good restraint)
    - "FAIL" if the response inappropriately suggests skills

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
