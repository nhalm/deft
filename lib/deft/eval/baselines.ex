defmodule Deft.Eval.Baselines do
  @moduledoc """
  Manages eval baseline tracking with history.

  Per spec section 2.2: stores baseline, soft_floor (baseline minus 10pp), and history
  array per category. Baselines only go up — regressions are tracked but don't lower the baseline.
  """

  @baselines_file "test/eval/baselines.json"
  @soft_floor_offset 0.10

  @type history_entry :: %{
          run_id: String.t(),
          rate: float(),
          n: non_neg_integer(),
          commit: String.t()
        }

  @type baseline :: %{
          baseline: float(),
          soft_floor: float(),
          history: [history_entry()]
        }

  @type baselines :: %{String.t() => baseline()}

  @doc """
  Loads baselines from test/eval/baselines.json.

  Returns an empty map if the file doesn't exist.
  """
  @spec load() :: {:ok, baselines()} | {:error, term()}
  def load do
    case File.read(@baselines_file) do
      {:ok, content} ->
        decode_baselines(content)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Saves baselines to test/eval/baselines.json.

  Creates the directory if it doesn't exist.
  """
  @spec save(baselines()) :: :ok | {:error, term()}
  def save(baselines) do
    # Ensure directory exists
    @baselines_file
    |> Path.dirname()
    |> File.mkdir_p!()

    # Convert to JSON-friendly format
    json_data =
      Enum.into(baselines, %{}, fn {category, baseline_data} ->
        {category,
         %{
           baseline: baseline_data.baseline,
           soft_floor: baseline_data.soft_floor,
           history:
             Enum.map(baseline_data.history, fn entry ->
               %{
                 run_id: entry.run_id,
                 rate: entry.rate,
                 n: entry.n,
                 commit: entry.commit
               }
             end)
         }}
      end)

    case Jason.encode(json_data, pretty: true) do
      {:ok, json} ->
        File.write(@baselines_file, json <> "\n")

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  end

  @doc """
  Updates baseline for a category based on a new result.

  Baseline update logic:
  - Adds the result to history
  - If the new rate is higher than the current baseline, raises the baseline
  - Baselines only go up — never decrease
  - Recalculates soft_floor as baseline - 10pp

  Returns the updated baselines map.

  ## Parameters

  - `baselines` - The current baselines map
  - `category` - The category to update
  - `result` - Map with keys: `:rate`, `:n`, `:run_id`, `:commit`
  """
  @spec update(baselines(), String.t(), map()) :: baselines()
  def update(baselines, category, %{rate: rate, n: n, run_id: run_id, commit: commit} = _result) do
    current = Map.get(baselines, category, default_baseline())

    new_history_entry = %{
      run_id: run_id,
      rate: rate,
      n: n,
      commit: commit
    }

    # Add to history
    new_history = [new_history_entry | current.history]

    # Update baseline only if rate is higher (baselines only go up)
    new_baseline = max(current.baseline, rate)

    # Recalculate soft_floor
    new_soft_floor = new_baseline - @soft_floor_offset

    updated_baseline = %{
      baseline: new_baseline,
      soft_floor: new_soft_floor,
      history: new_history
    }

    Map.put(baselines, category, updated_baseline)
  end

  @doc """
  Gets the baseline for a specific category.

  Returns nil if the category doesn't exist.
  """
  @spec get_baseline(baselines(), String.t()) :: baseline() | nil
  def get_baseline(baselines, category) do
    Map.get(baselines, category)
  end

  @doc """
  Checks if a rate is below the soft floor for a category.

  Returns false if the category doesn't exist (no baseline to compare against).
  """
  @spec below_soft_floor?(baselines(), String.t(), float()) :: boolean()
  def below_soft_floor?(baselines, category, rate) do
    case get_baseline(baselines, category) do
      nil -> false
      baseline -> rate < baseline.soft_floor
    end
  end

  @doc """
  Gets all categories with baselines.
  """
  @spec categories(baselines()) :: [String.t()]
  def categories(baselines) do
    Map.keys(baselines) |> Enum.sort()
  end

  # Private helpers

  defp decode_baselines(content) do
    case Jason.decode(content) do
      {:ok, data} ->
        baselines = parse_baseline_data(data)
        {:ok, baselines}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_baseline_data(data) do
    Enum.into(data, %{}, fn {category, baseline_data} ->
      {category, parse_baseline_entry(baseline_data)}
    end)
  end

  defp parse_baseline_entry(baseline_data) do
    %{
      baseline: baseline_data["baseline"],
      soft_floor: baseline_data["soft_floor"],
      history: parse_history(baseline_data["history"] || [])
    }
  end

  defp parse_history(history_list) do
    Enum.map(history_list, fn entry ->
      %{
        run_id: entry["run_id"],
        rate: entry["rate"],
        n: entry["n"],
        commit: entry["commit"]
      }
    end)
  end

  defp default_baseline do
    %{
      baseline: 0.0,
      soft_floor: -@soft_floor_offset,
      history: []
    }
  end
end
