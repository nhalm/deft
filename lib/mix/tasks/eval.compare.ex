defmodule Mix.Tasks.Eval.Compare do
  @moduledoc """
  Compares two eval runs and shows differences.

  Usage:
      mix eval.compare <run_a> <run_b>

  Shows:
  - Categories that changed and by how much
  - Categories that dropped below soft floor
  - Failure examples side-by-side

  Per spec section 2.4.
  """

  use Mix.Task

  alias Deft.Eval.Baselines

  @shortdoc "Compare two eval runs"

  @impl Mix.Task
  def run(args) do
    # Ensure modules are compiled
    Mix.Task.run("compile")

    case args do
      [run_a, run_b] ->
        compare(run_a, run_b)

      _ ->
        Mix.shell().error("Usage: mix eval.compare <run_a> <run_b>")
        exit({:shutdown, 1})
    end
  end

  defp compare(run_a_id, run_b_id) do
    with {:ok, baselines} <- Baselines.load(),
         {:ok, run_a} <- load_run(run_a_id),
         {:ok, run_b} <- load_run(run_b_id) do
      print_comparison(run_a_id, run_b_id, run_a, run_b, baselines)
    else
      {:error, :not_found, run_id} ->
        Mix.shell().error("Run not found: #{run_id}")
        exit({:shutdown, 1})

      {:error, :corrupt_data, run_id} ->
        Mix.shell().error("Run file exists but contains corrupt JSONL data: #{run_id}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Failed to load data: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_comparison(run_a_id, run_b_id, run_a, run_b, baselines) do
    results_a = group_by_category(run_a)
    results_b = group_by_category(run_b)

    print_header(run_a_id, run_b_id)
    print_category_changes(results_a, results_b, baselines)
    print_soft_floor_violations(results_b, baselines)
    print_failure_comparisons(results_a, results_b)
  end

  defp load_run(run_id) do
    file_path = Path.join("test/eval/results", "#{run_id}.jsonl")

    case File.read(file_path) do
      {:ok, content} ->
        parse_jsonl_results(content, run_id)

      {:error, :enoent} ->
        {:error, :not_found, run_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_jsonl_results(content, run_id) do
    results =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&decode_json_line/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(results) do
      {:error, :corrupt_data, run_id}
    else
      {:ok, results}
    end
  end

  defp decode_json_line(line) do
    case Jason.decode(line) do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  end

  defp group_by_category(results) do
    Enum.into(results, %{}, fn result ->
      {result["category"], result}
    end)
  end

  defp print_header(run_a_id, run_b_id) do
    IO.puts("\n" <> IO.ANSI.bright() <> "Eval Comparison" <> IO.ANSI.reset())
    IO.puts("Run A: #{run_a_id}")
    IO.puts("Run B: #{run_b_id}")
    IO.puts("")
  end

  defp print_category_changes(results_a, results_b, baselines) do
    IO.puts(IO.ANSI.bright() <> "Category Changes:" <> IO.ANSI.reset())
    IO.puts("")

    all_categories =
      (Map.keys(results_a) ++ Map.keys(results_b))
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.empty?(all_categories) do
      IO.puts("  No categories found in either run")
    else
      Enum.each(all_categories, fn category ->
        print_single_category_change(category, results_a, results_b, baselines)
      end)
    end

    IO.puts("")
  end

  defp print_single_category_change(category, results_a, results_b, baselines) do
    rate_a = get_pass_rate(results_a, category)
    rate_b = get_pass_rate(results_b, category)

    case {rate_a, rate_b} do
      {nil, rate} ->
        IO.puts("  #{category}: NEW → #{format_rate(rate)}")

      {rate, nil} ->
        IO.puts("  #{category}: #{format_rate(rate)} → REMOVED")

      {rate_a, rate_b} ->
        print_category_diff(category, rate_a, rate_b, baselines)
    end
  end

  defp print_category_diff(category, rate_a, rate_b, baselines) do
    diff = rate_b - rate_a
    diff_str = format_diff(diff)
    color = diff_color(diff)

    # Check if below soft floor
    below_floor = Baselines.below_soft_floor?(baselines, category, rate_b)
    floor_marker = if below_floor, do: " ⚠️  BELOW SOFT FLOOR", else: ""

    IO.puts(
      "  #{category}: #{format_rate(rate_a)} → #{format_rate(rate_b)} " <>
        "#{color}#{diff_str}#{IO.ANSI.reset()}#{floor_marker}"
    )
  end

  defp print_soft_floor_violations(results_b, baselines) do
    violations = find_soft_floor_violations(results_b, baselines)

    unless Enum.empty?(violations) do
      print_violations_section(violations, baselines)
    end
  end

  defp find_soft_floor_violations(results, baselines) do
    results
    |> Enum.filter(fn {category, result} ->
      rate = result["pass_rate"]
      Baselines.below_soft_floor?(baselines, category, rate)
    end)
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  defp print_violations_section(violations, baselines) do
    IO.puts(IO.ANSI.bright() <> "Soft Floor Violations:" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(violations, fn {category, result} ->
      print_violation(category, result, baselines)
    end)

    IO.puts("")
  end

  defp print_violation(category, result, baselines) do
    rate = result["pass_rate"]
    baseline = Baselines.get_baseline(baselines, category)

    IO.puts(
      "  #{category}: #{format_rate(rate)} " <>
        IO.ANSI.red() <>
        "(below soft floor of #{format_rate(baseline.soft_floor)})" <> IO.ANSI.reset()
    )
  end

  defp print_failure_comparisons(results_a, results_b) do
    # Find categories that have failures in either run
    categories_with_failures =
      (Map.keys(results_a) ++ Map.keys(results_b))
      |> Enum.uniq()
      |> Enum.filter(fn category ->
        has_failures_a = has_failures?(results_a, category)
        has_failures_b = has_failures?(results_b, category)
        has_failures_a or has_failures_b
      end)
      |> Enum.sort()

    if Enum.empty?(categories_with_failures) do
      IO.puts(IO.ANSI.bright() <> "Failure Examples:" <> IO.ANSI.reset())
      IO.puts("")
      IO.puts("  No failures in either run")
      IO.puts("")
    else
      IO.puts(IO.ANSI.bright() <> "Failure Examples:" <> IO.ANSI.reset())
      IO.puts("")

      Enum.each(categories_with_failures, fn category ->
        print_category_failures(category, results_a, results_b)
      end)
    end
  end

  defp print_category_failures(category, results_a, results_b) do
    failures_a = get_failures(results_a, category)
    failures_b = get_failures(results_b, category)

    IO.puts("  #{IO.ANSI.cyan()}#{category}#{IO.ANSI.reset()}")
    IO.puts("")

    max_count = max(length(failures_a), length(failures_b))

    if max_count == 0 do
      IO.puts("    No failures")
    else
      print_run_failures("A", failures_a)
      IO.puts("")
      print_run_failures("B", failures_b)
    end

    IO.puts("")
  end

  defp print_run_failures(run_label, failures) do
    sample = Enum.take(failures, 3)

    IO.puts("    Run #{run_label} (#{length(failures)} failures):")

    if Enum.empty?(sample) do
      IO.puts("      (none)")
    else
      Enum.each(sample, &print_failure/1)
    end
  end

  defp print_failure(failure) do
    IO.puts("      - Fixture: #{failure["fixture"]}")
    IO.puts("        Reason: #{failure["reason"]}")
  end

  defp get_pass_rate(results, category) do
    case Map.get(results, category) do
      nil -> nil
      result -> result["pass_rate"]
    end
  end

  defp has_failures?(results, category) do
    case Map.get(results, category) do
      nil -> false
      result -> length(result["failures"] || []) > 0
    end
  end

  defp get_failures(results, category) do
    case Map.get(results, category) do
      nil -> []
      result -> result["failures"] || []
    end
  end

  defp format_rate(rate) when is_float(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  defp format_rate(nil), do: "N/A"

  defp format_diff(diff) when diff > 0 do
    "(+#{Float.round(diff * 100, 1)}pp)"
  end

  defp format_diff(diff) when diff < 0 do
    "(#{Float.round(diff * 100, 1)}pp)"
  end

  defp format_diff(_), do: "(no change)"

  defp diff_color(diff) when diff > 0, do: IO.ANSI.green()
  defp diff_color(diff) when diff < 0, do: IO.ANSI.red()
  defp diff_color(_), do: IO.ANSI.white()
end
