defmodule Deft.Test.Eval.JudgeCalibration do
  @moduledoc """
  Test helpers for judge calibration workflows.

  Provides utilities for:
  - Creating calibration example fixtures
  - Mock judge functions for testing
  - Assertion helpers for calibration results
  - Fixture file generation for calibration sets
  """

  alias Deft.Eval.JudgeCalibration

  @doc """
  Creates a calibration example map for testing.

  ## Examples

      iex> example = calibration_example("ex1", "some input", true, "tests positive case")
      iex> example.id
      "ex1"
      iex> example.gold_label
      true
  """
  def calibration_example(id, input, gold_label, description \\ "") do
    %{
      id: id,
      input: input,
      gold_label: gold_label,
      description: description
    }
  end

  @doc """
  Creates a batch of calibration examples for testing.

  ## Options
  - `:count` - Total number of examples to create (default: 50)
  - `:positive_ratio` - Ratio of positive examples (default: 0.5)
  - `:input_generator` - Function to generate input (default: returns "input_\#{n}")

  ## Examples

      iex> examples = generate_examples(count: 10, positive_ratio: 0.6)
      iex> length(examples)
      10
      iex> Enum.count(examples, & &1.gold_label)
      6
  """
  def generate_examples(opts \\ []) do
    count = Keyword.get(opts, :count, 50)
    positive_ratio = Keyword.get(opts, :positive_ratio, 0.5)
    input_generator = Keyword.get(opts, :input_generator, &default_input_generator/1)

    positive_count = round(count * positive_ratio)

    examples =
      for n <- 1..count do
        calibration_example(
          "example_#{n}",
          input_generator.(n),
          n <= positive_count,
          "Generated example #{n}"
        )
      end

    Enum.shuffle(examples)
  end

  @doc """
  Creates a mock judge function that always returns the same result.

  ## Examples

      iex> judge = constant_judge(true)
      iex> judge.("any input")
      true
  """
  def constant_judge(result) do
    fn _input -> result end
  end

  @doc """
  Creates a mock judge function that returns true for positive examples.

  Useful for testing perfect precision/recall scenarios.

  ## Examples

      iex> judge = perfect_judge()
      iex> examples = generate_examples(count: 10)
      iex> results = Enum.map(examples, fn ex -> judge.(ex) end)
      iex> Enum.all?(results, &is_boolean/1)
      true
  """
  def perfect_judge do
    fn
      example when is_map(example) -> example.gold_label
      _other -> false
    end
  end

  @doc """
  Creates a mock judge function with specified error rate.

  ## Options
  - `:error_rate` - Probability of incorrect classification (0.0 to 1.0)
  - `:seed` - Random seed for deterministic testing (default: 42)

  ## Examples

      iex> judge = noisy_judge(error_rate: 0.1, seed: 42)
      iex> example = calibration_example("ex1", "test", true)
      iex> is_boolean(judge.(example))
      true
  """
  def noisy_judge(opts \\ []) do
    error_rate = Keyword.get(opts, :error_rate, 0.1)
    seed = Keyword.get(opts, :seed, 42)
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    fn example when is_map(example) ->
      if :rand.uniform() < error_rate do
        not example.gold_label
      else
        example.gold_label
      end
    end
  end

  @doc """
  Creates a temporary JSONL file with calibration examples.

  Returns `{:ok, path}` where path is the temporary file location.
  The caller is responsible for cleaning up the file.

  ## Examples

      iex> examples = generate_examples(count: 5)
      iex> {:ok, path} = write_temp_calibration_file(examples)
      iex> File.exists?(path)
      true
      iex> File.rm!(path)
  """
  def write_temp_calibration_file(examples) do
    content =
      examples
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    path = Path.join(System.tmp_dir!(), "calibration_#{:rand.uniform(999_999)}.jsonl")

    case File.write(path, content) do
      :ok -> {:ok, path}
      error -> error
    end
  end

  @doc """
  Assert that calibration result meets minimum thresholds.

  ## Examples

      iex> result = %{precision: 0.90, recall: 0.85}
      iex> assert_calibration_passes(result)
      :ok
  """
  def assert_calibration_passes(result) do
    case JudgeCalibration.validate_thresholds(result) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "Calibration failed: #{reason}",
          left: result,
          right: %{precision: ">0.85", recall: ">0.80"}
    end
  end

  @doc """
  Assert that calibration result has expected precision.

  ## Examples

      iex> result = %{precision: 0.90}
      iex> assert_precision(result, 0.90, delta: 0.01)
      :ok
  """
  def assert_precision(result, expected, opts \\ []) do
    delta = Keyword.get(opts, :delta, 0.01)
    actual = result.precision

    if abs(actual - expected) > delta do
      raise ExUnit.AssertionError,
        message: "Expected precision to be ~#{expected} (±#{delta}), got #{actual}",
        left: actual,
        right: expected
    end

    :ok
  end

  @doc """
  Assert that calibration result has expected recall.

  ## Examples

      iex> result = %{recall: 0.85}
      iex> assert_recall(result, 0.85, delta: 0.01)
      :ok
  """
  def assert_recall(result, expected, opts \\ []) do
    delta = Keyword.get(opts, :delta, 0.01)
    actual = result.recall

    if abs(actual - expected) > delta do
      raise ExUnit.AssertionError,
        message: "Expected recall to be ~#{expected} (±#{delta}), got #{actual}",
        left: actual,
        right: expected
    end

    :ok
  end

  @doc """
  Assert that calibration result has expected accuracy.

  ## Examples

      iex> result = %{accuracy: 0.88}
      iex> assert_accuracy(result, 0.88, delta: 0.01)
      :ok
  """
  def assert_accuracy(result, expected, opts \\ []) do
    delta = Keyword.get(opts, :delta, 0.01)
    actual = result.accuracy

    if abs(actual - expected) > delta do
      raise ExUnit.AssertionError,
        message: "Expected accuracy to be ~#{expected} (±#{delta}), got #{actual}",
        left: actual,
        right: expected
    end

    :ok
  end

  @doc """
  Calculate expected metrics for a set of examples and judge results.

  Useful for verifying calibration logic in tests.

  ## Examples

      iex> examples = [
      ...>   %{gold_label: true},
      ...>   %{gold_label: false},
      ...>   %{gold_label: true}
      ...> ]
      iex> judge_results = [true, false, false]
      iex> metrics = expected_metrics(examples, judge_results)
      iex> metrics.true_positives
      1
      iex> metrics.false_negatives
      1
  """
  def expected_metrics(examples, judge_results) do
    results = Enum.zip(examples, judge_results)
    {tp, fp, tn, fn_count} = count_confusion_matrix(results)
    build_metrics_map(tp, fp, tn, fn_count)
  end

  # Private helpers

  defp default_input_generator(n) do
    "input_#{n}"
  end

  defp count_confusion_matrix(results) do
    Enum.reduce(results, {0, 0, 0, 0}, fn {example, judge_result}, acc ->
      increment_classification(example.gold_label, judge_result, acc)
    end)
  end

  defp increment_classification(gold, judge, {tp, fp, tn, fn_count}) do
    case {gold, judge} do
      {true, true} -> {tp + 1, fp, tn, fn_count}
      {false, true} -> {tp, fp + 1, tn, fn_count}
      {false, false} -> {tp, fp, tn + 1, fn_count}
      {true, false} -> {tp, fp, tn, fn_count + 1}
    end
  end

  defp build_metrics_map(tp, fp, tn, fn_count) do
    total = tp + fp + tn + fn_count
    precision = if tp + fp > 0, do: tp / (tp + fp), else: 0.0
    recall = if tp + fn_count > 0, do: tp / (tp + fn_count), else: 0.0
    accuracy = if total > 0, do: (tp + tn) / total, else: 0.0

    %{
      precision: precision,
      recall: recall,
      accuracy: accuracy,
      true_positives: tp,
      false_positives: fp,
      true_negatives: tn,
      false_negatives: fn_count,
      total: total
    }
  end
end
