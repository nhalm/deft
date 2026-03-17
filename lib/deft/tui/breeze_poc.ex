defmodule Deft.TUI.BreezePOC do
  @moduledoc """
  Proof-of-concept for Breeze streaming performance.

  Tests:
  - 1000+ lines of mixed text
  - 30 tokens/sec append rate
  - Scrollable area + fixed input + status bar

  If performance is acceptable, this validates Breeze for production use.
  If not, we fall back to Termite + BackBreeze.

  Run with: mix run -e "Deft.TUI.BreezePOC.run()"
  """

  use Breeze.View

  alias Breeze.Server

  @total_lines 1200
  @chars_per_token 4

  # Sample content: mix of code, markdown, and plain text
  @sample_blocks [
    "This is a paragraph of regular text that represents typical LLM output.\n",
    "**Bold text** and *italic text* mixed with `inline code` examples.\n",
    "```elixir\ndefmodule Example do\n  def hello, do: :world\nend\n```\n",
    "1. First item in a numbered list\n",
    "2. Second item with more details\n",
    "3. Third item to complete the example\n",
    "- Bullet point one\n",
    "- Bullet point two with a longer description that might wrap\n",
    "- Bullet point three\n",
    "Let me analyze the code structure and provide a detailed explanation of how this works.\n",
    "The main components are organized into several modules that handle different aspects.\n",
    "> A blockquote with some philosophical musings about software architecture\n",
    "Here's a table of results:\n\n| Column 1 | Column 2 | Column 3 |\n|----------|----------|-----------|\n",
    "Now let's examine the function implementation in detail, line by line.\n",
    "```python\ndef example():\n    return 'Another code block'\n```\n"
  ]

  def mount(_params, term) do
    # Generate all content upfront for the POC
    content = generate_content(@total_lines)

    term =
      term
      |> assign(
        content: [],
        generated_content: content,
        current_index: 0,
        tokens_sent: 0,
        start_time: System.monotonic_time(:millisecond),
        streaming: false,
        input: "Press 's' to start, 'q' to quit",
        scroll_offset: 0
      )

    {:ok, term}
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        total_tokens:
          (length(assigns.generated_content) * @chars_per_token / 4)
          |> trunc()
      )

    ~H"""
    <box>
      <box style="bold border">Breeze Streaming POC</box>

      <box style="border height-30">
        <%= for line <- @content do %>
          <box><%= line %></box>
        <% end %>
        <%= if @streaming do %>
          <box>▊</box>
        <% end %>
      </box>

      <box style="border">
        <box>> <%= @input %></box>
      </box>

      <box style="border">
        <box>
          Tokens: <%= @tokens_sent %>/<%= @total_tokens %> |
          Lines: <%= length(@content) %>/<%= @total_lines %> |
          <%= if @streaming, do: "◉ streaming", else: "○ idle" %>
        </box>
      </box>
    </box>
    """
  end

  def handle_event(_event, %{"key" => "s"}, term) do
    if not term.assigns.streaming do
      # Start the streaming simulation
      send(self(), :stream_token)
      {:noreply, assign(term, streaming: true)}
    else
      {:noreply, term}
    end
  end

  def handle_event(_event, %{"key" => "q"}, term) do
    {:stop, term}
  end

  def handle_event(_event, %{"key" => key}, term) do
    # Simple input handling for display
    {:noreply, assign(term, input: term.assigns.input <> key)}
  end

  def handle_event(_event, _params, term) do
    {:noreply, term}
  end

  def handle_info(:stream_token, term) do
    current_index = term.assigns.current_index
    generated = term.assigns.generated_content

    if current_index >= length(generated) do
      # Done streaming
      elapsed = System.monotonic_time(:millisecond) - term.assigns.start_time
      lines = length(term.assigns.content)

      # Write results to a file since we can't IO.puts in alt screen
      result = """
      === STREAMING COMPLETE ===
      Total lines: #{lines}
      Total tokens: #{term.assigns.tokens_sent}
      Time elapsed: #{elapsed}ms (#{elapsed / 1000}s)
      Actual rate: #{term.assigns.tokens_sent / (elapsed / 1000)} tokens/sec
      ========================
      """

      File.write!("/tmp/breeze_poc_results.txt", result)

      {:noreply, assign(term, streaming: false, input: "Done! Check /tmp/breeze_poc_results.txt")}
    else
      # Append next chunk
      chunk = Enum.at(generated, current_index)
      new_content = term.assigns.content ++ [chunk]

      # Calculate approximate tokens (rough estimate: 1 token ≈ 4 chars)
      tokens_in_chunk = String.length(chunk) |> div(@chars_per_token)

      # Schedule next token batch to maintain ~30 tokens/sec
      # At 30 tokens/sec, each token takes ~33ms
      Process.send_after(self(), :stream_token, 33)

      term =
        term
        |> assign(content: new_content)
        |> assign(current_index: current_index + 1)
        |> assign(tokens_sent: term.assigns.tokens_sent + tokens_in_chunk)

      {:noreply, term}
    end
  end

  # Generate mixed content to reach target line count
  defp generate_content(target_lines) do
    blocks_needed = ceil(target_lines / Enum.count(@sample_blocks))

    1..blocks_needed
    |> Enum.flat_map(fn i ->
      # Vary the content slightly
      Enum.map(@sample_blocks, fn block ->
        if rem(i, 5) == 0 do
          "=== Section #{div(i, 5)} ===\n" <> block
        else
          block
        end
      end)
    end)
    |> Enum.take(target_lines)
  end

  @doc """
  Run the POC interactively.

  Usage:
      mix run -e "Deft.TUI.BreezePOC.run()"

  Press 's' to begin streaming, 'q' to quit.
  The POC will stream 1200 lines at ~30 tokens/sec and report performance.
  """
  def run do
    IO.puts("""
    ╔══════════════════════════════════════════════════════════════╗
    ║           Breeze Streaming POC                               ║
    ║                                                              ║
    ║  This test simulates:                                        ║
    ║  - 1200 lines of mixed markdown/code/text                    ║
    ║  - 30 tokens/second streaming rate                           ║
    ║  - Scrollable content area                                   ║
    ║  - Fixed input and status bar                                ║
    ║                                                              ║
    ║  Press 's' to start streaming, 'q' to quit.                  ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    try do
      Server.start_link(view: __MODULE__)
      # Keep the process alive
      Process.sleep(:infinity)
    rescue
      e ->
        IO.puts("\n❌ Breeze error occurred: #{inspect(e)}")
        run_fallback_test()
    end
  end

  @doc """
  Run a non-interactive fallback performance test.

  This simulates the streaming without Breeze to test basic performance.
  """
  def run_fallback_test do
    IO.puts("\nRunning fallback performance test (non-interactive)...\n")

    content = generate_content(@total_lines)
    start_time = System.monotonic_time(:millisecond)

    # Simulate rendering each chunk
    rendered =
      Enum.reduce(content, {[], 0}, fn chunk, {acc, token_count} ->
        # Simulate per-token delay (30 tokens/sec = 33ms per token)
        tokens_in_chunk = String.length(chunk) |> div(@chars_per_token)
        Process.sleep(33)

        {acc ++ [chunk], token_count + tokens_in_chunk}
      end)

    {final_content, total_tokens} = rendered
    elapsed = System.monotonic_time(:millisecond) - start_time

    IO.puts("=== FALLBACK TEST RESULTS ===")
    IO.puts("Total lines: #{length(final_content)}")
    IO.puts("Total tokens: #{total_tokens}")
    IO.puts("Time elapsed: #{elapsed}ms (#{elapsed / 1000}s)")
    IO.puts("Actual rate: #{total_tokens / (elapsed / 1000)} tokens/sec")
    IO.puts("Memory usage: #{:erlang.memory(:total) |> div(1024) |> div(1024)} MB")
    IO.puts("=============================\n")

    if elapsed / 1000 < 60 do
      IO.puts("✅ Performance acceptable (< 60 seconds for full render)")
      :ok
    else
      IO.puts("⚠️  Performance may be concerning (> 60 seconds)")
      IO.puts("Consider Termite + BackBreeze fallback")
      :slow
    end
  end
end
