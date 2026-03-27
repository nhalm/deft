defmodule Deft.Check.Refactor.FunctionBodyLength do
  use Credo.Check,
    base_priority: :low,
    category: :refactor,
    explanations: [
      check: """
      Functions should not exceed a maximum body length.

      Long functions do too much and should be split into smaller, focused functions.
      This improves readability, testability, and maintainability.
      """,
      params: [
        max_lines: "Maximum number of lines allowed in a function body (default: 25)"
      ]
    ]

  @moduledoc false

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta

  @default_params [max_lines: 25]

  @doc false
  def run(%Credo.SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    max_lines = Params.get(params, :max_lines, @default_params)
    context = %{issue_meta: issue_meta, max_lines: max_lines}

    Code.prewalk(source_file, &traverse(&1, &2, context))
  end

  # Traverse def and defp nodes
  defp traverse(
         {:def, meta, [{_name, _meta, _args} = signature, body]} = ast,
         issues,
         context
       ) do
    {ast, check_function(meta, signature, body, issues, context)}
  end

  defp traverse(
         {:defp, meta, [{_name, _meta, _args} = signature, body]} = ast,
         issues,
         context
       ) do
    {ast, check_function(meta, signature, body, issues, context)}
  end

  defp traverse(ast, issues, _context) do
    {ast, issues}
  end

  defp check_function(meta, {name, _, args}, body, issues, context) do
    line_count = count_body_lines(meta, body)

    if line_count > context.max_lines do
      issue_params = %{
        line_no: meta[:line],
        function_name: name,
        arity: arity(args),
        actual: line_count,
        max: context.max_lines
      }

      [issue_for(context.issue_meta, issue_params) | issues]
    else
      issues
    end
  end

  defp count_body_lines(_meta, nil), do: 0

  defp count_body_lines(meta, body) do
    start_line = meta[:line]
    end_line = get_end_line(meta, body)

    if start_line && end_line && end_line >= start_line do
      # Subtract 1 to not count the def/defp line itself
      end_line - start_line
    else
      0
    end
  end

  defp get_end_line(meta, _body) do
    case meta[:end] do
      {line, _} -> line
      line when is_integer(line) -> line
      _ -> meta[:line]
    end
  end

  defp arity(nil), do: 0
  defp arity(args) when is_list(args), do: length(args)
  defp arity(_), do: 0

  defp issue_for(issue_meta, params) do
    format_issue(
      issue_meta,
      message:
        "Function #{params.function_name}/#{params.arity} has a body length of " <>
          "#{params.actual} (max: #{params.max})",
      line_no: params.line_no
    )
  end
end
