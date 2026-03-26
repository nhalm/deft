defmodule DeftWeb.ChatLiveTest do
  use DeftWeb.ConnCase, async: false

  # Helper to get LiveView state
  defp get_state(view) do
    :sys.get_state(view.pid)
  end

  defp get_assign(view, key) do
    get_state(view).socket.assigns[key]
  end

  setup do
    # Create a test session ID
    session_id = "test_session_#{System.unique_integer([:positive])}"

    %{session_id: session_id, conn: build_conn()}
  end

  describe "mount/3" do
    test "renders header with repo name", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ "Deft"
      assert html =~ Path.basename(File.cwd!())
    end

    test "starts in insert mode", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ "Insert"
    end

    test "initializes with empty conversation", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      assert get_assign(view, :messages) == []
      assert get_assign(view, :streaming_text) == ""
    end
  end

  describe "text_delta event" do
    test "updates conversation with streaming text", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:text_delta, "Hello "}})
      assert get_assign(view, :streaming_text) == "Hello "

      send(view.pid, {:agent_event, {:text_delta, "world"}})
      assert get_assign(view, :streaming_text) == "Hello world"
    end
  end

  describe "thinking_delta event" do
    test "renders thinking block with styling", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:thinking_delta, "analyzing the auth module..."}})

      html = render(view)
      assert html =~ "analyzing the auth module..."
      assert get_assign(view, :streaming_thinking) == "analyzing the auth module..."
    end

    test "accumulates thinking deltas", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:thinking_delta, "analyzing "}})
      send(view.pid, {:agent_event, {:thinking_delta, "the code..."}})

      assert get_assign(view, :streaming_thinking) == "analyzing the code..."
    end
  end

  describe "tool execution events" do
    test "tool_call_start shows spinner", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:tool_call_start, %{id: "tool_1", name: "read"}}})

      active_tools = get_assign(view, :active_tools)

      assert active_tools["tool_1"] == %{
               id: "tool_1",
               name: "read",
               status: :running,
               duration: nil,
               input: nil,
               output: nil,
               key_arg: nil
             }
    end

    test "tool_call_done and tool_execution_complete show success indicator", %{
      conn: conn,
      session_id: session_id
    } do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:tool_call_start, %{id: "tool_1", name: "read"}}})

      send(
        view.pid,
        {:agent_event, {:tool_call_done, %{id: "tool_1", args: %{"file_path" => "test.ex"}}}}
      )

      send(
        view.pid,
        {:agent_event,
         {:tool_execution_complete,
          %{id: "tool_1", success: true, duration: 500, result: {:ok, "file contents"}}}}
      )

      # Tool should be removed from active_tools after completion
      active_tools = get_assign(view, :active_tools)
      assert active_tools["tool_1"] == nil

      # Tool should be in the conversation stream
      html = render(view)
      assert html =~ "[Tool: read]"
      assert html =~ "test.ex"
    end

    test "tracks multiple tool calls", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(view.pid, {:agent_event, {:tool_call_start, %{id: "tool_1", name: "read"}}})
      send(view.pid, {:agent_event, {:tool_call_start, %{id: "tool_2", name: "bash"}}})

      active_tools = get_assign(view, :active_tools)
      assert map_size(active_tools) == 2
      assert active_tools["tool_1"].name == "read"
      assert active_tools["tool_2"].name == "bash"
    end
  end

  describe "vim mode keybindings" do
    test "Esc switches to normal mode", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Starts in insert mode
      assert get_assign(view, :vim_mode) == :insert

      # Press Escape
      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})

      assert get_assign(view, :vim_mode) == :normal
    end

    test "i in normal mode switches to insert", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Switch to normal mode first
      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})
      assert get_assign(view, :vim_mode) == :normal

      # Press i
      view |> element(".chat-container") |> render_keydown(%{"key" => "i"})

      assert get_assign(view, :vim_mode) == :insert
    end

    test "a in normal mode switches to insert", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})
      view |> element(".chat-container") |> render_keydown(%{"key" => "a"})

      assert get_assign(view, :vim_mode) == :insert
    end

    test "j/k scroll in normal mode", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Switch to normal mode
      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})

      initial_offset = get_assign(view, :scroll_offset)

      # Press j to scroll down
      view |> element(".chat-container") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :scroll_offset) == initial_offset + 1

      # Press k to scroll up
      view |> element(".chat-container") |> render_keydown(%{"key" => "k"})
      assert get_assign(view, :scroll_offset) == initial_offset
    end

    test "G scrolls to bottom in normal mode", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})
      view |> element(".chat-container") |> render_keydown(%{"key" => "G"})

      assert get_assign(view, :scroll_offset) == :bottom
    end

    test "gg scrolls to top in normal mode", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      view |> element(".chat-container") |> render_keydown(%{"key" => "Escape"})
      view |> element(".chat-container") |> render_keydown(%{"key" => "j"})
      view |> element(".chat-container") |> render_keydown(%{"key" => "j"})

      # First g sets pending
      view |> element(".chat-container") |> render_keydown(%{"key" => "g"})
      assert get_assign(view, :pending_g) == true

      # Second g scrolls to top
      view |> element(".chat-container") |> render_keydown(%{"key" => "g"})
      assert get_assign(view, :scroll_offset) == 0
      assert get_assign(view, :pending_g) == false
    end
  end

  describe "prompt submission" do
    test "Enter submits prompt", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Submit via form (Enter key in the input triggers the form submit)
      view |> element("form") |> render_submit(%{"input" => "test prompt"})

      # Check that input was cleared
      assert get_assign(view, :input) == ""
    end

    test "empty input is ignored", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      initial_messages = get_assign(view, :messages)

      view |> element("form") |> render_submit(%{"input" => "   "})

      assert get_assign(view, :messages) == initial_messages
    end
  end

  describe "slash commands" do
    test "/quit command is handled", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      view |> element("form") |> render_submit(%{"input" => "/quit"})

      # Should display shutdown message
      html = render(view)
      assert html =~ "Shutting down..."
    end

    test "/help command displays help", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      view |> element("form") |> render_submit(%{"input" => "/help"})

      html = render(view)
      assert html =~ "Available commands"
    end

    test "/clear command clears conversation", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Add some messages first
      view |> element("form") |> render_submit(%{"input" => "test message"})

      # Then clear
      view |> element("form") |> render_submit(%{"input" => "/clear"})

      assert get_assign(view, :messages) == []
    end
  end

  describe "agent roster" do
    test "appears on job_status event", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Initially no roster
      assert get_assign(view, :agent_statuses) == []
      assert get_assign(view, :roster_visible) == false

      # Send job_status event
      send(
        view.pid,
        {:job_status,
         [
           %{label: "Foreman", state: :executing},
           %{label: "Lead A", state: :implementing}
         ]}
      )

      html = render(view)
      assert html =~ "Foreman"
      assert html =~ "Lead A"
      assert get_assign(view, :roster_visible) == true
      assert length(get_assign(view, :agent_statuses)) == 2
    end
  end

  describe "status bar" do
    test "shows token count and cost", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Send usage event
      send(
        view.pid,
        {:agent_event, {:usage, %{input: 1000, output: 500, cost: 0.05}}}
      )

      assert get_assign(view, :tokens_input) == 1000
      assert get_assign(view, :tokens_output) == 500
      assert get_assign(view, :cost) == 0.05
    end

    test "accumulates usage across multiple events", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      send(
        view.pid,
        {:agent_event, {:usage, %{input: 1000, output: 500, cost: 0.05}}}
      )

      send(
        view.pid,
        {:agent_event, {:usage, %{input: 2000, output: 1000, cost: 0.10}}}
      )

      assert get_assign(view, :tokens_input) == 3000
      assert get_assign(view, :tokens_output) == 1500
      # Use approximate comparison for floating point
      assert_in_delta get_assign(view, :cost), 0.15, 0.001
    end
  end

  describe "tmux-style keybindings" do
    test "Ctrl+b followed by % toggles roster", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      initial_roster = get_assign(view, :roster_visible)

      # Press Ctrl+b
      view |> element(".chat-container") |> render_keydown(%{"key" => "b", "ctrlKey" => true})
      assert get_assign(view, :tmux_prefix) == true

      # Press %
      view |> element(".chat-container") |> render_keydown(%{"key" => "%"})
      assert get_assign(view, :roster_visible) == not initial_roster
      assert get_assign(view, :tmux_prefix) == false
    end

    test "Ctrl+b followed by z toggles zoom", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      # Press Ctrl+b
      view |> element(".chat-container") |> render_keydown(%{"key" => "b", "ctrlKey" => true})

      # Press z
      view |> element(".chat-container") |> render_keydown(%{"key" => "z"})
      assert get_assign(view, :zoom) == true
      assert get_assign(view, :tmux_prefix) == false
    end
  end

  describe "state changes" do
    test "updates agent state on state_change event", %{conn: conn, session_id: session_id} do
      {:ok, view, _html} = live(conn, "/?session=#{session_id}")

      assert get_assign(view, :agent_state) == :idle

      send(view.pid, {:agent_event, {:state_change, :executing}})
      assert get_assign(view, :agent_state) == :executing
    end
  end

  describe "HTML structure" do
    test "textarea has correct class and hook", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ ~r/class="chat-input"/
      assert html =~ ~r/phx-hook="TextareaInput"/
    end

    test "textarea is wrapped in form with phx-submit", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ ~r/<form[^>]*phx-submit="submit"[^>]*>/
      assert html =~ ~r/<form[^>]*>.*?<textarea[^>]*class="chat-input"/s
    end

    test "conversation area has ScrollControl hook", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ ~r/class="conversation-area"[^>]*phx-hook="ScrollControl"/
    end

    test "input area has mode-indicator element", %{conn: conn, session_id: session_id} do
      {:ok, _view, html} = live(conn, "/?session=#{session_id}")

      assert html =~ ~r/class="vim-mode-indicator/
    end
  end
end
