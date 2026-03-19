defmodule Deft.Eval.Observer.SectionOrderingTest do
  use ExUnit.Case, async: false
  import Deft.EvalHelpers

  alias Deft.OM.Observer

  @moduletag :eval
  @moduletag :expensive

  describe "Observer section ordering (spec observational-memory.md, hard assertion)" do
    test "sections appear in canonical order" do
      config = test_config()

      # Create messages that will trigger all 5 sections
      tool_use_id = "toolu_123"
      tool_use = assistant_tool_use("read", %{"file_path" => "src/auth.ex"})
      tool_result = user_tool_result(tool_use_id, "read", "defmodule Auth do\nend", false)

      messages = [
        user_message("I'm implementing JWT authentication"),
        user_message("I prefer spaces over tabs"),
        tool_use,
        tool_result,
        user_message("Let's use argon2 for password hashing"),
        user_message("Please explain how auth works"),
        assistant_message("The auth module handles JWT verification")
      ]

      # Run Observer
      result = Observer.run(config, messages, "", 4.0)
      observations = result.observations

      # Check that sections appear in canonical order
      assert sections_in_order?(observations), """
      Sections must appear in canonical order:
      1. ## Current State
      2. ## User Preferences
      3. ## Files & Architecture
      4. ## Decisions
      5. ## Session History

      Got:
      #{observations}
      """
    end
  end

  @doc """
  Checks if sections appear in canonical order.

  Per spec observational-memory.md section 4:
  - ## Current State (always at top)
  - ## User Preferences
  - ## Files & Architecture
  - ## Decisions
  - ## Session History
  """
  def sections_in_order?(observations) do
    # Extract section headers with their positions
    section_positions =
      ~r/^## (.+)$/m
      |> Regex.scan(observations, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.map(fn {[name], idx} -> {String.trim(name), idx} end)
      |> Map.new()

    # Canonical order
    canonical_order = [
      "Current State",
      "User Preferences",
      "Files & Architecture",
      "Decisions",
      "Session History"
    ]

    # Check that any present sections appear in the correct order
    present_sections =
      canonical_order
      |> Enum.filter(fn section -> Map.has_key?(section_positions, section) end)

    # Get positions of present sections
    positions =
      present_sections
      |> Enum.map(fn section -> section_positions[section] end)

    # Positions should be strictly increasing
    positions == Enum.sort(positions)
  end
end
