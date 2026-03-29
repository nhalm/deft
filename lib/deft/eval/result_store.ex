defmodule Deft.Eval.ResultStore do
  @moduledoc """
  Storage and retrieval for eval run results.

  Per spec section 2.1: stores per-run results as JSONL at test/eval/results/<run_id>.jsonl
  with commit SHA, model, category, pass_rate, iterations, cost, and failure examples.

  Automatically manages cleanup to keep only the last 30 runs on disk.
  """

  alias Deft.Eval

  @results_dir "test/eval/results"
  @max_runs_to_keep 30

  @type failure :: %{
          fixture: String.t(),
          output: String.t(),
          reason: String.t()
        }

  @type result :: %{
          run_id: Eval.run_id(),
          commit: String.t(),
          timestamp: String.t(),
          model: String.t(),
          category: Eval.category(),
          pass_rate: float(),
          iterations: non_neg_integer(),
          cost_usd: float(),
          failures: [failure()]
        }

  @doc """
  Generates a unique run ID for the current eval run.

  Format: YYYY-MM-DD-<6-hex-chars>
  """
  @spec generate_run_id() :: Eval.run_id()
  def generate_run_id do
    date = Date.utc_today() |> Date.to_iso8601()
    random = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{date}-#{random}"
  end

  @doc """
  Gets the current git commit SHA.

  Returns "unknown" if not in a git repository or git command fails.
  """
  @spec get_commit_sha() :: String.t()
  def get_commit_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _error -> "unknown"
    end
  end

  @doc """
  Stores an eval result to disk as JSONL.

  Each result is written as a single JSON line to test/eval/results/<run_id>.jsonl.
  Automatically triggers cleanup to keep only the last 30 runs.
  """
  @spec store(result()) :: :ok | {:error, term()}
  def store(result) do
    # Ensure results directory exists
    File.mkdir_p!(@results_dir)

    # Write result as JSONL
    file_path = Path.join(@results_dir, "#{result.run_id}.jsonl")
    json_line = Jason.encode!(result) <> "\n"

    case File.write(file_path, json_line, [:append]) do
      :ok ->
        # Trigger cleanup after successful write
        cleanup_old_runs()
        :ok

      {:error, reason} = error ->
        IO.warn("Failed to write eval result to #{file_path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads all eval results for a specific run ID.

  Returns a list of result maps (one per category) or {:error, :not_found} if the run doesn't exist.

  If individual JSONL lines are corrupt, they are skipped with a warning logged.
  Valid results from the same run are preserved.
  """
  @spec load(Eval.run_id()) :: {:ok, [result()]} | {:error, :not_found | term()}
  def load(run_id) do
    file_path = Path.join(@results_dir, "#{run_id}.jsonl")

    case File.read(file_path) do
      {:ok, content} ->
        parse_jsonl_content(content, file_path, run_id)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_jsonl_content(content, file_path, run_id) do
    lines = String.split(content, "\n", trim: true)

    {valid_results, corrupt_count} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {line, line_num}, acc ->
        decode_jsonl_line(line, line_num, file_path, acc)
      end)

    log_corrupt_lines_if_any(valid_results, run_id, corrupt_count)
    {:ok, Enum.reverse(valid_results)}
  end

  defp decode_jsonl_line(line, line_num, file_path, {results, corrupt}) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, result} ->
        {[result | results], corrupt}

      {:error, reason} ->
        IO.warn("Skipping corrupt JSONL line #{line_num} in #{file_path}: #{inspect(reason)}")

        {results, corrupt + 1}
    end
  end

  defp log_corrupt_lines_if_any(valid_results, run_id, corrupt_count) when corrupt_count > 0 do
    IO.warn(
      "Loaded #{length(valid_results)} valid results from #{run_id}, skipped #{corrupt_count} corrupt line(s)"
    )
  end

  defp log_corrupt_lines_if_any(_valid_results, _run_id, _corrupt_count), do: :ok

  @doc """
  Lists all available eval runs, sorted by run ID (newest first).

  Returns a list of run IDs.
  """
  @spec list_runs() :: [Eval.run_id()]
  def list_runs do
    case File.ls(@results_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.basename(&1, ".jsonl"))
        |> Enum.filter(&run_id_format?/1)
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  # Filters for valid run ID format (YYYY-MM-DD-*), excluding archive files
  defp run_id_format?(run_id) do
    String.match?(run_id, ~r/^\d{4}-\d{2}-\d{2}-/)
  end

  @doc """
  Cleans up old eval runs, keeping only the last 30.

  Runs are sorted by run ID (which includes date) and the oldest are removed.
  """
  @spec cleanup_old_runs() :: :ok
  def cleanup_old_runs do
    runs = list_runs()

    # Keep only the most recent runs
    runs_to_delete = Enum.drop(runs, @max_runs_to_keep)

    Enum.each(runs_to_delete, fn run_id ->
      file_path = Path.join(@results_dir, "#{run_id}.jsonl")
      File.rm(file_path)
    end)

    :ok
  end

  @doc """
  Exports all eval results to a single archive file.

  Used for long-term history tracking outside of the working directory.
  Format: JSONL with one result per line.

  If individual runs fail to load, a warning is logged and the run is skipped.
  """
  @spec export(Path.t()) :: :ok | {:error, File.posix()}
  def export(output_path) do
    runs = list_runs()
    {results, failed_runs} = load_all_runs(runs)

    log_failed_runs_if_any(failed_runs)
    write_export_file(output_path, results)
  end

  defp load_all_runs(runs) do
    Enum.reduce(runs, {[], []}, fn run_id, {results_acc, failed_acc} ->
      case load(run_id) do
        {:ok, run_results} ->
          {results_acc ++ run_results, failed_acc}

        {:error, reason} ->
          IO.warn("Skipping run #{run_id} during export: failed to load (#{inspect(reason)})")
          {results_acc, [run_id | failed_acc]}
      end
    end)
  end

  defp log_failed_runs_if_any(failed_runs) when length(failed_runs) > 0 do
    IO.warn("Export skipped #{length(failed_runs)} run(s) that failed to load")
  end

  defp log_failed_runs_if_any(_failed_runs), do: :ok

  defp write_export_file(output_path, results) do
    jsonl_content =
      results
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    case File.write(output_path, jsonl_content <> "\n") do
      :ok ->
        IO.puts("Exported #{length(results)} eval results to #{output_path}")
        :ok

      {:error, reason} = error ->
        IO.warn("Failed to export eval results to #{output_path}: #{inspect(reason)}")
        error
    end
  end
end
