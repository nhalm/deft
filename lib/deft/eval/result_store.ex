defmodule Deft.Eval.ResultStore do
  @moduledoc """
  Storage and retrieval for eval run results.

  Per spec section 2.1: stores per-run results as JSONL at test/eval/results/<run_id>.jsonl
  with commit SHA, model, category, pass_rate, iterations, cost, and failure examples.

  Automatically manages cleanup to keep only the last 30 runs on disk.
  """

  @results_dir "test/eval/results"
  @max_runs_to_keep 30

  @type failure :: %{
          fixture: String.t(),
          output: String.t(),
          reason: String.t()
        }

  @type result :: %{
          run_id: String.t(),
          commit: String.t(),
          timestamp: String.t(),
          model: String.t(),
          category: String.t(),
          pass_rate: float(),
          iterations: non_neg_integer(),
          cost_usd: float(),
          failures: [failure()]
        }

  @doc """
  Generates a unique run ID for the current eval run.

  Format: YYYY-MM-DD-<6-hex-chars>
  """
  @spec generate_run_id() :: String.t()
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

    case File.write(file_path, json_line) do
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
  Loads a specific eval result by run ID.

  Returns the result map or {:error, :not_found} if the run doesn't exist.
  """
  @spec load(String.t()) :: {:ok, result()} | {:error, :not_found | term()}
  def load(run_id) do
    file_path = Path.join(@results_dir, "#{run_id}.jsonl")

    case File.read(file_path) do
      {:ok, content} ->
        # Parse the first line (should only be one line)
        content
        |> String.trim()
        |> Jason.decode()

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all available eval runs, sorted by run ID (newest first).

  Returns a list of run IDs.
  """
  @spec list_runs() :: [String.t()]
  def list_runs do
    case File.ls(@results_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.basename(&1, ".jsonl"))
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
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
  """
  @spec export(Path.t()) :: :ok | {:error, term()}
  def export(output_path) do
    runs = list_runs()

    # Load all results
    results =
      runs
      |> Enum.map(&load/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    # Write all results as JSONL
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
