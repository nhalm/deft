defmodule Deft.Eval.Observer.ExtractionTest do
  @moduledoc """
  Eval tests for Observer fact extraction.

  Tests that the Observer correctly extracts explicit facts from conversations
  including tech choices, preferences, file operations, errors, commands,
  architectural decisions, dependencies, and deferred work.

  Pass rate: 85% over 20 iterations
  """

  use ExUnit.Case, async: false

  alias Deft.{Config, Message}
  alias Deft.Message.Text
  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @pass_threshold 0.85

  setup do
    # Use default config with observer settings
    config = Config.load()

    {:ok, config: config}
  end

  describe "fact extraction - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "extracts explicit tech choices", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Fixture: User explicitly states a tech choice
          messages = [
            build_user_message("We use PostgreSQL for our database")
          ]

          # Run Observer extraction
          result = Observer.run(config, messages, "", 4.0)

          # Judge: Does the observation contain "PostgreSQL"?
          judge_extraction(result.observations, "PostgreSQL")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nExplicit tech choice extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold,
             "Tech choice extraction below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@pass_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "extracts preference statements", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("I prefer spaces over tabs")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Must contain both "spaces" and "prefer"
          judge_extraction_multi(result.observations, ["spaces", "prefer"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nPreference extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts file read events", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          # Simulate a tool result for file read
          messages = [
            build_tool_result_message("""
            File: src/auth.ex

            defmodule MyApp.Auth do
              def verify_password(password, hash) do
                Bcrypt.verify_pass(password, hash)
              end
            end
            """)
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Must contain the file path
          judge_extraction(result.observations, "src/auth.ex")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nFile read extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts error messages", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_bash_result_message("""
            ** (CompileError) lib/my_module.ex:42: undefined function foo/1
            """)
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Should contain reference to the error
          judge_extraction_multi(result.observations, ["CompileError", "line 42", "undefined"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nError extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts command execution results", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_bash_result_message("""
            $ mix test
            ..........F.F

            12 tests, 2 failures
            """)
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Should contain command and failure count
          judge_extraction_multi(result.observations, ["mix test", "2 failures"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nCommand result extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts architectural decisions with rationale", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message(
              "Let's use gen_statem for the agent loop because it has explicit states"
            )
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Should contain both the tech choice and rationale
          judge_extraction_multi(result.observations, ["gen_statem", "explicit states"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nArchitectural decision extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts dependency additions", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("Add jason ~> 1.4 to the deps")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Should contain dependency name and version
          judge_extraction_multi(result.observations, ["jason", "1.4"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nDependency extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @pass_threshold
    end

    @tag timeout: 180_000
    test "extracts deferred work items", %{config: config} do
      results =
        Enum.map(1..@iterations, fn _i ->
          messages = [
            build_user_message("We still need to handle the error case later")
          ]

          result = Observer.run(config, messages, "", 4.0)

          # Should note deferred work
          judge_extraction_multi(result.observations, ["error case", "later"])
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nDeferred work extraction: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

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

  # Helper: Build a tool result message (simulating Read tool)
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

  # Helper: Judge if observation contains a specific term
  defp judge_extraction(observations, expected_term) do
    # Simple containment check - case insensitive
    String.downcase(observations) =~ String.downcase(expected_term)
  end

  # Helper: Judge if observation contains all terms
  defp judge_extraction_multi(observations, expected_terms) do
    downcase_obs = String.downcase(observations)

    Enum.all?(expected_terms, fn term ->
      downcase_obs =~ String.downcase(term)
    end)
  end
end
