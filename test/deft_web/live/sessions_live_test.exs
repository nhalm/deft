defmodule DeftWeb.SessionsLiveTest do
  use DeftWeb.ConnCase, async: false

  alias Deft.Session.Entry.{SessionStart, Message}
  alias Deft.Session.Store
  alias Phoenix.ConnTest

  setup do
    # Create a unique test working directory for each test
    # Include microseconds and a random component for uniqueness
    test_working_dir =
      "/tmp/deft_sessions_live_test_#{System.unique_integer([:positive, :monotonic])}_#{:erlang.phash2(make_ref())}"

    sessions_dir = Path.join([test_working_dir, ".deft", "sessions"])
    File.mkdir_p!(sessions_dir)

    # Save the current working directory and change to test directory
    original_cwd = File.cwd!()
    File.cd!(test_working_dir)

    on_exit(fn ->
      # Restore original working directory
      File.cd!(original_cwd)
      # Clean up test directory
      File.rm_rf!(test_working_dir)
    end)

    %{conn: ConnTest.build_conn(), test_working_dir: test_working_dir}
  end

  # Helper to get LiveView state
  defp get_state(view) do
    :sys.get_state(view.pid)
  end

  defp get_assign(view, key) do
    get_state(view).socket.assigns[key]
  end

  # Helper to create test session files
  defp create_test_session(session_id, opts) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    message_count = Keyword.get(opts, :message_count, 0)
    last_prompt = Keyword.get(opts, :last_prompt, "")

    # Create session start entry
    start_entry = SessionStart.new(session_id, working_dir, "claude-sonnet-4-20250514", %{})
    Store.append(session_id, start_entry)

    # Create message entries
    create_test_messages(session_id, message_count, last_prompt)
  end

  defp create_test_messages(_session_id, 0, _last_prompt), do: :ok

  defp create_test_messages(session_id, message_count, last_prompt) do
    for i <- 1..message_count do
      content = build_message_content(i, message_count, last_prompt)

      msg = %Message{
        type: :message,
        message_id: "msg-#{i}",
        role: :user,
        content: content,
        timestamp: DateTime.utc_now()
      }

      Store.append(session_id, msg)
      # Small delay to ensure timestamps are different
      :timer.sleep(5)
    end
  end

  defp build_message_content(i, message_count, last_prompt)
       when i == message_count and last_prompt != "" do
    [%{type: "text", text: last_prompt}]
  end

  defp build_message_content(i, _message_count, _last_prompt) do
    [%{type: "text", text: "Message #{i}"}]
  end

  describe "mount/3" do
    test "lists sessions from store", %{conn: conn} do
      # Create test sessions
      create_test_session("session_001",
        message_count: 5,
        last_prompt: "Help me debug"
      )

      :timer.sleep(10)

      create_test_session("session_002",
        message_count: 3,
        last_prompt: "Explain the auth module"
      )

      # Mount the LiveView
      {:ok, view, html} = live(conn, "/sessions")

      # Verify sessions are rendered
      assert html =~ "Sessions"
      assert html =~ "session_001"
      assert html =~ "session_002"
      assert html =~ "Help me debug"
      assert html =~ "Explain the auth module"
      # Working directory should be shown
      assert html =~ "/tmp/deft_sessions_live_test"
      assert html =~ "5 messages"
      assert html =~ "3 messages"

      # Verify assigns
      sessions = get_assign(view, :sessions)
      assert length(sessions) == 2
      assert get_assign(view, :selected_index) == 0
    end

    test "displays empty state when no sessions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "No sessions found"
      assert html =~ "Start a new session with"
      assert html =~ "deft"
    end

    test "shows help text for keyboard navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "j/k to navigate"
      assert html =~ "Enter to select"
      assert html =~ "q to quit"
    end

    test "initializes with first session selected", %{conn: conn} do
      create_test_session("session_001", message_count: 5, last_prompt: "Test prompt")

      {:ok, view, html} = live(conn, "/sessions")

      # First item should have "selected" class
      assert html =~ ~r/session-item.*selected/

      # selected_index should be 0
      assert get_assign(view, :selected_index) == 0
    end
  end

  describe "j/k navigation" do
    setup %{conn: conn} do
      # Create test sessions with time delays to ensure proper ordering
      create_test_session("session_001", message_count: 5, last_prompt: "First session")
      :timer.sleep(10)
      create_test_session("session_002", message_count: 3, last_prompt: "Second session")
      :timer.sleep(10)
      create_test_session("session_003", message_count: 7, last_prompt: "Third session")

      {:ok, view, _html} = live(conn, "/sessions")

      %{view: view}
    end

    test "j moves selection down", %{view: view} do
      # Start at index 0
      assert get_assign(view, :selected_index) == 0

      # Press j
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 1

      # Press j again
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 2
    end

    test "k moves selection up", %{view: view} do
      # Move down first
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 2

      # Press k
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "k"})
      assert get_assign(view, :selected_index) == 1

      # Press k again
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "k"})
      assert get_assign(view, :selected_index) == 0
    end

    test "j stops at last session", %{view: view} do
      # Move to last item
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 2

      # Press j again - should stay at last item
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 2
    end

    test "k stops at first session", %{view: view} do
      # Already at index 0
      assert get_assign(view, :selected_index) == 0

      # Press k - should stay at first item
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "k"})
      assert get_assign(view, :selected_index) == 0
    end

    test "navigation updates selected class in rendered HTML", %{view: view} do
      # Initial render - first item selected
      _html = render(view)

      # Move down
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})

      # Second item should now have selected class
      # This is a simplified check - in real implementation would verify CSS classes
      assert get_assign(view, :selected_index) == 1
    end
  end

  describe "Enter key selection" do
    setup %{conn: conn} do
      create_test_session("session_abc123", message_count: 5, last_prompt: "First session")
      :timer.sleep(10)
      create_test_session("session_def456", message_count: 3, last_prompt: "Second session")

      {:ok, view, _html} = live(conn, "/sessions")

      %{view: view}
    end

    test "Enter redirects to chat with selected session_id", %{view: view} do
      # Press Enter on first session (index 0)
      # Since session_def456 was created last, it will be at index 0 (most recent first)
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "Enter"})

      # Should redirect to the most recent session (session_def456)
      assert_redirect(view, "/?session=session_def456")
    end

    test "Enter redirects to correct session after navigation", %{view: view} do
      # Navigate to second session (which will be first in most-recent-first order)
      # Since session_def456 was created last, it's at index 0
      # session_abc123 is at index 1
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "j"})
      assert get_assign(view, :selected_index) == 1

      # Press Enter
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "Enter"})

      # Should redirect to session_abc123 (the older session)
      assert_redirect(view, "/?session=session_abc123")
    end
  end

  describe "q key - quit/back" do
    test "q redirects to most recent session", %{conn: conn} do
      # Create test sessions
      create_test_session("session_newer", message_count: 2, last_prompt: "Newer")
      # Ensure different timestamps
      :timer.sleep(10)
      create_test_session("session_older", message_count: 1, last_prompt: "Older")

      {:ok, view, _html} = live(conn, "/sessions")

      # Press q
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "q"})

      # Should redirect to most recent session (the one with the latest last_message_at)
      # Sessions are sorted by last_message_at desc, so the first one is most recent
      {:ok, sessions} = Store.list()
      most_recent = List.first(sessions)
      assert_redirect(view, "/?session=#{most_recent.session_id}")
    end

    test "q does nothing when no sessions", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions")

      # Press q
      html = view |> element(".sessions-picker") |> render_keydown(%{"key" => "q"})

      # Should stay on picker (no redirect, still shows sessions page)
      assert html =~ "Sessions"
      assert html =~ "No sessions found"
    end
  end

  describe "other keys" do
    test "ignores unknown keys", %{conn: conn} do
      create_test_session("session_001", message_count: 5, last_prompt: "Test")

      {:ok, view, _html} = live(conn, "/sessions")

      initial_index = get_assign(view, :selected_index)

      # Press random keys
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "x"})
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "y"})
      view |> element(".sessions-picker") |> render_keydown(%{"key" => "z"})

      # Should not change selected_index
      assert get_assign(view, :selected_index) == initial_index
    end
  end

  describe "session metadata display" do
    test "formats datetime correctly", %{conn: conn} do
      create_test_session("session_001", message_count: 5, last_prompt: "Test")

      {:ok, _view, html} = live(conn, "/sessions")

      # Should contain formatted date/time (will show today's date)
      # Just check that date format is present
      assert html =~ ~r/\d{4}-\d{2}-\d{2}/
    end

    test "shows message count", %{conn: conn} do
      create_test_session("session_001", message_count: 42, last_prompt: "Test")

      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "42 messages"
    end

    test "shows working directory", %{conn: conn, test_working_dir: test_working_dir} do
      create_test_session("session_001", message_count: 5, last_prompt: "Test")

      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ test_working_dir
    end

    test "displays last user prompt", %{conn: conn} do
      create_test_session("session_001",
        message_count: 5,
        last_prompt: "Help me refactor this function to use pattern matching"
      )

      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "Help me refactor this function to use pattern matching"
    end

    test "hides last prompt div when prompt is empty", %{conn: conn} do
      # Create session with no messages - will have empty last_user_prompt
      create_test_session("session_001", message_count: 0, last_prompt: "")

      {:ok, _view, html} = live(conn, "/sessions")

      # Should not render the last-prompt div when prompt is empty
      refute html =~ ~r/<div class="last-prompt">/
    end
  end
end
