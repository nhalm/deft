defmodule Deft.Eval.JudgeCalibration do
  @moduledoc """
  Judge calibration workflow for LLM-as-judge assertions.

  Before deploying any LLM-as-judge assertion as an automated gate:
  1. Collect 50 examples with human-graded gold labels
  2. Run the judge prompt against all 50
  3. Measure precision and recall against the gold standard
  4. Only deploy if precision > 85% and recall > 80%
  5. Store the calibration set in test/eval/support/judge_calibration/
  6. Re-run calibration when changing judge model or prompt
  """

  @type gold_label :: boolean()
  @type judge_result :: boolean()

  @type calibration_example :: %{
          id: String.t(),
          input: any(),
          gold_label: gold_label(),
          description: String.t()
        }

  @type calibration_result :: %{
          precision: float(),
          recall: float(),
          accuracy: float(),
          true_positives: non_neg_integer(),
          false_positives: non_neg_integer(),
          true_negatives: non_neg_integer(),
          false_negatives: non_neg_integer(),
          total: non_neg_integer(),
          examples_count: non_neg_integer(),
          model: String.t(),
          timestamp: String.t(),
          judge_name: String.t()
        }

  @calibration_dir "test/eval/support/judge_calibration"

  @doc """
  Load calibration examples from a JSONL file.

  Each line should be a JSON object with:
  - id: unique identifier
  - input: the input to be judged (format depends on judge type)
  - gold_label: true/false human-graded label
  - description: human-readable description of what this example tests

  Returns a list of calibration examples or an error tuple.
  """
  @spec load_examples(String.t()) :: {:ok, [calibration_example()]} | {:error, term()}
  def load_examples(filename) do
    path = Path.join(@calibration_dir, filename)

    with {:ok, content} <- File.read(path) do
      examples =
        content
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce_while([], fn {line, line_num}, acc ->
          case Jason.decode(line) do
            {:ok, example} ->
              {:cont, [parse_example(example) | acc]}

            {:error, reason} ->
              {:halt, {:error, "Line #{line_num}: #{inspect(reason)}"}}
          end
        end)

      case examples do
        {:error, _} = error -> error
        examples -> {:ok, Enum.reverse(examples)}
      end
    end
  end

  @doc """
  Run calibration for a judge prompt.

  Takes:
  - examples: list of calibration examples with gold labels
  - judge_fn: function that takes an input and returns true/false
  - judge_name: identifier for this judge (e.g., "observer_extraction")
  - model: the model being used (e.g., "claude-sonnet-4-6")

  Returns calibration metrics including precision, recall, and accuracy.
  """
  @spec calibrate([calibration_example()], (any() -> judge_result()), String.t(), String.t()) ::
          {:ok, calibration_result()} | {:error, term()}
  def calibrate(examples, judge_fn, judge_name, model) do
    if length(examples) < 50 do
      {:error, "Calibration requires at least 50 examples, got #{length(examples)}"}
    else
      results =
        Enum.map(examples, fn example ->
          judge_result = judge_fn.(example.input)
          {example, judge_result}
        end)

      metrics = calculate_metrics(results)

      result = %{
        precision: metrics.precision,
        recall: metrics.recall,
        accuracy: metrics.accuracy,
        true_positives: metrics.true_positives,
        false_positives: metrics.false_positives,
        true_negatives: metrics.true_negatives,
        false_negatives: metrics.false_negatives,
        total: metrics.total,
        examples_count: length(examples),
        model: model,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        judge_name: judge_name
      }

      {:ok, result}
    end
  end

  @doc """
  Check if calibration results meet the required thresholds.

  Returns :ok if precision > 85% and recall > 80%, otherwise returns
  {:error, reason} with details about which thresholds were not met.
  """
  @spec validate_thresholds(calibration_result()) :: :ok | {:error, String.t()}
  def validate_thresholds(result) do
    precision_ok? = result.precision > 0.85
    recall_ok? = result.recall > 0.80

    cond do
      not precision_ok? and not recall_ok? ->
        {:error,
         "Both precision (#{format_percent(result.precision)}) and recall (#{format_percent(result.recall)}) below thresholds"}

      not precision_ok? ->
        {:error, "Precision (#{format_percent(result.precision)}) below 85% threshold"}

      not recall_ok? ->
        {:error, "Recall (#{format_percent(result.recall)}) below 80% threshold"}

      true ->
        :ok
    end
  end

  @doc """
  Save calibration results to disk.

  Stores the result as a JSON file in the calibration directory with
  filename: <judge_name>_<timestamp>.json
  """
  @spec save_result(calibration_result()) :: :ok | {:error, term()}
  def save_result(result) do
    timestamp = result.timestamp |> String.replace(~r/[:\-]/, "") |> String.replace("T", "_")
    filename = "#{result.judge_name}_#{timestamp}.json"
    path = Path.join(@calibration_dir, filename)

    case Jason.encode(result, pretty: true) do
      {:ok, json} -> File.write(path, json)
      error -> error
    end
  end

  @doc """
  Load the most recent calibration result for a judge.

  Returns the most recent calibration result based on timestamp,
  or {:error, :not_found} if no calibration exists.
  """
  @spec load_latest_result(String.t()) :: {:ok, calibration_result()} | {:error, term()}
  def load_latest_result(judge_name) do
    with {:ok, files} <- File.ls(@calibration_dir) do
      matching_files =
        files
        |> Enum.filter(&String.starts_with?(&1, "#{judge_name}_"))
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort(:desc)

      case matching_files do
        [] ->
          {:error, :not_found}

        [latest | _] ->
          path = Path.join(@calibration_dir, latest)

          with {:ok, content} <- File.read(path),
               {:ok, result} <- Jason.decode(content, keys: :atoms) do
            {:ok, result}
          end
      end
    end
  end

  @doc """
  Format a calibration result for display.

  Returns a multi-line string with formatted metrics.
  """
  @spec format_result(calibration_result()) :: String.t()
  def format_result(result) do
    status =
      case validate_thresholds(result) do
        :ok -> "✓ PASS"
        {:error, reason} -> "✗ FAIL: #{reason}"
      end

    """
    Judge Calibration: #{result.judge_name}
    Model: #{result.model}
    Timestamp: #{result.timestamp}
    Examples: #{result.examples_count}

    Metrics:
      Precision: #{format_percent(result.precision)} (threshold: 85%)
      Recall:    #{format_percent(result.recall)} (threshold: 80%)
      Accuracy:  #{format_percent(result.accuracy)}

    Confusion Matrix:
      True Positives:  #{result.true_positives}
      False Positives: #{result.false_positives}
      True Negatives:  #{result.true_negatives}
      False Negatives: #{result.false_negatives}

    Status: #{status}
    """
  end

  # Private functions

  defp parse_example(map) do
    %{
      id: Map.fetch!(map, "id"),
      input: Map.fetch!(map, "input"),
      gold_label: Map.fetch!(map, "gold_label"),
      description: Map.get(map, "description", "")
    }
  end

  defp calculate_metrics(results) do
    {tp, fp, tn, false_neg} =
      Enum.reduce(results, {0, 0, 0, 0}, fn {example, judge_result}, {tp, fp, tn, false_neg} ->
        case {example.gold_label, judge_result} do
          {true, true} -> {tp + 1, fp, tn, false_neg}
          {false, true} -> {tp, fp + 1, tn, false_neg}
          {false, false} -> {tp, fp, tn + 1, false_neg}
          {true, false} -> {tp, fp, tn, false_neg + 1}
        end
      end)

    total = tp + fp + tn + false_neg

    precision = if tp + fp > 0, do: tp / (tp + fp), else: 0.0
    recall = if tp + false_neg > 0, do: tp / (tp + false_neg), else: 0.0
    accuracy = if total > 0, do: (tp + tn) / total, else: 0.0

    %{
      precision: precision,
      recall: recall,
      accuracy: accuracy,
      true_positives: tp,
      false_positives: fp,
      true_negatives: tn,
      false_negatives: false_neg,
      total: total
    }
  end

  defp format_percent(value) do
    "#{Float.round(value * 100, 1)}%"
  end
end
