defmodule Deft.Eval.Spilling.SummaryQualityTest do
  @moduledoc """
  Eval tests for tool result spilling summary quality.

  Tests that summaries:
  - Contain a parseable cache:// reference (100% hard assertion)
  - Mention result count/size (100% hard assertion)
  - Stay below threshold (100% hard assertion)
  - LLM judges as useful for decision-making (85% over 20 iterations)
  """

  use ExUnit.Case, async: false

  alias Deft.Eval.Helpers
  alias Deft.Message.Text
  alias Deft.Store
  alias Deft.Tool.Context
  alias Deft.Tools.{Grep, Ls, Read}

  @moduletag :eval
  @moduletag :expensive

  @iterations 20
  @quality_threshold 0.85

  setup do
    # Start a test cache store
    session_id = "spilling-summary-#{:erlang.unique_integer([:positive])}"

    {:ok, registry_pid} =
      Registry.start_link(keys: :unique, name: :"registry_#{session_id}")

    {:ok, store_pid} =
      Store.start_link(
        name: {:via, Registry, {:"registry_#{session_id}", {:cache, session_id, "main"}}}
      )

    working_dir = File.cwd!()

    context = %Context{
      session_id: session_id,
      working_dir: working_dir,
      emit: fn _ -> :ok end,
      bash_timeout: 120_000,
      cache_tid: store_pid,
      cache_config: %{
        "grep" => 1_000,
        "read" => 1_000,
        "ls" => 1_000,
        "default" => 1_000
      }
    }

    on_exit(fn ->
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
      if Process.alive?(registry_pid), do: GenServer.stop(registry_pid)
    end)

    {:ok, context: context, session_id: session_id, registry_name: :"registry_#{session_id}"}
  end

  describe "summary format - hard assertions" do
    test "grep summary contains cache:// reference", %{context: _context} do
      # Create a large grep result
      large_result = generate_grep_result(3000)

      summary = Grep.summarize([%Text{text: large_result}], "test-key-123")

      # Hard assertion: cache:// reference must be present
      assert summary =~ ~r/cache:\/\/test-key-123/
    end

    test "grep summary mentions match count", %{context: _context} do
      large_result = generate_grep_result(3000)
      summary = Grep.summarize([%Text{text: large_result}], "test-key-123")

      # Hard assertion: must mention number of matches
      assert summary =~ ~r/\d+ matches/
    end

    test "read summary contains cache:// reference", %{context: _context} do
      large_result = generate_read_result(3000)
      summary = Read.summarize([%Text{text: large_result}], "test-key-456")

      # Hard assertion: cache:// reference must be present
      assert summary =~ ~r/cache:\/\/test-key-456/
    end

    test "read summary mentions line count", %{context: _context} do
      large_result = generate_read_result(3000)
      summary = Read.summarize([%Text{text: large_result}], "test-key-456")

      # Hard assertion: must mention number of lines
      assert summary =~ ~r/\d+ lines/
    end

    test "ls summary contains cache:// reference", %{context: _context} do
      large_result = generate_ls_result(3000)
      summary = Ls.summarize([%Text{text: large_result}], "test-key-789")

      # Hard assertion: cache:// reference must be present
      assert summary =~ ~r/cache:\/\/test-key-789/
    end

    test "ls summary mentions file/directory count", %{context: _context} do
      large_result = generate_ls_result(3000)
      summary = Ls.summarize([%Text{text: large_result}], "test-key-789")

      # Hard assertion: must mention counts
      assert summary =~ ~r/\d+ (files|directories|items)/
    end
  end

  describe "summary size - hard assertion" do
    test "grep summary stays below threshold" do
      large_result = generate_grep_result(15_000)
      summary = Grep.summarize([%Text{text: large_result}], "test-key")

      # Summary should be much smaller than original
      summary_tokens = estimate_tokens(summary)
      assert summary_tokens < 1_000
    end

    test "read summary stays below threshold" do
      large_result = generate_read_result(15_000)
      summary = Read.summarize([%Text{text: large_result}], "test-key")

      summary_tokens = estimate_tokens(summary)
      assert summary_tokens < 1_000
    end

    test "ls summary stays below threshold" do
      large_result = generate_ls_result(15_000)
      summary = Ls.summarize([%Text{text: large_result}], "test-key")

      summary_tokens = estimate_tokens(summary)
      assert summary_tokens < 1_000
    end
  end

  describe "summary quality - LLM judge (85% over 20 iterations)" do
    @tag timeout: 180_000
    test "grep summaries provide enough information for agent decisions" do
      results =
        Enum.map(1..@iterations, fn i ->
          # Generate different sized results
          size = Enum.random([2_000, 5_000, 10_000, 15_000])
          result = generate_grep_result(size)
          summary = Grep.summarize([%Text{text: result}], "key-#{i}")

          # Ask LLM: does this summary give enough info to decide if full result is needed?
          judge_summary_quality(summary, result, "grep")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nGrep summary quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @quality_threshold,
             "Grep summary quality below threshold: #{Float.round(pass_rate * 100, 1)}% < #{@quality_threshold * 100}%"
    end

    @tag timeout: 180_000
    test "read summaries provide enough information for agent decisions" do
      results =
        Enum.map(1..@iterations, fn i ->
          size = Enum.random([2_000, 5_000, 10_000, 15_000])
          result = generate_read_result(size)
          summary = Read.summarize([%Text{text: result}], "key-#{i}")

          judge_summary_quality(summary, result, "read")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nRead summary quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @quality_threshold
    end

    @tag timeout: 180_000
    test "ls summaries provide enough information for agent decisions" do
      results =
        Enum.map(1..@iterations, fn i ->
          size = Enum.random([2_000, 5_000, 10_000, 15_000])
          result = generate_ls_result(size)
          summary = Ls.summarize([%Text{text: result}], "key-#{i}")

          judge_summary_quality(summary, result, "ls")
        end)

      pass_count = Enum.count(results, & &1)
      pass_rate = pass_count / @iterations

      IO.puts(
        "\nLs summary quality: #{pass_count}/#{@iterations} (#{Float.round(pass_rate * 100, 1)}%)"
      )

      assert pass_rate >= @quality_threshold
    end
  end

  # Helper: Generate realistic grep output
  defp generate_grep_result(target_tokens) do
    # Approximate tokens as words / 1.3
    target_words = round(target_tokens * 1.3)
    # ~10 words per line
    lines_needed = div(target_words, 10)

    1..lines_needed
    |> Enum.map(fn i ->
      file = "src/module#{rem(i, 20)}.ex"
      line_num = 100 + i * 5
      content = "defmodule Something#{i} do # Some code here that matches pattern"
      "#{file}:#{line_num}:#{content}"
    end)
    |> Enum.join("\n")
  end

  # Helper: Generate realistic read output
  defp generate_read_result(target_tokens) do
    target_words = round(target_tokens * 1.3)
    lines_needed = div(target_words, 8)

    lines =
      1..lines_needed
      |> Enum.map(fn i ->
        "#{String.pad_leading(to_string(i), 6)}→  # This is line #{i} of the file with some code"
      end)
      |> Enum.join("\n")

    lines <> "\n\n(#{lines_needed} of #{lines_needed} lines)"
  end

  # Helper: Generate realistic ls output
  defp generate_ls_result(target_tokens) do
    target_words = round(target_tokens * 1.3)
    entries_needed = div(target_words, 6)

    1..entries_needed
    |> Enum.map(fn i ->
      type = if rem(i, 4) == 0, do: "d", else: "-"
      perms = "rwxr-xr-x"
      size = :rand.uniform(100_000)
      date = "Mar 18 14:30"
      name = "file_#{i}.ex"
      "#{type}#{perms}  1 user  staff  #{size}  #{date}  #{name}"
    end)
    |> Enum.join("\n")
  end

  # Helper: Estimate token count (rough approximation)
  defp estimate_tokens(text) do
    # Rough estimate: byte_size / 4
    div(byte_size(text), 4)
  end

  # Helper: Judge summary quality using LLM
  defp judge_summary_quality(summary, full_result, tool_name) do
    # Build a judge prompt that asks if the summary provides enough information
    # for an agent to decide whether they need to see the full result
    prompt = """
    You are evaluating the quality of a tool result summary in an AI coding agent.

    The agent needs to decide: "Do I need to retrieve the full cached result, or is this summary sufficient?"

    Tool: #{tool_name}

    SUMMARY:
    #{summary}

    FULL RESULT (first 1000 chars):
    #{String.slice(full_result, 0, 1000)}

    Your task: Judge if the summary contains enough information for an agent to make an informed decision about whether to retrieve the full result.

    A GOOD summary should:
    - Indicate what type of content is in the full result
    - Mention key counts/sizes (number of matches, lines, files, etc.)
    - Include a representative preview of the content
    - Reference where the full result is cached

    Respond with ONLY one word:
    - "PASS" if the summary provides enough decision-making information
    - "FAIL" if the summary is too vague or missing critical information

    Your judgment:
    """

    case Helpers.call_llm_judge(prompt) do
      {:ok, judgment} ->
        # Parse judgment - check if it contains "PASS"
        String.upcase(String.trim(judgment)) =~ ~r/PASS/

      {:error, reason} ->
        # Log the error and fail this iteration
        IO.puts("LLM judge error: #{inspect(reason)}")
        false
    end
  end
end
