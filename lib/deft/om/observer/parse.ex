defmodule Deft.OM.Observer.Parse do
  @moduledoc """
  Parses Observer LLM output and implements section-aware merging.

  The Observer returns XML-formatted observations with sectioned content.
  This module extracts the observations and current-task, validates section
  headers, and implements the merge strategy from spec section 3.5.
  """

  @doc """
  Parses Observer LLM output and extracts observations and current task.

  ## Input Format

  Expected XML format:
  ```xml
  <observations>
  ## Current State
  - (14:55) Active task: ...

  ## User Preferences
  ...
  </observations>

  <current-task>
  Brief description
  </current-task>

  <continuation-hint>
  Dynamic hint for conversation continuity
  </continuation-hint>
  ```

  ## Return Value

  Returns `{:ok, %{observations: text, current_task: text, continuation_hint: text}}` on success.
  Returns `{:error, reason}` if parsing fails completely.

  ## Examples

      iex> xml = "<observations>## Current State\\n- Task\\n</observations>\\n<current-task>Working</current-task>"
      iex> {:ok, result} = Deft.OM.Observer.Parse.parse_output(xml)
      iex> result.observations
      "## Current State\\n- Task\\n"
      iex> result.current_task
      "Working"
  """
  @spec parse_output(String.t()) ::
          {:ok,
           %{
             observations: String.t(),
             current_task: String.t() | nil,
             continuation_hint: String.t() | nil
           }}
          | {:error, String.t()}
  def parse_output(output) when is_binary(output) do
    # Try XML parsing first
    case extract_xml_blocks(output) do
      {:ok, observations, current_task, continuation_hint} ->
        # Validate section headers
        case validate_sections(observations) do
          :ok ->
            {:ok,
             %{
               observations: observations,
               current_task: current_task,
               continuation_hint: continuation_hint
             }}

          {:error, _reason} = error ->
            # Validation failed, try fallback
            fallback_parse(output, error)
        end

      :error ->
        # XML extraction failed, try fallback
        fallback_parse(output, {:error, "XML parsing failed"})
    end
  end

  @doc """
  Merges new observations into existing observations using section-aware rules.

  ## Merge Strategy (from spec section 3.5)

  - `## Current State` — **Replace** entire section
  - `## User Preferences` — **Append** new entries
  - `## Decisions` — **Append** new entries
  - `## Session History` — **Append** new entries
  - `## Files & Architecture` — **Append with dedup** (same file path updates existing entry)
  - Unknown sections — **Ignore**

  ## Examples

      iex> existing = "## Current State\\n- Old task\\n\\n## User Preferences\\n- Pref 1\\n"
      iex> new_obs = "## Current State\\n- New task\\n\\n## User Preferences\\n- Pref 2\\n"
      iex> merged = Deft.OM.Observer.Parse.merge_observations(existing, new_obs)
      iex> String.contains?(merged, "New task")
      true
      iex> String.contains?(merged, "Old task")
      false
      iex> String.contains?(merged, "Pref 1")
      true
      iex> String.contains?(merged, "Pref 2")
      true
  """
  # Standard section names in canonical order
  @section_order [
    "Current State",
    "User Preferences",
    "Files & Architecture",
    "Decisions",
    "Session History"
  ]

  @spec merge_observations(String.t(), String.t()) :: String.t()
  def merge_observations(existing, new_observations)
      when is_binary(existing) and is_binary(new_observations) do
    existing_sections = parse_sections(existing)
    new_sections = parse_sections(new_observations)

    # Merge sections according to strategy
    merged_sections =
      @section_order
      |> Enum.map(fn section_name ->
        merge_section(
          section_name,
          Map.get(existing_sections, section_name),
          Map.get(new_sections, section_name)
        )
      end)
      |> Enum.reject(&is_nil/1)

    # Rejoin sections with double newline separation
    Enum.join(merged_sections, "\n\n")
  end

  @doc """
  Parse observations into a map of section_name => content.

  Returns a map where keys are section names (without "##") and values are
  the section content (without the header line).

  ## Examples

      iex> obs = "## Current State\\n- Task 1\\n\\n## User Preferences\\n- Pref 1\\n"
      iex> sections = Deft.OM.Observer.Parse.parse_sections(obs)
      iex> Map.get(sections, "Current State")
      "- Task 1"
  """
  @spec parse_sections(String.t()) :: %{String.t() => String.t()}
  def parse_sections(observations) do
    lines = String.split(observations, "\n")

    {sections, current_section, current_lines} =
      Enum.reduce(lines, {%{}, nil, []}, fn line, {sections, current_section, current_lines} ->
        case Regex.run(~r/^## (.+)$/, line, capture: :all_but_first) do
          [section_name] ->
            # New section header - save previous section if exists
            sections =
              if current_section do
                content = current_lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
                Map.put(sections, current_section, content)
              else
                sections
              end

            {sections, String.trim(section_name), []}

          nil ->
            # Content line - accumulate
            {sections, current_section, [line | current_lines]}
        end
      end)

    # Save the last section
    if current_section do
      content = current_lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
      Map.put(sections, current_section, content)
    else
      sections
    end
  end

  ## Private Functions

  # Extract content from XML tags
  defp extract_xml_blocks(output) do
    # Extract <observations>...</observations>
    observations =
      case Regex.run(~r/<observations>(.*?)<\/observations>/s, output, capture: :all_but_first) do
        [content] -> String.trim(content)
        _ -> nil
      end

    # Extract <current-task>...</current-task>
    current_task =
      case Regex.run(~r/<current-task>(.*?)<\/current-task>/s, output, capture: :all_but_first) do
        [content] -> String.trim(content)
        _ -> nil
      end

    # Extract <continuation-hint>...</continuation-hint>
    continuation_hint =
      case Regex.run(~r/<continuation-hint>(.*?)<\/continuation-hint>/s, output,
             capture: :all_but_first
           ) do
        [content] -> String.trim(content)
        _ -> nil
      end

    if observations do
      {:ok, observations, current_task, continuation_hint}
    else
      :error
    end
  end

  # Validate that sections are from the allowed set
  defp validate_sections(observations) do
    section_headers = Regex.scan(~r/^## (.+)$/m, observations, capture: :all_but_first)
    section_names = Enum.map(section_headers, fn [name] -> String.trim(name) end)

    invalid_sections = Enum.reject(section_names, fn name -> name in @section_order end)

    if Enum.empty?(invalid_sections) do
      :ok
    else
      {:error, "Invalid sections: #{Enum.join(invalid_sections, ", ")}"}
    end
  end

  # Fallback to raw bullet-list extraction when XML parsing fails
  defp fallback_parse(output, _original_error) do
    # Try to extract observations even without XML tags
    # Look for section headers and content
    if Regex.match?(~r/^## /m, output) do
      # Has section headers, treat the whole thing as observations
      {:ok, %{observations: String.trim(output), current_task: nil, continuation_hint: nil}}
    else
      # No recognizable structure
      {:error, "Could not parse output: no XML tags and no section headers found"}
    end
  end

  # Merge a single section according to its strategy
  defp merge_section(section_name, existing_content, new_content)

  # No content in either - skip section
  defp merge_section(_section_name, nil, nil), do: nil

  # No new content - keep existing
  defp merge_section(section_name, existing_content, nil) when not is_nil(existing_content) do
    "## #{section_name}\n#{existing_content}"
  end

  # No existing content - use new
  defp merge_section(section_name, nil, new_content) when not is_nil(new_content) do
    "## #{section_name}\n#{new_content}"
  end

  # Current State - replace strategy
  defp merge_section("Current State", _existing_content, new_content) do
    "## Current State\n#{new_content}"
  end

  # Files & Architecture - append with dedup strategy
  defp merge_section("Files & Architecture", existing_content, new_content) do
    existing_entries = parse_file_entries(existing_content)
    new_entries = parse_file_entries(new_content)

    # Merge: new entries override existing ones with same filepath
    merged_map = Map.merge(existing_entries, new_entries)

    # Reconstruct in order (existing first, then new)
    all_keys =
      (Map.keys(existing_entries) ++ Map.keys(new_entries))
      |> Enum.uniq()

    merged_lines =
      all_keys
      |> Enum.map(fn key -> Map.get(merged_map, key) end)
      |> Enum.join("\n")

    "## Files & Architecture\n#{merged_lines}"
  end

  # User Preferences, Decisions, Session History - append strategy
  defp merge_section(section_name, existing_content, new_content) do
    "## #{section_name}\n#{existing_content}\n#{new_content}"
  end

  # Parse file entries for deduplication
  # Returns a map of filepath => full line
  defp parse_file_entries(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      # Try to extract filepath from patterns like:
      # - (14:40) 🟡 Read src/auth.ex — contains...
      # - (14:45) 🟡 Modified src/auth.ex — added...
      # - (14:42) 🟡 Architecture: gen_statem for...
      case extract_filepath(line) do
        {:ok, filepath} -> Map.put(acc, filepath, line)
        # Use line as its own key if no filepath
        :error -> Map.put(acc, line, line)
      end
    end)
  end

  # Extract filepath from a file observation line
  defp extract_filepath(line) do
    cond do
      # Match "Read <filepath>" or "Modified <filepath>"
      match = Regex.run(~r/(?:Read|Modified)\s+([^\s—]+)/, line, capture: :all_but_first) ->
        {:ok, List.first(match)}

      # Match "Architecture:" - use whole line as key (not dedupable by path)
      String.contains?(line, "Architecture:") ->
        :error

      # Other patterns - use line as-is
      true ->
        :error
    end
  end
end
