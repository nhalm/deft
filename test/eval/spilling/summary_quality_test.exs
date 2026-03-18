defmodule Deft.Eval.Spilling.SummaryQualityTest do
  use ExUnit.Case, async: true
  use Tribunal.EvalCase

  alias Tribunal.Assertions
  alias Tribunal.TestCase

  @moduletag :eval
  @moduletag :expensive

  @threshold_grep 8000
  @threshold_read 12000
  @threshold_ls 4000

  # Number of iterations for statistical tests
  @iterations 20
  @pass_threshold 0.85

  describe "grep summary quality" do
    test "500 token result - deterministic format checks" do
      result = generate_grep_result(500)
      summary = generate_grep_summary(result)

      # Hard assertions - must pass 100%
      assert_cache_reference(summary)
      assert_mentions_count(summary)
      assert_below_threshold(summary, @threshold_grep)
    end

    test "500 token result - LLM quality check (20 iterations)" do
      run_statistical_test(500, :grep, @iterations, @pass_threshold)
    end

    test "2k token result - LLM quality check (20 iterations)" do
      run_statistical_test(2000, :grep, @iterations, @pass_threshold)
    end

    test "5k token result - LLM quality check (20 iterations)" do
      run_statistical_test(5000, :grep, @iterations, @pass_threshold)
    end

    test "15k token result - LLM quality check (20 iterations)" do
      run_statistical_test(15000, :grep, @iterations, @pass_threshold)
    end
  end

  describe "read summary quality" do
    test "500 token result - deterministic format checks" do
      result = generate_read_result(500)
      summary = generate_read_summary(result)

      # Hard assertions - must pass 100%
      assert_cache_reference(summary)
      assert_mentions_line_count(summary)
      assert_below_threshold(summary, @threshold_read)
    end

    test "2k token result - LLM quality check (20 iterations)" do
      run_statistical_test(2000, :read, @iterations, @pass_threshold)
    end

    test "5k token result - LLM quality check (20 iterations)" do
      run_statistical_test(5000, :read, @iterations, @pass_threshold)
    end

    test "15k token result - LLM quality check (20 iterations)" do
      run_statistical_test(15000, :read, @iterations, @pass_threshold)
    end
  end

  describe "ls summary quality" do
    test "500 token result - deterministic format checks" do
      result = generate_ls_result(500)
      summary = generate_ls_summary(result)

      # Hard assertions - must pass 100%
      assert_cache_reference(summary)
      assert_mentions_file_count(summary)
      assert_below_threshold(summary, @threshold_ls)
    end

    test "2k token result - LLM quality check (20 iterations)" do
      run_statistical_test(2000, :ls, @iterations, @pass_threshold)
    end

    test "5k token result - LLM quality check (20 iterations)" do
      run_statistical_test(5000, :ls, @iterations, @pass_threshold)
    end

    test "15k token result - LLM quality check (20 iterations)" do
      run_statistical_test(15000, :ls, @iterations, @pass_threshold)
    end
  end

  # Statistical test runner
  defp run_statistical_test(token_count, tool_type, iterations, threshold) do
    judge_prompt = get_judge_prompt(tool_type)

    results =
      Enum.map(1..iterations, fn _i ->
        result = generate_tool_result(token_count, tool_type)
        summary = generate_tool_summary(result, tool_type)

        # Use Tribunal's faithful assertion and return pass/fail
        test_case = %TestCase{
          actual_output: summary,
          context: [result]
        }

        case Assertions.evaluate(:faithful, test_case, judge_prompt: judge_prompt) do
          {:pass, _} -> :pass
          {:fail, _} -> :fail
        end
      end)

    pass_count = Enum.count(results, &(&1 == :pass))
    pass_rate = pass_count / iterations

    # Calculate confidence interval (Wilson score interval)
    {ci_low, ci_high} = wilson_ci(pass_count, iterations)

    # Assert pass rate meets threshold
    assert pass_rate >= threshold,
           """
           Pass rate #{Float.round(pass_rate * 100, 1)}% (#{pass_count}/#{iterations}) below threshold #{Float.round(threshold * 100, 1)}%
           95% CI: [#{Float.round(ci_low * 100, 1)}%-#{Float.round(ci_high * 100, 1)}%]
           """
  end

  # Wilson score confidence interval for 95% confidence
  defp wilson_ci(successes, trials) do
    if trials == 0 do
      {0.0, 0.0}
    else
      p = successes / trials
      z = 1.96
      denominator = 1 + z * z / trials

      center = p + z * z / (2 * trials)
      spread = z * :math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials))

      {
        (center - spread) / denominator,
        (center + spread) / denominator
      }
    end
  end

  defp get_judge_prompt(:grep) do
    """
    You are evaluating a summary of grep search results.

    Does this summary give the agent enough information to decide whether it needs the full result?

    A good summary should include:
    - Total number of matches
    - Number of files matched
    - Representative examples of the matches
    - Clear reference to where full results can be found

    Answer YES if the summary provides sufficient decision-making context, NO otherwise.
    """
  end

  defp get_judge_prompt(:read) do
    """
    You are evaluating a summary of a file read result.

    Does this summary give the agent enough information to decide whether it needs the full result?

    A good summary should include:
    - Total number of lines in the file
    - First N lines of the file (enough to understand structure)
    - Clear reference to where full results can be found

    Answer YES if the summary provides sufficient decision-making context, NO otherwise.
    """
  end

  defp get_judge_prompt(:ls) do
    """
    You are evaluating a summary of a directory listing result.

    Does this summary give the agent enough information to decide whether it needs the full result?

    A good summary should include:
    - Total number of files
    - Number of directories
    - Top-level directory structure
    - Clear reference to where full results can be found

    Answer YES if the summary provides sufficient decision-making context, NO otherwise.
    """
  end

  defp generate_tool_result(token_count, :grep), do: generate_grep_result(token_count)
  defp generate_tool_result(token_count, :read), do: generate_read_result(token_count)
  defp generate_tool_result(token_count, :ls), do: generate_ls_result(token_count)

  defp generate_tool_summary(result, :grep), do: generate_grep_summary(result)
  defp generate_tool_summary(result, :read), do: generate_read_summary(result)
  defp generate_tool_summary(result, :ls), do: generate_ls_summary(result)

  # Helper functions for generating tool results

  defp generate_grep_result(target_tokens) do
    # Rough estimation: 1 token ~= 4 characters
    target_chars = target_tokens * 4

    # Generate realistic grep output
    files = ["lib/accounts/user.ex", "lib/accounts/session.ex", "lib/orders/order.ex"]

    # Build up matches until we reach target size
    generate_grep_lines(target_chars, files, [], 0, 1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp generate_grep_lines(target_chars, _files, acc, current_size, _line_num)
       when current_size >= target_chars do
    acc
  end

  defp generate_grep_lines(target_chars, files, acc, current_size, line_num) do
    file = Enum.random(files)
    line_text = generate_code_line()
    match = "  #{file}:#{line_num}: #{line_text}\n"

    generate_grep_lines(
      target_chars,
      files,
      [match | acc],
      current_size + String.length(match),
      line_num + 1
    )
  end

  defp generate_read_result(target_tokens) do
    target_chars = target_tokens * 4

    # Generate realistic file content
    generate_read_lines(target_chars, [], 0, 1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp generate_read_lines(target_chars, acc, current_size, _line_num)
       when current_size >= target_chars do
    acc
  end

  defp generate_read_lines(target_chars, acc, current_size, line_num) do
    line = "#{line_num}\t#{generate_code_line()}\n"

    generate_read_lines(
      target_chars,
      [line | acc],
      current_size + String.length(line),
      line_num + 1
    )
  end

  defp generate_ls_result(target_tokens) do
    target_chars = target_tokens * 4

    # Generate realistic directory listing
    dirs = ["src/accounts", "src/orders", "src/web", "test/accounts", "test/orders"]
    files = ["user.ex", "session.ex", "router.ex", "schema.ex", "query.ex"]

    generate_ls_entries(target_chars, dirs, files, [], 0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp generate_ls_entries(target_chars, _dirs, _files, acc, current_size)
       when current_size >= target_chars do
    acc
  end

  defp generate_ls_entries(target_chars, dirs, files, acc, current_size) do
    entry_type = if :rand.uniform() > 0.3, do: "file", else: "dir"

    entry =
      case entry_type do
        "dir" ->
          dir = Enum.random(dirs)
          file_count = :rand.uniform(50)
          "#{dir}/    (#{file_count} files)\n"

        "file" ->
          dir = Enum.random(dirs)
          file = Enum.random(files)
          "#{dir}/#{file}\n"
      end

    generate_ls_entries(
      target_chars,
      dirs,
      files,
      [entry | acc],
      current_size + String.length(entry)
    )
  end

  defp generate_code_line do
    templates = [
      "defstruct [:id, :email, :name]",
      "def changeset(user, attrs) do",
      "use Ecto.Schema",
      "import Ecto.Changeset",
      "@type t :: %__MODULE__{}",
      "schema \"users\" do",
      "field :email, :string",
      "timestamps()",
      "validates_presence_of :email"
    ]

    Enum.random(templates)
  end

  defp generate_grep_summary(result) do
    lines = String.split(result, "\n", trim: true)
    match_count = length(lines)

    files =
      lines
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [file, _] -> String.trim(file)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    file_count = length(files)

    # Show top 10 matches
    top_matches = Enum.take(lines, 10) |> Enum.join("\n")

    # Generate cache key
    cache_key = "cache://grep-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

    """
    #{match_count} matches across #{file_count} files. Top 10 shown:

    #{top_matches}

    Full results: #{cache_key}
    """
  end

  defp generate_read_summary(result) do
    lines = String.split(result, "\n", trim: true)
    line_count = length(lines)

    # Show first 100 lines
    first_lines = Enum.take(lines, 100) |> Enum.join("\n")

    # Generate cache key
    cache_key = "cache://read-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

    """
    File has #{line_count} lines. First 100 lines shown:

    #{first_lines}

    Full results: #{cache_key}
    """
  end

  defp generate_ls_summary(result) do
    lines = String.split(result, "\n", trim: true)

    # Count files and directories
    {dirs, files} =
      Enum.split_with(lines, fn line ->
        String.contains?(line, "(") and String.contains?(line, "files)")
      end)

    file_count = length(files)
    dir_count = length(dirs)

    # Show top-level structure (first 20 entries)
    top_structure = Enum.take(lines, 20) |> Enum.join("\n")

    # Generate cache key
    cache_key = "cache://ls-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

    """
    #{file_count + dir_count} entries (#{dir_count} directories, #{file_count} files). Top-level structure:

    #{top_structure}

    Full results: #{cache_key}
    """
  end

  # Assertion helpers

  defp assert_cache_reference(summary) do
    assert summary =~ ~r/cache:\/\/[a-z0-9-]+/,
           "Summary must contain a cache:// reference"
  end

  defp assert_mentions_count(summary) do
    assert summary =~ ~r/\d+ matches/i or summary =~ ~r/match count/i,
           "Summary must mention match count"
  end

  defp assert_mentions_line_count(summary) do
    assert summary =~ ~r/\d+ lines/i or summary =~ ~r/line count/i,
           "Summary must mention line count"
  end

  defp assert_mentions_file_count(summary) do
    assert summary =~ ~r/\d+ (entries|files)/i or summary =~ ~r/file count/i,
           "Summary must mention file count"
  end

  defp assert_below_threshold(summary, threshold) do
    # Rough token estimation: bytes / 4
    estimated_tokens = byte_size(summary) / 4

    assert estimated_tokens < threshold,
           "Summary must be below threshold (#{estimated_tokens} >= #{threshold})"
  end
end
