defmodule Deft.Eval.JudgeCalibration do
  @moduledoc """
  LLM-as-judge calibration set management.

  Validates judge prompts against human-graded gold labels before
  deploying them as automated gates (spec section 1.6).

  Calibration workflow:
  1. Collect 50 examples with human-graded gold labels
  2. Run judge prompt against all 50
  3. Measure precision and recall against gold standard
  4. Only deploy if precision > 85% and recall > 80%
  5. Re-run calibration when changing judge model or prompt
  """

  @calibration_dir "test/eval/support/judge_calibration"
  @required_examples 50
  @precision_threshold 0.85
  @recall_threshold 0.80

  @type example :: %{
          id: String.t(),
          input: String.t(),
          gold_label: boolean(),
          metadata: map()
        }

  @type calibration_result :: %{
          judge_name: String.t(),
          judge_version: String.t(),
          model: String.t(),
          precision: float(),
          recall: float(),
          accuracy: float(),
          total_examples: integer(),
          passed: boolean(),
          timestamp: String.t(),
          failures: list(map())
        }

  @doc """
  Loads a calibration set from disk.

  Calibration sets are stored as JSON files in #{@calibration_dir}/<judge_name>.json
  """
  def load_calibration_set(judge_name) do
    path = calibration_set_path(judge_name)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, data} -> {:ok, data}
          {:error, _} = error -> error
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Saves a calibration set to disk.

  Examples should be a list of maps with:
  - `:id` - unique example identifier
  - `:input` - the text/content to judge
  - `:gold_label` - true/false human-graded label
  - `:metadata` - optional context (e.g., why this example is interesting)
  """
  def save_calibration_set(judge_name, examples, metadata \\ %{}) do
    unless length(examples) >= @required_examples do
      raise ArgumentError,
            "Calibration set must have at least #{@required_examples} examples, got #{length(examples)}"
    end

    File.mkdir_p!(@calibration_dir)

    data = %{
      judge_name: judge_name,
      examples: examples,
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      example_count: length(examples)
    }

    path = calibration_set_path(judge_name)
    content = Jason.encode!(data, pretty: true)
    File.write!(path, content)

    {:ok, path}
  end

  @doc """
  Runs calibration for a judge against its calibration set.

  The judge_fn receives an example's input and returns a boolean judgment.
  Returns a calibration result with precision, recall, and pass/fail status.

  Options:
  - `:model` - LLM model used (for tracking)
  - `:judge_version` - version identifier for the judge prompt
  """
  def run_calibration(judge_name, judge_fn, opts \\ []) do
    with {:ok, calibration_data} <- load_calibration_set(judge_name) do
      examples = calibration_data.examples

      results =
        Enum.map(examples, fn example ->
          predicted = judge_fn.(example.input)

          %{
            id: example.id,
            gold: example.gold_label,
            predicted: predicted,
            correct: example.gold_label == predicted
          }
        end)

      metrics = compute_metrics(results)

      passed =
        metrics.precision >= @precision_threshold and
          metrics.recall >= @recall_threshold

      failures =
        results
        |> Enum.reject(& &1.correct)
        |> Enum.map(fn r -> %{id: r.id, gold: r.gold, predicted: r.predicted} end)

      result = %{
        judge_name: judge_name,
        judge_version: Keyword.get(opts, :judge_version, "unknown"),
        model: Keyword.get(opts, :model, "unknown"),
        precision: metrics.precision,
        recall: metrics.recall,
        accuracy: metrics.accuracy,
        total_examples: length(examples),
        passed: passed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        failures: failures
      }

      {:ok, result}
    end
  end

  @doc """
  Computes precision, recall, and accuracy from judgment results.

  Precision = TP / (TP + FP) - of all positive predictions, how many were correct?
  Recall = TP / (TP + FN) - of all actual positives, how many did we find?
  Accuracy = (TP + TN) / total
  """
  def compute_metrics(results) do
    tp = Enum.count(results, fn r -> r.gold == true and r.predicted == true end)
    fp = Enum.count(results, fn r -> r.gold == false and r.predicted == true end)
    tn = Enum.count(results, fn r -> r.gold == false and r.predicted == false end)
    fn_count = Enum.count(results, fn r -> r.gold == true and r.predicted == false end)

    total = length(results)

    precision = if tp + fp > 0, do: tp / (tp + fp), else: 0.0
    recall = if tp + fn_count > 0, do: tp / (tp + fn_count), else: 0.0
    accuracy = if total > 0, do: (tp + tn) / total, else: 0.0

    %{
      precision: Float.round(precision, 3),
      recall: Float.round(recall, 3),
      accuracy: Float.round(accuracy, 3),
      true_positives: tp,
      false_positives: fp,
      true_negatives: tn,
      false_negatives: fn_count
    }
  end

  @doc """
  Stores calibration results to a history file.

  Appends the result as a JSONL entry to allow tracking calibration over time.
  """
  def store_calibration_result(result) do
    File.mkdir_p!(@calibration_dir)
    history_path = Path.join(@calibration_dir, "calibration_history.jsonl")

    json_line = Jason.encode!(result) <> "\n"
    File.write!(history_path, json_line, [:append])

    {:ok, history_path}
  end

  @doc """
  Checks if a judge has been calibrated and passed thresholds.

  Returns {:ok, latest_result} if calibration exists and passed,
  or {:error, reason} otherwise.
  """
  def check_calibration_status(judge_name) do
    history_path = Path.join(@calibration_dir, "calibration_history.jsonl")

    case File.read(history_path) do
      {:ok, content} ->
        results =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!(&1, keys: :atoms))
          |> Enum.filter(&(&1.judge_name == judge_name))

        case List.last(results) do
          nil ->
            {:error, :no_calibration}

          latest ->
            if latest.passed do
              {:ok, latest}
            else
              {:error, {:failed_thresholds, latest}}
            end
        end

      {:error, :enoent} ->
        {:error, :no_calibration}

      {:error, _} = error ->
        error
    end
  end

  defp calibration_set_path(judge_name) do
    Path.join(@calibration_dir, "#{judge_name}.json")
  end
end
