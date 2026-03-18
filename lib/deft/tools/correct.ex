defmodule Deft.Tools.Correct do
  @moduledoc """
  Tool for correcting observations by replacing incorrect text with correct text.

  Per spec section 11, supports two modes:
  - Search: finds observations matching the search term
  - Confirm: appends a CORRECTION marker with replacement text

  The workflow is:
  1. Agent calls with mode="search", old="...", new="..." to find matches
  2. Agent shows matches to user and asks for confirmation
  3. Agent calls with mode="confirm", old="...", new="..." to append the CORRECTION marker
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context
  alias Deft.OM.State

  @impl Deft.Tool
  def name, do: "correct"

  @impl Deft.Tool
  def description do
    "Correct observations by replacing incorrect text with correct text. " <>
      "Use mode=\"search\" with old and new to find matching observations. " <>
      "Use mode=\"confirm\" with old and new to append a CORRECTION marker after user confirmation."
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
        "old" => %{
          "type" => "string",
          "description" => "The incorrect text to search for and replace"
        },
        "new" => %{
          "type" => "string",
          "description" => "The correct text to use as replacement"
        }
      },
      "required" => ["mode", "old", "new"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{session_id: session_id}) do
    mode = args["mode"]
    old_text = args["old"]
    new_text = args["new"]

    case mode do
      "search" ->
        search_observations(session_id, old_text, new_text)

      "confirm" ->
        append_correction(session_id, old_text, new_text)

      _ ->
        {:error, "Invalid mode: #{mode}. Must be \"search\" or \"confirm\""}
    end
  end

  defp search_observations(session_id, old_text, _new_text) do
    {observations_text, _observed_ids, _hint, _calibration, _pending, _obs_tokens} =
      State.get_context(session_id)

    if observations_text == "" do
      {:ok, [%Text{text: "No observations to search."}]}
    else
      matches = find_matches(observations_text, old_text)

      if matches == [] do
        {:ok, [%Text{text: "No observations match \"#{old_text}\"."}]}
      else
        result = format_matches(matches, old_text)
        {:ok, [%Text{text: result}]}
      end
    end
  end

  defp append_correction(session_id, old_text, new_text) do
    correction_message = "Replace \"#{old_text}\" with \"#{new_text}\""
    State.append_correction(session_id, correction_message)
    {:ok, [%Text{text: "CORRECTION marker added: Replace \"#{old_text}\" with \"#{new_text}\""}]}
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
