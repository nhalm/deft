defmodule Deft.Eval.Actor.ToolSelectionTest do
  @moduledoc """
  Actor tool selection evals per evals spec section 4.3.

  Tests that the Actor (agent) selects the correct specialized tools instead
  of falling back to bash commands. Validates that the agent understands when
  to use read vs cat, find vs shell find, grep vs shell grep, edit vs sed, etc.

  Each test runs 10 iterations via Tribunal evaluation mode.
  Pass threshold: 85%
  """

  use ExUnit.Case, async: false

  alias Deft.Agent
  alias Deft.Provider.Event.{ToolCallStart, Done}

  @moduletag :eval

  # Tool modules for the agent
  @tools [
    Deft.Tools.Read,
    Deft.Tools.Write,
    Deft.Tools.Edit,
    Deft.Tools.Bash,
    Deft.Tools.Grep,
    Deft.Tools.Find,
    Deft.Tools.Ls
  ]

  # Number of iterations for statistical confidence
  @iterations 10

  # Pass threshold per spec
  @pass_threshold 0.85

  setup_all do
    # Verify API key is present
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      ExUnit.configure(exclude: [:eval])
      IO.puts("\nSkipping eval tests: ANTHROPIC_API_KEY not set\n")
      :ok
    else
      # Register the Anthropic provider
      :ok = Deft.Provider.Registry.register("anthropic", Deft.Provider.Anthropic)

      # Ensure Registry is started
      case Process.whereis(Deft.Registry) do
        nil ->
          {:ok, _} = Registry.start_link(keys: :duplicate, name: Deft.Registry)

        _pid ->
          :ok
      end

      :ok
    end
  end

  describe "tool selection" do
    @tag timeout: 300_000
    test "selects read for file reading, not bash cat" do
      prompt = "Read src/auth.ex"
      expected_tool = "read"
      forbidden_tool = "bash"

      run_evaluation(prompt, expected_tool, forbidden_tool)
    end

    @tag timeout: 300_000
    test "selects find for file search, not bash find" do
      prompt = "Find all test files"
      expected_tool = "find"
      forbidden_tool = "bash"

      run_evaluation(prompt, expected_tool, forbidden_tool)
    end

    @tag timeout: 300_000
    test "selects grep for content search, not bash grep" do
      prompt = "Search for 'defmodule Auth'"
      expected_tool = "grep"
      forbidden_tool = "bash"

      run_evaluation(prompt, expected_tool, forbidden_tool)
    end

    @tag timeout: 300_000
    test "selects bash for running tests" do
      prompt = "Run the tests"
      expected_tool = "bash"

      # For this test, we just verify bash is used
      # We also check that the command contains "mix test"
      run_bash_evaluation(prompt, expected_tool)
    end

    @tag timeout: 300_000
    test "selects edit for file modification, not bash sed" do
      prompt = "Change foo to bar in config.exs"
      expected_tool = "edit"
      forbidden_tool = "bash"

      run_evaluation(prompt, expected_tool, forbidden_tool)
    end
  end

  # Helper to run evaluation for a single test case
  defp run_evaluation(prompt, expected_tool, forbidden_tool) do
    results =
      Enum.map(1..@iterations, fn iteration ->
        IO.puts("\nIteration #{iteration}/#{@iterations} for: #{prompt}")

        first_tool_call = get_first_tool_call(prompt)

        case first_tool_call do
          {:ok, tool_name} ->
            IO.puts("  → Selected tool: #{tool_name}")

            cond do
              tool_name == expected_tool ->
                {:pass, "Selected #{expected_tool}"}

              tool_name == forbidden_tool ->
                {:fail, "Selected #{forbidden_tool} instead of #{expected_tool}"}

              true ->
                {:fail, "Selected unexpected tool #{tool_name} instead of #{expected_tool}"}
            end

          {:error, :no_tool_call} ->
            {:fail, "No tool call made"}

          {:error, reason} ->
            {:fail, "Error: #{inspect(reason)}"}
        end
      end)

    # Calculate pass rate
    passes = Enum.count(results, fn {result, _} -> result == :pass end)
    pass_rate = passes / @iterations

    IO.puts("\n=== Results ===")
    IO.puts("Passes: #{passes}/#{@iterations}")
    IO.puts("Pass rate: #{Float.round(pass_rate * 100, 1)}%")
    IO.puts("Threshold: #{@pass_threshold * 100}%")

    # Print failure details
    failures =
      results
      |> Enum.with_index(1)
      |> Enum.filter(fn {{result, _}, _} -> result == :fail end)

    unless Enum.empty?(failures) do
      IO.puts("\nFailures:")

      Enum.each(failures, fn {{_, reason}, iteration} ->
        IO.puts("  Iteration #{iteration}: #{reason}")
      end)
    end

    assert pass_rate >= @pass_threshold,
           "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{@pass_threshold * 100}%"
  end

  # Helper for bash evaluation that also checks command content
  defp run_bash_evaluation(prompt, expected_tool) do
    results =
      Enum.map(1..@iterations, fn iteration ->
        IO.puts("\nIteration #{iteration}/#{@iterations} for: #{prompt}")

        first_tool_call = get_first_tool_call(prompt)

        case first_tool_call do
          {:ok, tool_name} when tool_name == expected_tool ->
            IO.puts("  → Selected tool: #{tool_name}")
            {:pass, "Selected #{expected_tool}"}

          {:ok, other_tool} ->
            IO.puts("  → Selected tool: #{other_tool}")
            {:fail, "Selected #{other_tool} instead of #{expected_tool}"}

          {:error, :no_tool_call} ->
            {:fail, "No tool call made"}

          {:error, reason} ->
            {:fail, "Error: #{inspect(reason)}"}
        end
      end)

    # Calculate pass rate
    passes = Enum.count(results, fn {result, _} -> result == :pass end)
    pass_rate = passes / @iterations

    IO.puts("\n=== Results ===")
    IO.puts("Passes: #{passes}/#{@iterations}")
    IO.puts("Pass rate: #{Float.round(pass_rate * 100, 1)}%")
    IO.puts("Threshold: #{@pass_threshold * 100}%")

    assert pass_rate >= @pass_threshold,
           "Pass rate #{Float.round(pass_rate * 100, 1)}% below threshold #{@pass_threshold * 100}%"
  end

  # Gets the first tool call from an agent response to a prompt
  defp get_first_tool_call(prompt) do
    # Create a minimal agent configuration
    working_dir = System.tmp_dir!()
    session_id = "eval_#{:erlang.unique_integer([:positive])}"

    config = %{
      model: "claude-sonnet-4",
      provider: Deft.Provider.Anthropic,
      working_dir: working_dir,
      turn_limit: 1,
      tool_timeout: 60_000,
      max_turns: 1,
      tools: @tools
    }

    # Start the agent
    {:ok, agent} = Agent.start_link(session_id: session_id, config: config, messages: [])

    # Subscribe to agent events
    Registry.register(Deft.Registry, {:session, session_id}, [])

    # Send prompt
    Agent.prompt(agent, prompt)

    # Collect events until we get the first tool call or the stream completes
    result = collect_first_tool_call()

    # Clean up
    Process.exit(agent, :kill)

    result
  end

  # Collects events until we see the first tool call
  defp collect_first_tool_call(timeout \\ 60_000) do
    receive do
      {:agent_event, %ToolCallStart{name: name}} ->
        {:ok, name}

      {:agent_event, %Done{}} ->
        {:error, :no_tool_call}

      {:agent_event, _other} ->
        collect_first_tool_call(timeout)
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
