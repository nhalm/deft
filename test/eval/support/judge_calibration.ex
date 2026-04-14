defmodule Deft.EvalSupport.JudgeCalibration do
  @moduledoc """
  LLM-as-judge calibration support for eval tests.

  Provides functions to calibrate judge prompts against human-graded gold labels
  before deploying them as automated gates.

  See specs/testing/evals/README.md section 1.6 for calibration requirements.
  """

  @doc """
  Calculate precision of judge predictions against gold labels.

  Precision = true positives / (true positives + false positives)

  ## Examples

      iex> calculate_precision([true, true, false], [true, false, false])
      0.5

      iex> calculate_precision([true, true], [true, true])
      1.0
  """
  def calculate_precision(predictions, gold_labels)
      when length(predictions) == length(gold_labels) do
    pairs = Enum.zip(predictions, gold_labels)

    true_positives = Enum.count(pairs, fn {pred, gold} -> pred == true and gold == true end)
    false_positives = Enum.count(pairs, fn {pred, gold} -> pred == true and gold == false end)

    if true_positives + false_positives == 0 do
      0.0
    else
      true_positives / (true_positives + false_positives)
    end
  end

  @doc """
  Calculate recall of judge predictions against gold labels.

  Recall = true positives / (true positives + false negatives)

  ## Examples

      iex> calculate_recall([true, true, false], [true, false, false])
      1.0

      iex> calculate_recall([false, false], [true, true])
      0.0
  """
  def calculate_recall(predictions, gold_labels)
      when length(predictions) == length(gold_labels) do
    pairs = Enum.zip(predictions, gold_labels)

    true_positives = Enum.count(pairs, fn {pred, gold} -> pred == true and gold == true end)
    false_negatives = Enum.count(pairs, fn {pred, gold} -> pred == false and gold == true end)

    if true_positives + false_negatives == 0 do
      0.0
    else
      true_positives / (true_positives + false_negatives)
    end
  end

  @doc """
  Check if judge meets deployment threshold.

  Requires precision > 85% and recall > 80% per spec section 1.6.

  ## Examples

      iex> meets_threshold?(0.90, 0.85)
      true

      iex> meets_threshold?(0.80, 0.85)
      false
  """
  def meets_threshold?(precision, recall) do
    precision > 0.85 and recall > 0.80
  end

  @doc """
  Run calibration against a gold standard dataset.

  Takes a judge function and a list of calibration examples with gold labels.
  Returns calibration metrics.

  ## Parameters

  - `judge_fn` - Function that takes an example and returns true/false prediction
  - `calibration_set` - List of {example, gold_label} tuples

  ## Returns

  Map with:
  - `:precision` - Precision score
  - `:recall` - Recall score
  - `:passes_threshold` - Boolean whether judge meets deployment requirements
  - `:predictions` - List of {example, prediction, gold_label} for analysis
  """
  def run_calibration(judge_fn, calibration_set) do
    results =
      Enum.map(calibration_set, fn {example, gold_label} ->
        prediction = judge_fn.(example)
        {example, prediction, gold_label}
      end)

    predictions = Enum.map(results, fn {_example, pred, _gold} -> pred end)
    gold_labels = Enum.map(results, fn {_example, _pred, gold} -> gold end)

    precision = calculate_precision(predictions, gold_labels)
    recall = calculate_recall(predictions, gold_labels)

    %{
      precision: precision,
      recall: recall,
      passes_threshold: meets_threshold?(precision, recall),
      predictions: results
    }
  end
end
