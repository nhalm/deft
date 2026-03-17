defmodule Mix.Tasks.Eval.Export do
  @moduledoc """
  Exports all eval results to an archive file.

  Usage:
      mix eval.export [output_path]

  If no output path is provided, defaults to:
      test/eval/results/archive-<timestamp>.jsonl

  The archive file contains all eval results in JSONL format,
  with one result per line.

  This is useful for long-term tracking of eval results outside
  of the working directory, since the results directory only
  keeps the last 30 runs.
  """

  use Mix.Task

  alias Deft.Eval.ResultStore

  @shortdoc "Export all eval results to an archive file"

  @impl Mix.Task
  def run(args) do
    # Ensure modules are compiled
    Mix.Task.run("compile")

    output_path =
      case args do
        [path] ->
          path

        [] ->
          timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
          "test/eval/results/archive-#{timestamp}.jsonl"
      end

    case ResultStore.export(output_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Export failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
