defmodule Deft.Tools.Edit do
  @moduledoc """
  Tool for editing files via string replacement or line-range replacement.

  Supports two modes:
  1. String match mode - requires unique match of old_string, returns unified diff
  2. Line-range mode - replaces specific line range with new content

  Enforces file scope when set.
  """

  @behaviour Deft.Tool

  alias Deft.Message.Text
  alias Deft.Tool.Context

  @impl Deft.Tool
  def name, do: "edit"

  @impl Deft.Tool
  def description do
    "Edit a file using string replacement (unique old_string match) or line-range replacement. " <>
      "Returns a unified diff of changes."
  end

  @impl Deft.Tool
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "file_path" => %{
          "type" => "string",
          "description" => "The absolute path to the file to edit"
        },
        "old_string" => %{
          "type" => "string",
          "description" => "String to replace (must match uniquely). Used in string-match mode."
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Replacement string. Used in string-match mode."
        },
        "start_line" => %{
          "type" => "integer",
          "description" => "Starting line number (1-indexed). Used in line-range mode."
        },
        "end_line" => %{
          "type" => "integer",
          "description" => "Ending line number (1-indexed, inclusive). Used in line-range mode."
        },
        "new_content" => %{
          "type" => "string",
          "description" => "New content to replace the line range. Used in line-range mode."
        }
      },
      "required" => ["file_path"]
    }
  end

  @impl Deft.Tool
  def execute(args, %Context{working_dir: working_dir, file_scope: file_scope}) do
    file_path = args["file_path"]
    absolute_path = resolve_absolute_path(file_path, working_dir)

    with :ok <- check_file_scope(absolute_path, file_scope),
         :ok <- validate_file_exists(absolute_path, file_path) do
      dispatch_edit_mode(args, absolute_path, file_path)
    end
  end

  defp resolve_absolute_path(file_path, working_dir) do
    if Path.type(file_path) == :absolute do
      file_path
    else
      Path.join(working_dir, file_path)
    end
  end

  defp dispatch_edit_mode(
         %{"old_string" => old, "new_string" => new},
         absolute_path,
         display_path
       )
       when not is_nil(old) and not is_nil(new) do
    string_match_mode(absolute_path, old, new, display_path)
  end

  defp dispatch_edit_mode(
         %{"start_line" => start, "end_line" => end_l, "new_content" => content},
         absolute_path,
         display_path
       )
       when not is_nil(start) and not is_nil(end_l) and not is_nil(content) do
    line_range_mode(absolute_path, start, end_l, content, display_path)
  end

  defp dispatch_edit_mode(_args, _absolute_path, _display_path) do
    {:error,
     "Must provide either (old_string, new_string) for string-match mode or " <>
       "(start_line, end_line, new_content) for line-range mode"}
  end

  defp check_file_scope(_path, nil), do: :ok

  defp check_file_scope(absolute_path, file_scope) do
    # Normalize both paths for comparison
    normalized_path = Path.expand(absolute_path)

    in_scope? =
      Enum.any?(file_scope, fn scope_path ->
        normalized_scope = Path.expand(scope_path)
        String.starts_with?(normalized_path, normalized_scope)
      end)

    if in_scope? do
      :ok
    else
      {:error, "path outside file scope"}
    end
  end

  defp validate_file_exists(absolute_path, display_path) do
    cond do
      not File.exists?(absolute_path) ->
        {:error, "File not found: #{display_path}"}

      File.dir?(absolute_path) ->
        {:error, "Path is a directory, not a file: #{display_path}"}

      true ->
        :ok
    end
  end

  defp string_match_mode(absolute_path, old_string, new_string, display_path) do
    with {:ok, content} <- File.read(absolute_path),
         occurrences <- count_occurrences(content, old_string),
         :ok <- validate_occurrence_count(occurrences, old_string, content, display_path) do
      perform_string_replacement(absolute_path, content, old_string, new_string, display_path)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read file: #{:file.format_error(reason)}"}

      {:error, _} = error ->
        error
    end
  end

  defp validate_occurrence_count(0, old_string, content, display_path) do
    similar_text = find_similar_text(content, old_string)
    error_msg = build_not_found_error(display_path, similar_text)
    {:error, error_msg}
  end

  defp validate_occurrence_count(occurrences, _old_string, _content, display_path)
       when occurrences > 1 do
    {:error, "String appears #{occurrences} times in file (must be unique): #{display_path}"}
  end

  defp validate_occurrence_count(1, _old_string, _content, _display_path), do: :ok

  defp build_not_found_error(display_path, nil) do
    "String not found in file: #{display_path}"
  end

  defp build_not_found_error(display_path, similar_text) do
    "String not found in file: #{display_path}\n\nDid you mean:\n#{similar_text}"
  end

  defp perform_string_replacement(absolute_path, content, old_string, new_string, display_path) do
    new_content = String.replace(content, old_string, new_string, global: false)

    case File.write(absolute_path, new_content) do
      :ok ->
        diff = generate_unified_diff(content, new_content, display_path)
        {:ok, [%Text{text: diff}]}

      {:error, reason} ->
        {:error, "Failed to write file: #{:file.format_error(reason)}"}
    end
  end

  defp line_range_mode(absolute_path, start_line, end_line, new_content, display_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total_lines = length(lines)

        with :ok <- validate_line_range(start_line, end_line, total_lines, display_path) do
          replacement_params = %{
            absolute_path: absolute_path,
            original_content: content,
            lines: lines,
            start_line: start_line,
            end_line: end_line,
            new_content: new_content,
            display_path: display_path
          }

          perform_line_range_replacement(replacement_params)
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{:file.format_error(reason)}"}
    end
  end

  defp validate_line_range(start_line, end_line, total_lines, display_path) do
    cond do
      start_line < 1 or end_line < 1 ->
        {:error, "Line numbers must be >= 1"}

      start_line > end_line ->
        {:error, "start_line (#{start_line}) must be <= end_line (#{end_line})"}

      end_line > total_lines ->
        {:error,
         "end_line (#{end_line}) exceeds file length (#{total_lines} lines): #{display_path}"}

      true ->
        :ok
    end
  end

  defp perform_line_range_replacement(%{
         absolute_path: absolute_path,
         original_content: original_content,
         lines: lines,
         start_line: start_line,
         end_line: end_line,
         new_content: new_content,
         display_path: display_path
       }) do
    before = Enum.take(lines, start_line - 1)
    after_lines = Enum.drop(lines, end_line)
    new_lines = if new_content == "", do: [], else: String.split(new_content, "\n")

    new_file_lines = before ++ new_lines ++ after_lines
    new_file_content = Enum.join(new_file_lines, "\n")

    case File.write(absolute_path, new_file_content) do
      :ok ->
        diff = generate_unified_diff(original_content, new_file_content, display_path)
        {:ok, [%Text{text: diff}]}

      {:error, reason} ->
        {:error, "Failed to write file: #{:file.format_error(reason)}"}
    end
  end

  defp count_occurrences(content, search_string) do
    content
    |> String.split(search_string)
    |> length()
    |> Kernel.-(1)
  end

  defp find_similar_text(content, search_string) do
    # Find text that's somewhat similar to help the user
    # Look for lines that contain some words from the search string
    words = String.split(search_string, ~r/\s+/, trim: true)

    if Enum.empty?(words) do
      nil
    else
      find_matching_lines(content, words)
    end
  end

  defp find_matching_lines(content, words) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} ->
      Enum.any?(words, fn word -> String.contains?(line, word) end)
    end)
    |> Enum.take(3)
    |> format_similar_lines()
  end

  defp format_similar_lines([]), do: nil

  defp format_similar_lines(similar_lines) do
    similar_lines
    |> Enum.map(fn {line, line_num} -> "#{line_num}: #{line}" end)
    |> Enum.join("\n")
  end

  defp generate_unified_diff(old_content, new_content, file_path) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    diff_header = ["--- #{file_path}", "+++ #{file_path}"]

    # Find changed regions
    changes = find_changes(old_lines, new_lines)

    # Group changes into hunks with context
    hunks = group_into_hunks(changes, 3)

    # Generate hunk output with headers
    hunk_output =
      Enum.map(hunks, fn {hunk_changes, old_start, new_start} ->
        generate_hunk_with_header(hunk_changes, old_start, new_start)
      end)

    Enum.join(diff_header ++ hunk_output, "\n")
  end

  # Group diff operations into hunks with context lines
  defp group_into_hunks(changes, context_lines) do
    changes
    |> find_change_indices()
    |> build_hunk_ranges(changes, context_lines)
    |> extract_hunks(changes)
  end

  defp find_change_indices(changes) do
    changes
    |> Enum.with_index()
    |> Enum.filter(fn {{op, _}, _idx} -> op != :context end)
    |> Enum.map(fn {_, idx} -> idx end)
  end

  defp build_hunk_ranges([], _changes, _context_lines), do: []

  defp build_hunk_ranges(change_indices, changes, context_lines) do
    change_indices
    |> Enum.chunk_by(fn idx -> div(idx, context_lines * 2 + 1) end)
    |> Enum.map(fn group -> expand_range_with_context(group, changes, context_lines) end)
    |> merge_overlapping_ranges()
  end

  defp expand_range_with_context(group, changes, context_lines) do
    first = Enum.min(group)
    last = Enum.max(group)
    start_idx = max(0, first - context_lines)
    end_idx = min(length(changes) - 1, last + context_lines)
    {start_idx, end_idx}
  end

  defp extract_hunks(hunk_ranges, changes) do
    Enum.map(hunk_ranges, fn {start_idx, end_idx} ->
      hunk_changes = Enum.slice(changes, start_idx..end_idx)
      {old_start, new_start} = calculate_starting_lines(changes, start_idx)
      {hunk_changes, old_start, new_start}
    end)
  end

  # Calculate the starting line numbers for a hunk by counting through all preceding changes
  defp calculate_starting_lines(changes, start_idx) do
    # Count how many old and new lines precede this hunk
    {old_line, new_line} =
      changes
      |> Enum.take(start_idx)
      |> Enum.reduce({1, 1}, fn
        {:context, _}, {old, new} -> {old + 1, new + 1}
        {:delete, _}, {old, new} -> {old + 1, new}
        {:add, _}, {old, new} -> {old, new + 1}
      end)

    {old_line, new_line}
  end

  # Merge overlapping or adjacent ranges
  defp merge_overlapping_ranges([]), do: []
  defp merge_overlapping_ranges([range]), do: [range]

  defp merge_overlapping_ranges([{s1, e1} | rest]) do
    merge_overlapping_ranges(rest, [{s1, e1}])
  end

  defp merge_overlapping_ranges([], acc), do: Enum.reverse(acc)

  defp merge_overlapping_ranges([{s2, e2} | rest], [{s1, e1} | acc]) do
    if s2 <= e1 + 1 do
      # Overlapping or adjacent - merge
      merge_overlapping_ranges(rest, [{s1, max(e1, e2)} | acc])
    else
      # Not overlapping - keep separate
      merge_overlapping_ranges(rest, [{s2, e2}, {s1, e1} | acc])
    end
  end

  # Generate a hunk with its @@ header
  defp generate_hunk_with_header(hunk_changes, old_start_line, new_start_line) do
    # Calculate line numbers and counts for old and new files
    {old_start, old_count, new_start, new_count} =
      calculate_hunk_header(hunk_changes, old_start_line, new_start_line)

    # Format hunk header
    header = "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@"

    # Format hunk body
    body =
      Enum.map(hunk_changes, fn
        {:context, line} -> " #{line}"
        {:delete, line} -> "-#{line}"
        {:add, line} -> "+#{line}"
      end)

    Enum.join([header | body], "\n")
  end

  # Calculate the line numbers and counts for a hunk header
  defp calculate_hunk_header(hunk_changes, old_start_line, new_start_line) do
    initial_state = {nil, 0, nil, 0, {old_start_line, new_start_line}}

    {old_start, old_count, new_start, new_count, _} =
      Enum.reduce(hunk_changes, initial_state, &update_hunk_header_state/2)

    {old_start || old_start_line, old_count, new_start || new_start_line, new_count}
  end

  defp update_hunk_header_state({:context, _}, {old_s, old_c, new_s, new_c, {old_line, new_line}}) do
    {
      old_s || old_line,
      old_c + 1,
      new_s || new_line,
      new_c + 1,
      {old_line + 1, new_line + 1}
    }
  end

  defp update_hunk_header_state({:delete, _}, {old_s, old_c, new_s, new_c, {old_line, new_line}}) do
    {
      old_s || old_line,
      old_c + 1,
      new_s || new_line,
      new_c,
      {old_line + 1, new_line}
    }
  end

  defp update_hunk_header_state({:add, _}, {old_s, old_c, new_s, new_c, {old_line, new_line}}) do
    {
      old_s || old_line,
      old_c,
      new_s || new_line,
      new_c + 1,
      {old_line, new_line + 1}
    }
  end

  defp find_changes(old_lines, new_lines) do
    # Use Myers diff algorithm to produce minimal diff
    myers_diff(old_lines, new_lines)
  end

  # Myers diff algorithm - finds shortest edit script
  defp myers_diff(old_lines, new_lines) do
    n = length(old_lines)
    m = length(new_lines)
    max_d = n + m

    ctx = %{
      old_lines: old_lines,
      new_lines: new_lines,
      n: n,
      m: m,
      max_d: max_d
    }

    # Find the edit graph path using Myers algorithm
    {path, _} = myers_find_path(ctx)

    # Convert path to diff operations
    path_to_diff_ops(path, old_lines, new_lines)
  end

  defp myers_find_path(ctx) do
    # V maps each k-line to the farthest-reaching x coordinate
    initial_v = %{1 => 0}

    myers_search(ctx, 0, initial_v)
  end

  defp myers_search(%{max_d: max_d}, d, v) when d > max_d do
    # Shouldn't happen, but failsafe: return empty edit script
    {[], v}
  end

  defp myers_search(ctx, d, v) do
    # Try all k-lines for this d-value
    new_v =
      for k <- (d * -1)..d//2, reduce: v do
        acc_v ->
          x = choose_myers_direction(k, d, acc_v)

          # Follow diagonal as far as possible (matching lines)
          y = x - k
          {final_x, _final_y} = myers_follow_diagonal(ctx, x, y)

          # Store the furthest x for this k-line
          Map.put(acc_v, k, final_x)
      end

    # Check if we've reached the end
    final_k = ctx.m - ctx.n

    if Map.get(new_v, final_k, -1) >= ctx.n do
      # Reconstruct path by backtracking
      path = myers_backtrack(ctx)
      {path, new_v}
    else
      # Continue searching with d+1
      myers_search(ctx, d + 1, new_v)
    end
  end

  defp choose_myers_direction(k, d, acc_v) when k == -d do
    # Must move down (insert from new)
    Map.get(acc_v, k + 1, 0)
  end

  defp choose_myers_direction(k, d, acc_v) when k == d do
    # Must move right (delete from old)
    Map.get(acc_v, k - 1, 0) + 1
  end

  defp choose_myers_direction(k, _d, acc_v) do
    # Choose the path that gets us furthest
    x_down = Map.get(acc_v, k + 1, 0)
    x_right = Map.get(acc_v, k - 1, 0) + 1

    max(x_right, x_down)
  end

  defp myers_follow_diagonal(%{n: n, m: m}, x, y) when x >= n or y >= m do
    {x, y}
  end

  defp myers_follow_diagonal(%{old_lines: old_lines, new_lines: new_lines} = ctx, x, y) do
    if Enum.at(old_lines, x) == Enum.at(new_lines, y) do
      myers_follow_diagonal(ctx, x + 1, y + 1)
    else
      {x, y}
    end
  end

  defp myers_backtrack(ctx) do
    # Rebuild the path from (n, m) back to (0, 0)
    # For simplicity, we'll use a simpler LCS-based approach to build the edit script
    lcs_diff(ctx.old_lines, ctx.new_lines, ctx.n, ctx.m)
  end

  # LCS-based diff construction (simpler than full Myers backtrack)
  defp lcs_diff(old_lines, new_lines, n, m) do
    # Build LCS table
    lcs_table = build_lcs_table(old_lines, new_lines, n, m)

    # Backtrack to construct diff
    lcs_backtrack(lcs_table, old_lines, new_lines, n, m)
  end

  defp build_lcs_table(old_lines, new_lines, n, m) do
    # Initialize table with zeros
    initial_table = initialize_lcs_table(n, m)

    # Fill table using LCS recurrence
    fill_lcs_table(initial_table, old_lines, new_lines, n, m)
  end

  defp initialize_lcs_table(n, m) do
    for i <- 0..n, into: %{} do
      {i, Map.new(0..m, fn j -> {j, 0} end)}
    end
  end

  defp fill_lcs_table(table, old_lines, new_lines, n, m) do
    for i <- 1..n, j <- 1..m, reduce: table do
      acc_table ->
        value = compute_lcs_cell(acc_table, old_lines, new_lines, i, j)
        put_in(acc_table[i][j], value)
    end
  end

  defp compute_lcs_cell(table, old_lines, new_lines, i, j) do
    if Enum.at(old_lines, i - 1) == Enum.at(new_lines, j - 1) do
      table[i - 1][j - 1] + 1
    else
      max(table[i - 1][j], table[i][j - 1])
    end
  end

  defp lcs_backtrack(_table, _old_lines, _new_lines, 0, 0) do
    []
  end

  defp lcs_backtrack(_table, old_lines, _new_lines, i, 0) when i > 0 do
    # Remaining old lines are deletions
    for idx <- 0..(i - 1) do
      {:delete, Enum.at(old_lines, idx)}
    end
  end

  defp lcs_backtrack(_table, _old_lines, new_lines, 0, j) when j > 0 do
    # Remaining new lines are insertions
    for idx <- 0..(j - 1) do
      {:add, Enum.at(new_lines, idx)}
    end
  end

  defp lcs_backtrack(table, old_lines, new_lines, i, j) do
    if Enum.at(old_lines, i - 1) == Enum.at(new_lines, j - 1) do
      lcs_backtrack_match(table, old_lines, new_lines, i, j)
    else
      lcs_backtrack_differ(table, old_lines, new_lines, i, j)
    end
  end

  defp lcs_backtrack_match(table, old_lines, new_lines, i, j) do
    # Lines match - context
    lcs_backtrack(table, old_lines, new_lines, i - 1, j - 1) ++
      [{:context, Enum.at(old_lines, i - 1)}]
  end

  defp lcs_backtrack_differ(table, old_lines, new_lines, i, j) do
    # Lines differ - check which direction to go
    if table[i][j - 1] > table[i - 1][j] do
      # Insert from new
      lcs_backtrack(table, old_lines, new_lines, i, j - 1) ++
        [{:add, Enum.at(new_lines, j - 1)}]
    else
      # Delete from old
      lcs_backtrack(table, old_lines, new_lines, i - 1, j) ++
        [{:delete, Enum.at(old_lines, i - 1)}]
    end
  end

  defp path_to_diff_ops(_path, old_lines, new_lines) do
    # This is now handled by lcs_backtrack
    # Keeping this function for interface compatibility
    lcs_diff(old_lines, new_lines, length(old_lines), length(new_lines))
  end
end
