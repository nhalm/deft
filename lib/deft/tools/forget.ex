defmodule Deft.Tools.Forget do
  @moduledoc """
  Tool for marking observations as incorrect (forgetting).

  Per spec section 11, supports two modes:
  - Search: finds observations matching the search term
  - Confirm: appends a CORRECTION marker for the specified text

  The workflow is:
  1. Agent calls with mode="search" and text="..." to find matches
  2. Agent shows matches to user and asks for confirmation
  3. Agent calls with mode="confirm" and text="..." to append the CORRECTION marker
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context
  alias Deft.OM.State

  @impl Deft.Tool
  def name, do: "forget"

  @impl Deft.Tool
  def description do
    "Mark observations as incorrect. Use mode=\"search\" with text to find matching observations. " <>
      "Use mode=\"confirm\" with text to append a CORRECTION marker after user confirmation."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{
          "type" => "string",
          "enum" => ["search", "confirm"],
          "description" =>
            "Mode: \"search\" finds matching observations, \"confirm\" appends CORRECTION marker"
        },
        "text" => %{
          "type" => "string",
          "description" => "Text to search for or mark as incorrect"
        }
      },
      "required" => ["mode", "text"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{session_id: session_id}) do
    mode = args["mode"]
    text = args["text"]

    case mode do
      "search" ->
        search_observations(session_id, text)

      "confirm" ->
        append_correction(session_id, text)

      _ ->
        {:error, "Invalid mode: #{mode}. Must be \"search\" or \"confirm\""}
    end
  end

  defp search_observations(session_id, search_term) do
    {observations_text, _observed_ids, _hint, _calibration, _pending, _obs_tokens} =
      State.get_context(session_id)

    if observations_text == "" do
      {:ok, [%Text{text: "No observations to search."}]}
    else
      matches = find_matches(observations_text, search_term)

      if matches == [] do
        {:ok, [%Text{text: "No observations match \"#{search_term}\"."}]}
      else
        result = format_matches(matches, search_term)
        {:ok, [%Text{text: result}]}
      end
    end
  end

  defp append_correction(session_id, text) do
    correction_message = "#{text} is incorrect — remove this observation"
    State.append_correction(session_id, correction_message)
    {:ok, [%Text{text: "CORRECTION marker added for: #{text}"}]}
  end

  # Find all lines containing the search term (case-insensitive)
  defp find_matches(observations, search_term) do
    observations
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(String.downcase(line), String.downcase(search_term))
    end)
  end

  defp format_matches(matches, search_term) do
    count = length(matches)
    matches_text = Enum.join(matches, "\n")

    """
    Found #{count} observation(s) matching "#{search_term}":

    #{matches_text}
    """
  end
end
