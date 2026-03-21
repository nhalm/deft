defmodule Deft.Eval.Observer.DedupTest do
  @moduledoc """
  Eval tests for Observer deduplication behavior.

  Tests that the Observer does NOT re-extract facts that are already present
  in existing observations. When the same information appears in new messages,
  it should be recognized as duplicate and not added again.

  Pass rate: 80% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.Eval.Helpers
  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.80

  setup do
    config = Config.load()
    {:ok, config: config}
  end

  describe "deduplication - LLM judge (80% over 20 iterations)" do
    @tag timeout: 180_000
    test "does not re-extract tech choice already observed", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Existing observations mention PostgreSQL
          existing = """
          ## User Preferences

          - Uses PostgreSQL for database
          """

          # New messages repeat the same fact
          messages = [
            build_user_message("As I mentioned, we're using PostgreSQL")
          ]

          result = Observer.run(config, messages, existing, 4.0)

          # Judge: New observations should NOT duplicate PostgreSQL mention
          judge_no_duplication(existing, result.observations, "PostgreSQL")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nTech choice dedup: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "does not re-extract file operations already observed", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          existing = """
          ## Files & Architecture

          - Read lib/auth.ex - contains Bcrypt password verification
          """

          # Same file read again with same content
          messages = [
            build_tool_result_message("""
            File: lib/auth.ex

            defmodule MyApp.Auth do
              def verify_password(password, hash) do
                Bcrypt.verify_pass(password, hash)
              end
            end
            """)
          ]

          result = Observer.run(config, messages, existing, 4.0)

          # Judge: Should not duplicate lib/auth.ex observation
          judge_no_duplication(existing, result.observations, "lib/auth.ex")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nFile operation dedup: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "does not re-extract decisions already observed", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          existing = """
          ## Decisions

          - Using gen_statem for agent loop state machine
          """

          messages = [
            build_user_message("Since we decided on gen_statem, let's implement the first state")
          ]

          result = Observer.run(config, messages, existing, 4.0)

          # Judge: Should not duplicate gen_statem decision
          judge_no_duplication(existing, result.observations, "gen_statem")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nDecision dedup: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "does not re-extract preferences already observed", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          existing = """
          ## User Preferences

          - Prefers 2-space indentation
          - Likes descriptive variable names
          """

          messages = [
            build_user_message("Make sure to use 2-space indentation like I prefer")
          ]

          result = Observer.run(config, messages, existing, 4.0)

          # Judge: Should not duplicate indentation preference
          judge_no_duplication(existing, result.observations, "indentation")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nPreference dedup: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "does not re-extract error patterns already observed", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          existing = """
          ## Session History

          - Encountered CompileError in lib/foo.ex:42 - undefined function bar/1
          """

          messages = [
            build_bash_result_message("""
            ** (CompileError) lib/foo.ex:42: undefined function bar/1
            """)
          ]

          result = Observer.run(config, messages, existing, 4.0)

          # Judge: Should not duplicate the same error
          judge_no_duplication(existing, result.observations, "CompileError")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts("\nError dedup: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)")

      assert pass_rate >= @pass_threshold
    end
  end

  # Helper: Build a user message
  defp build_user_message(text) do
    %Message{
      id: generate_id(),
      role: :user,
      content: [%Text{text: text}],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build a tool result message
  defp build_tool_result_message(text) do
    %Message{
      id: generate_id(),
      role: :user,
      content: [
        %Deft.Message.ToolResult{
          tool_use_id: generate_id(),
          name: "Read",
          content: text,
          is_error: false
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Build a bash result message
  defp build_bash_result_message(text) do
    %Message{
      id: generate_id(),
      role: :user,
      content: [
        %Deft.Message.ToolResult{
          tool_use_id: generate_id(),
          name: "Bash",
          content: text,
          is_error: false
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  # Helper: Generate unique ID
  defp generate_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Helper: Judge that new observations don't duplicate existing ones
  defp judge_no_duplication(existing_obs, new_obs, key_term) do
    # Use LLM judge to detect redundant extraction
    prompt = """
    You are checking for redundant fact extraction in observation notes.

    EXISTING OBSERVATIONS:
    #{existing_obs}

    NEW OBSERVATIONS:
    #{new_obs}

    KEY TERM: #{key_term}

    QUESTION: Do the new observations redundantly re-state information about "#{key_term}"
    that was already captured in the existing observations?

    Good deduplication means:
    - If existing observations already mention #{key_term}, new observations should NOT repeat it
    - New observations can ADD information about #{key_term} if it's genuinely new
    - But NEW observations should NOT just restate what's already there

    Respond with ONLY one word:
    - "PASS" if there is NO redundant duplication (new observations don't repeat existing info)
    - "FAIL" if there IS redundant duplication (new observations restate what's already captured)

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        # PASS means no duplication (good)
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, _reason} ->
        # On error, fail conservatively
        false
    end
  end
end
