defmodule Deft.TUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias Deft.TUI.Markdown

  describe "render/1" do
    test "renders plain text" do
      assert Markdown.render("hello world") == "hello world\n"
    end

    test "renders bold text" do
      result = Markdown.render("**bold** text")
      assert result =~ "\e[1mbold\e[22m"
    end

    test "renders italic text" do
      result = Markdown.render("*italic* text")
      assert result =~ "\e[3mitalic\e[23m"
    end

    test "renders inline code" do
      result = Markdown.render("`code` snippet")
      assert result =~ "\e[36mcode\e[39m"
    end

    test "renders fenced code block without language" do
      markdown = """
      ```
      def hello
        :world
      end
      ```
      """

      result = Markdown.render(markdown)
      assert result =~ "```"
      assert result =~ "def hello"
      assert result =~ ":world"
    end

    test "renders fenced code block with language" do
      markdown = """
      ```elixir
      def hello
        :world
      end
      ```
      """

      result = Markdown.render(markdown)
      assert result =~ "elixir"
      assert result =~ "def hello"
    end

    test "renders unordered list" do
      markdown = """
      - item 1
      - item 2
      - item 3
      """

      result = Markdown.render(markdown)
      assert result =~ "• item 1"
      assert result =~ "• item 2"
      assert result =~ "• item 3"
    end

    test "renders ordered list" do
      markdown = """
      1. first
      2. second
      3. third
      """

      result = Markdown.render(markdown)
      assert result =~ "1. first"
      assert result =~ "2. second"
      assert result =~ "3. third"
    end

    test "renders headings" do
      assert Markdown.render("# H1") =~ "\e[1m"
      assert Markdown.render("## H2") =~ "\e[1m"
      assert Markdown.render("### H3") =~ "\e[1m"
    end

    test "renders links" do
      result = Markdown.render("[link text](https://example.com)")
      assert result =~ "link text"
      assert result =~ "https://example.com"
    end

    test "renders blockquote" do
      markdown = """
      > This is a quote
      > with multiple lines
      """

      result = Markdown.render(markdown)
      assert result =~ "This is a quote"
      assert result =~ "with multiple lines"
    end

    test "renders horizontal rule" do
      result = Markdown.render("---")
      assert result =~ "─"
    end

    test "handles mixed formatting" do
      markdown = "**bold** and *italic* and `code`"
      result = Markdown.render(markdown)
      assert result =~ "\e[1mbold\e[22m"
      assert result =~ "\e[3mitalic\e[23m"
      assert result =~ "\e[36mcode\e[39m"
    end

    test "handles nested lists" do
      markdown = """
      - top level
        - nested item
      - another top
      """

      result = Markdown.render(markdown)
      assert result =~ "top level"
      assert result =~ "nested item"
    end
  end

  describe "render_streaming/1" do
    test "buffers incomplete line without newline" do
      {rendered, buffered} = Markdown.render_streaming("**bold")
      assert rendered == ""
      assert buffered == "**bold"
    end

    test "renders complete line with newline" do
      {rendered, buffered} = Markdown.render_streaming("**bold** text\n")
      assert rendered =~ "\e[1mbold\e[22m"
      assert buffered == ""
    end

    test "renders complete lines and buffers incomplete" do
      markdown = "**bold** text\nincomplete"
      {rendered, buffered} = Markdown.render_streaming(markdown)

      assert rendered =~ "\e[1mbold\e[22m"
      assert buffered == "incomplete"
    end

    test "handles multiple complete lines" do
      markdown = "line 1\nline 2\nline 3\n"
      {rendered, buffered} = Markdown.render_streaming(markdown)

      assert rendered =~ "line 1"
      assert rendered =~ "line 2"
      assert rendered =~ "line 3"
      assert buffered == ""
    end

    test "handles empty string" do
      {rendered, buffered} = Markdown.render_streaming("")
      assert rendered == ""
      assert buffered == ""
    end

    test "handles single newline" do
      {rendered, buffered} = Markdown.render_streaming("\n")
      # A single newline has no content, so renders to empty string
      assert rendered == ""
      assert buffered == ""
    end

    test "buffers partial code block" do
      # Note: line-based buffering means the incomplete last line is buffered
      # The complete first line "```elixir" will be rendered
      markdown = "```elixir\ndef hello"
      {rendered, buffered} = Markdown.render_streaming(markdown)
      # The first line "```elixir" is complete and will be rendered as a code block
      assert rendered =~ "```"
      assert buffered == "def hello"
    end

    test "renders complete code block" do
      markdown = """
      ```elixir
      def hello
        :world
      end
      ```
      """

      {rendered, buffered} = Markdown.render_streaming(markdown)
      assert rendered =~ "elixir"
      assert rendered =~ "def hello"
      assert buffered == ""
    end
  end
end
