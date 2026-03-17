defmodule Deft.TUI.Markdown do
  @moduledoc """
  Converts markdown to ANSI-formatted text for terminal display.

  Uses EarmarkParser to parse markdown into an AST, then walks the AST
  to emit ANSI escape codes for formatting (bold, italic, code, etc.).

  Supports streaming partial markdown by buffering incomplete lines.
  """

  @doc """
  Renders markdown text to ANSI-formatted string.

  Supports:
  - Bold text (**bold** or __bold__)
  - Italic text (*italic* or _italic_)
  - Inline code (`code`)
  - Fenced code blocks (```lang...```)
  - Bullet lists (-, *, +)
  - Numbered lists (1., 2., etc.)
  - Headings (# H1, ## H2, etc.)

  ## Examples

      iex> Deft.TUI.Markdown.render("**bold** text")
      "\\e[1mbold\\e[22m text"

      iex> Deft.TUI.Markdown.render("*italic* text")
      "\\e[3mitalic\\e[23m text"

  """
  @spec render(String.t()) :: String.t()
  def render(markdown) do
    case EarmarkParser.as_ast(markdown) do
      {:ok, ast, _messages} ->
        ast
        |> render_ast()
        |> IO.iodata_to_binary()

      {:error, ast, _errors} ->
        # Even with errors, try to render what we have
        ast
        |> render_ast()
        |> IO.iodata_to_binary()
    end
  end

  @doc """
  Renders markdown with streaming support.

  Buffers the last incomplete line to handle partial markdown.
  Returns `{rendered_text, buffered_incomplete_line}`.

  ## Examples

      iex> Deft.TUI.Markdown.render_streaming("**bold")
      {"", "**bold"}

      iex> Deft.TUI.Markdown.render_streaming("**bold** complete\\n")
      {"\\e[1mbold\\e[22m complete\\n", ""}

  """
  @spec render_streaming(String.t()) :: {String.t(), String.t()}
  def render_streaming(markdown) do
    # Split into complete and incomplete parts
    # A line is complete if it ends with \n
    cond do
      markdown == "" ->
        {"", ""}

      String.ends_with?(markdown, "\n") ->
        # All complete, nothing to buffer
        {render(markdown), ""}

      true ->
        # Has incomplete content at the end
        # Find the last newline
        case String.split(markdown, "\n") do
          [single] ->
            # No newline found, buffer everything
            {"", single}

          parts ->
            # Last element is incomplete
            incomplete = List.last(parts)
            complete_lines = Enum.drop(parts, -1)

            complete_text =
              if complete_lines == [] do
                ""
              else
                complete_lines
                |> Enum.join("\n")
                |> then(&(&1 <> "\n"))
                |> render()
              end

            {complete_text, incomplete}
        end
    end
  end

  # Private functions

  defp render_ast(ast) do
    Enum.map(ast, &render_node/1)
  end

  # Text node
  defp render_node(text) when is_binary(text) do
    text
  end

  # Paragraph
  defp render_node({"p", _attrs, children, _meta}) do
    [render_ast(children), "\n"]
  end

  # Headings
  defp render_node({"h1", _attrs, children, _meta}) do
    ["\e[1m\e[4m", render_ast(children), "\e[24m\e[22m\n"]
  end

  defp render_node({"h2", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m\n"]
  end

  defp render_node({"h3", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m\n"]
  end

  defp render_node({"h4", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m\n"]
  end

  defp render_node({"h5", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m\n"]
  end

  defp render_node({"h6", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m\n"]
  end

  # Bold (strong)
  defp render_node({"strong", _attrs, children, _meta}) do
    ["\e[1m", render_ast(children), "\e[22m"]
  end

  # Italic (em)
  defp render_node({"em", _attrs, children, _meta}) do
    ["\e[3m", render_ast(children), "\e[23m"]
  end

  # Inline code
  defp render_node({"code", attrs, children, _meta}) do
    # Check if this is inside a pre tag (fenced code block)
    # For inline code, we use a different style
    case List.keyfind(attrs, "class", 0) do
      {"class", "inline"} ->
        # Inline code - use cyan color
        ["\e[36m", render_ast(children), "\e[39m"]

      {"class", _lang} ->
        # This is a fenced code block, content only (pre handles formatting)
        render_ast(children)

      nil ->
        # Fallback: treat as inline code
        ["\e[36m", render_ast(children), "\e[39m"]
    end
  end

  # Fenced code block (pre + code)
  defp render_node({"pre", _attrs, children, _meta}) do
    # Extract language if present
    {lang, code_content} =
      case children do
        [{"code", attrs, code_children, _}] ->
          lang =
            case List.keyfind(attrs, "class", 0) do
              {"class", class} ->
                # Class is typically "language-<lang>"
                String.replace_prefix(class, "inline-", "")
                |> String.replace_prefix("language-", "")

              nil ->
                nil
            end

          {lang, code_children}

        _ ->
          {nil, children}
      end

    lang_label = if lang, do: " #{lang}", else: ""

    [
      "\e[90m```#{lang_label}\e[39m\n",
      "\e[2m",
      render_ast(code_content),
      "\e[22m",
      "\e[90m```\e[39m\n"
    ]
  end

  # Unordered list
  defp render_node({"ul", _attrs, children, _meta}) do
    [render_list_items(children, "• "), "\n"]
  end

  # Ordered list
  defp render_node({"ol", _attrs, children, _meta}) do
    children
    |> Enum.with_index(1)
    |> Enum.map(fn {child, index} ->
      render_list_item(child, "#{index}. ")
    end)
    |> then(&[&1, "\n"])
  end

  # List item
  defp render_node({"li", _attrs, children, _meta}) do
    render_ast(children)
  end

  # Blockquote
  defp render_node({"blockquote", _attrs, children, _meta}) do
    children
    |> render_ast()
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.map(fn line ->
      if line == "" do
        "\e[90m│\e[39m\n"
      else
        ["\e[90m│\e[39m ", line, "\n"]
      end
    end)
  end

  # Links
  defp render_node({"a", attrs, children, _meta}) do
    href = List.keyfind(attrs, "href", 0) |> elem(1)
    ["\e[34m\e[4m", render_ast(children), "\e[24m\e[39m (", href, ")"]
  end

  # Horizontal rule
  defp render_node({"hr", _attrs, _children, _meta}) do
    "\e[90m────────────────────────────────────────\e[39m\n"
  end

  # Break
  defp render_node({"br", _attrs, _children, _meta}) do
    "\n"
  end

  # Unknown/unsupported tags - just render children
  defp render_node({_tag, _attrs, children, _meta}) do
    render_ast(children)
  end

  # Helper for rendering list items with bullets
  defp render_list_items(items, bullet) do
    Enum.map(items, fn item ->
      render_list_item(item, bullet)
    end)
  end

  defp render_list_item({"li", _attrs, children, _meta}, bullet) do
    content =
      children
      |> render_ast()
      |> IO.iodata_to_binary()

    # Handle multi-line list items by indenting continuation lines
    lines = String.split(content, "\n", trim: true)

    case lines do
      [] ->
        [bullet, "\n"]

      [single] ->
        [bullet, single, "\n"]

      [first | rest] ->
        indent = String.duplicate(" ", String.length(bullet))

        [
          bullet,
          first,
          "\n",
          Enum.map(rest, fn line ->
            [indent, line, "\n"]
          end)
        ]
    end
  end

  defp render_list_item(node, bullet) do
    [bullet, render_node(node), "\n"]
  end
end
