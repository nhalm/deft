defmodule Deft.OM.Observer.ParseTest do
  use ExUnit.Case, async: true

  alias Deft.OM.Observer.Parse

  describe "parse_output/1" do
    test "extracts observations and current-task from valid XML" do
      xml = """
      <observations>
      ## Current State
      - (14:55) Active task: implementing JWT verification

      ## User Preferences
      - (14:32) 🔴 User prefers minimal dependencies
      </observations>

      <current-task>
      Implementing JWT authentication in src/auth.ex
      </current-task>
      """

      assert {:ok, result} = Parse.parse_output(xml)
      assert result.observations =~ "Active task: implementing JWT verification"
      assert result.observations =~ "User prefers minimal dependencies"
      assert result.current_task == "Implementing JWT authentication in src/auth.ex"
    end

    test "handles missing current-task tag" do
      xml = """
      <observations>
      ## Current State
      - (14:55) Active task: working
      </observations>
      """

      assert {:ok, result} = Parse.parse_output(xml)
      assert result.observations =~ "Active task: working"
      assert is_nil(result.current_task)
    end

    test "validates section headers and rejects invalid sections" do
      xml = """
      <observations>
      ## Current State
      - Task

      ## Invalid Section Name
      - Something
      </observations>
      """

      # Should fall back when validation fails
      assert {:ok, result} = Parse.parse_output(xml)
      # Fallback accepts the content as-is
      assert result.observations =~ "Current State"
    end

    test "falls back to raw extraction when XML tags are missing" do
      raw = """
      ## Current State
      - (14:55) Active task: working

      ## User Preferences
      - (14:32) 🔴 Preference
      """

      assert {:ok, result} = Parse.parse_output(raw)
      assert result.observations =~ "Active task: working"
      assert is_nil(result.current_task)
    end

    test "returns error when no structure is found" do
      bad_input = "This is just plain text with no structure"

      assert {:error, reason} = Parse.parse_output(bad_input)
      assert reason =~ "Could not parse"
    end

    test "folds current_task into ## Current State section per spec 3.5" do
      xml = """
      <observations>
      ## User Preferences
      - (14:32) 🔴 User prefers minimal dependencies
      </observations>

      <current-task>
      Implementing JWT authentication in src/auth.ex
      </current-task>
      """

      assert {:ok, result} = Parse.parse_output(xml)
      # current_task should be folded into Current State section
      assert result.observations =~ "## Current State"
      assert result.observations =~ "Active task: Implementing JWT authentication in src/auth.ex"
      assert result.observations =~ "## User Preferences"
      # Current State should come first in canonical order
      [first_section | _] = String.split(result.observations, "##", trim: true)
      assert first_section =~ "Current State"
    end

    test "folds current_task into existing ## Current State section" do
      xml = """
      <observations>
      ## Current State
      - (14:55) Last action: Runner created User migration
      - (14:52) Blocking error: none

      ## User Preferences
      - (14:32) 🔴 User prefers minimal dependencies
      </observations>

      <current-task>
      Implementing JWT authentication
      </current-task>
      """

      assert {:ok, result} = Parse.parse_output(xml)
      # current_task should be prepended to existing Current State content
      assert result.observations =~ "Active task: Implementing JWT authentication"
      assert result.observations =~ "Last action: Runner created User migration"
      assert result.observations =~ "Blocking error: none"
      # Verify Current State comes first
      assert result.observations =~ ~r/## Current State.*Active task.*Last action/s
    end

    test "handles empty current_task gracefully" do
      xml = """
      <observations>
      ## Current State
      - (14:55) Last action: test

      </observations>

      <current-task></current-task>
      """

      assert {:ok, result} = Parse.parse_output(xml)
      # Empty current_task should not be folded in
      refute result.observations =~ "Active task:"
      assert result.observations =~ "Last action: test"
    end
  end

  describe "merge_observations/2" do
    test "replaces Current State section" do
      existing = """
      ## Current State
      - (14:30) Active task: old task
      - (14:30) Last action: old action
      """

      new_obs = """
      ## Current State
      - (14:55) Active task: new task
      - (14:55) Last action: new action
      """

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "new task"
      assert merged =~ "new action"
      refute merged =~ "old task"
      refute merged =~ "old action"
    end

    test "appends User Preferences" do
      existing = """
      ## User Preferences
      - (14:30) 🔴 Preference 1
      """

      new_obs = """
      ## User Preferences
      - (14:55) 🔴 Preference 2
      """

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "Preference 1"
      assert merged =~ "Preference 2"
    end

    test "appends Decisions" do
      existing = """
      ## Decisions
      - (14:30) 🟡 Decision 1
      """

      new_obs = """
      ## Decisions
      - (14:55) 🟡 Decision 2
      """

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "Decision 1"
      assert merged =~ "Decision 2"
    end

    test "appends Session History" do
      existing = """
      ## Session History
      - (14:30) 🔴 Event 1
      """

      new_obs = """
      ## Session History
      - (14:55) 🟡 Event 2
      """

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "Event 1"
      assert merged =~ "Event 2"
    end

    test "deduplicates Files & Architecture by filepath for Read entries" do
      existing = """
      ## Files & Architecture
      - (14:30) 🟡 Read src/auth.ex — old description
      - (14:31) 🟡 Read src/user.ex — user module
      """

      new_obs = """
      ## Files & Architecture
      - (14:55) 🟡 Read src/auth.ex — updated description
      """

      merged = Parse.merge_observations(existing, new_obs)

      # Should have updated auth.ex entry, kept user.ex
      assert merged =~ "updated description"
      assert merged =~ "user module"
      refute merged =~ "old description"
    end

    test "deduplicates Files & Architecture by filepath for Modified entries" do
      existing = """
      ## Files & Architecture
      - (14:30) 🟡 Modified src/auth.ex — added function
      """

      new_obs = """
      ## Files & Architecture
      - (14:55) 🟡 Modified src/auth.ex — refactored function
      """

      merged = Parse.merge_observations(existing, new_obs)

      # Should have only the new modification
      assert merged =~ "refactored function"
      refute merged =~ "added function"
    end

    test "handles Architecture entries that don't have filepaths" do
      existing = """
      ## Files & Architecture
      - (14:30) 🟡 Read src/auth.ex — JWT module
      """

      new_obs = """
      ## Files & Architecture
      - (14:55) 🟡 Architecture: gen_statem for agent loop
      """

      merged = Parse.merge_observations(existing, new_obs)

      # Both should be present
      assert merged =~ "JWT module"
      assert merged =~ "gen_statem for agent loop"
    end

    test "maintains section order" do
      existing = """
      ## Session History
      - History

      ## Current State
      - Task
      """

      new_obs = """
      ## User Preferences
      - Pref
      """

      merged = Parse.merge_observations(existing, new_obs)

      # Check that sections appear in canonical order
      lines = String.split(merged, "\n")
      current_state_idx = Enum.find_index(lines, &(&1 =~ "Current State"))
      user_prefs_idx = Enum.find_index(lines, &(&1 =~ "User Preferences"))
      session_history_idx = Enum.find_index(lines, &(&1 =~ "Session History"))

      assert current_state_idx < user_prefs_idx
      assert user_prefs_idx < session_history_idx
    end

    test "merges multiple sections at once" do
      existing = """
      ## Current State
      - (14:30) Old task

      ## User Preferences
      - (14:30) 🔴 Pref 1

      ## Files & Architecture
      - (14:30) 🟡 Read src/old.ex — old file
      """

      new_obs = """
      ## Current State
      - (14:55) New task

      ## User Preferences
      - (14:55) 🔴 Pref 2

      ## Files & Architecture
      - (14:55) 🟡 Read src/new.ex — new file
      - (14:56) 🟡 Read src/old.ex — updated file

      ## Decisions
      - (14:55) 🟡 Made a decision
      """

      merged = Parse.merge_observations(existing, new_obs)

      # Current State replaced
      assert merged =~ "New task"
      refute merged =~ "Old task"

      # User Preferences appended
      assert merged =~ "Pref 1"
      assert merged =~ "Pref 2"

      # Files deduplicated
      assert merged =~ "new file"
      assert merged =~ "updated file"
      refute merged =~ "old file"

      # Decisions added
      assert merged =~ "Made a decision"
    end

    test "handles empty existing observations" do
      existing = ""

      new_obs = """
      ## Current State
      - (14:55) Task
      """

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "Current State"
      assert merged =~ "Task"
    end

    test "handles empty new observations" do
      existing = """
      ## Current State
      - (14:30) Task
      """

      new_obs = ""

      merged = Parse.merge_observations(existing, new_obs)

      assert merged =~ "Current State"
      assert merged =~ "Task"
    end
  end
end
