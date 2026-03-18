defmodule Deft.Tools.Observations do
  @moduledoc """
  Tool for viewing observational memory.

  Per spec section 11, supports three modes:
  - Default: shows Current State + User Preferences + today's entries
  - Full: shows all observations
  - Search: filters observations by search term
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context
  alias Deft.OM.State

  @impl Deft.Tool
  def name, do: "observations"

  @impl Deft.Tool
  def description do
    "View observational memory. Supports three modes: default (summary), full (complete dump), " <>
      "or search (filter by term). Use mode: \"summary\" (default), \"full\", or \"search\" with search_term parameter."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{
          "type" => "string",
          "enum" => ["summary", "full", "search"],
          "description" =>
            "Display mode: \"summary\" shows Current State + User Preferences + today's entries, " <>
              "\"full\" shows all observations, \"search\" filters by search_term"
        },
        "search_term" => %{
          "type" => "string",
          "description" =>
            "Search term to filter observations (only used when mode is \"search\")"
        }
      },
      "required" => []
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{session_id: session_id}) do
    mode = args["mode"] || "summary"
    search_term = args["search_term"]

    with :ok <- validate_mode(mode, search_term),
         {:ok, observations} <- get_observations(session_id) do
      format_observations(observations, mode, search_term)
    end
  end

  defp validate_mode("summary", _search_term), do: :ok
  defp validate_mode("full", _search_term), do: :ok
  defp validate_mode("search", search_term) when is_binary(search_term), do: :ok
  defp validate_mode("search", _), do: {:error, "search mode requires search_term parameter"}

  defp validate_mode(mode, _),
    do: {:error, "Invalid mode: #{mode}. Must be summary, full, or search"}

  defp get_observations(session_id) do
    {observations_text, _observed_ids, _hint, _calibration, _pending, _obs_tokens} =
      State.get_context(session_id)

    if observations_text == "" do
      {:ok, [%Text{text: "No observations yet."}]}
    else
      {:ok, observations_text}
    end
  end

  defp format_observations([%Text{} | _] = empty_response, _mode, _search_term),
    do: {:ok, empty_response}

  defp format_observations(observations, "summary", _search_term),
    do: {:ok, [%Text{text: format_summary(observations)}]}

  defp format_observations(observations, "full", _search_term),
    do: {:ok, [%Text{text: observations}]}

  defp format_observations(observations, "search", search_term),
    do: {:ok, [%Text{text: search_observations(observations, search_term)}]}

  # Extract Current State, User Preferences, and today's entries
  defp format_summary(observations) do
    sections = parse_sections(observations)

    # Always include Current State and User Preferences if they exist
    current_state = Map.get(sections, "Current State", "")
    user_prefs = Map.get(sections, "User Preferences", "")

    # Extract today's entries from all sections
    today_entries = extract_today_entries(observations)

    result =
      [
        if(current_state != "", do: "## Current State\n#{current_state}", else: nil),
        if(user_prefs != "", do: "\n## User Preferences\n#{user_prefs}", else: nil),
        if(today_entries != "", do: "\n## Today's Entries\n#{today_entries}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if result == "" do
      "No observations match the summary criteria."
    else
      result
    end
  end

  # Parse observations into sections
  defp parse_sections(text) do
    text
    |> String.split(~r/^## /m)
    |> Enum.drop(1)
    |> Enum.map(fn section ->
      [title | content] = String.split(section, "\n", parts: 2)
      {String.trim(title), Enum.join(content, "\n") |> String.trim()}
    end)
    |> Map.new()
  end

  # Extract entries with today's date
  defp extract_today_entries(text) do
    # Match lines with timestamps like (14:32) or (HH:MM)
    # and extract those that appear to be from today
    text
    |> String.split("\n")
    |> Enum.filter(fn line ->
      # Check if line has a timestamp and content
      String.match?(line, ~r/^\s*-\s*\(\d{1,2}:\d{2}\)/)
    end)
    |> Enum.join("\n")
  end

  # Search observations for a term
  defp search_observations(observations, search_term) do
    lines =
      observations
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(String.downcase(line), String.downcase(search_term))
      end)

    if lines == [] do
      "No observations match search term: #{search_term}"
    else
      Enum.join(lines, "\n")
    end
  end
end
