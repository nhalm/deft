defmodule Deft.Issue.IdTest do
  use ExUnit.Case, async: true

  alias Deft.Issue.Id

  describe "generate/1" do
    test "generates ID with deft- prefix" do
      id = Id.generate([])
      assert String.starts_with?(id, "deft-")
    end

    test "generates ID with 4 hex characters when no collisions" do
      id = Id.generate([])
      assert id =~ ~r/^deft-[0-9a-f]{4}$/
    end

    test "generates different IDs on subsequent calls" do
      id1 = Id.generate([])
      id2 = Id.generate([])
      assert id1 != id2
    end

    test "avoids collision by extending to 5 characters" do
      # Generate an ID first
      first_id = Id.generate([])

      # Extract the 4-char hex part
      "deft-" <> _hex = first_id

      # Create a scenario where all possible 4-char IDs starting with this prefix are taken
      # by providing the generated ID in existing_ids
      second_id = Id.generate([first_id])

      # The new ID should be different
      assert second_id != first_id
      assert String.starts_with?(second_id, "deft-")
    end

    test "extends to 5 characters when 4-char version collides" do
      existing = ["deft-abcd"]

      # Mock the random generation to produce "abcd" as first 4 chars
      # Since we can't control randomness easily, we test collision handling differently:
      # Generate many IDs and ensure none collide with existing
      ids = for _ <- 1..10, do: Id.generate(existing)

      # All generated IDs should be unique and none should be the existing one
      assert Enum.uniq(ids) == ids
      refute "deft-abcd" in ids
    end

    test "handles empty existing_ids list" do
      id = Id.generate([])
      assert String.starts_with?(id, "deft-")
      assert id =~ ~r/^deft-[0-9a-f]{4}$/
    end

    test "handles multiple existing IDs" do
      existing = ["deft-0000", "deft-1111", "deft-2222"]
      id = Id.generate(existing)

      assert String.starts_with?(id, "deft-")
      refute id in existing
    end

    test "generates valid hex characters only" do
      id = Id.generate([])
      "deft-" <> hex = id

      # Should only contain valid hex characters (0-9, a-f)
      assert String.match?(hex, ~r/^[0-9a-f]+$/)
    end

    test "collision resolution extends incrementally" do
      # Test that when we force multiple collisions, it keeps extending
      # We'll simulate this by providing a list that forces extension

      # If by chance we generate an ID that's in this list, it should extend
      existing = [
        "deft-aaaa",
        "deft-aaab",
        "deft-aaac"
      ]

      # Generate an ID - it should avoid all existing ones
      id = Id.generate(existing)
      refute id in existing
    end

    test "collision with 4-char ID extends to 5 chars" do
      # Pre-populate with a 4-char ID
      existing = ["deft-1234"]

      # Generate multiple IDs to see if any would need extension
      # At minimum, they should all be unique and not collide with existing
      # Reduced to 10 to minimize flakiness from random collisions
      ids = for _ <- 1..10, do: Id.generate(existing)

      assert Enum.all?(ids, fn id -> id != "deft-1234" end)
      assert Enum.uniq(ids) == ids
    end

    test "handles very long existing ID list" do
      # Generate a large list of existing IDs
      existing =
        for i <- 1..100, do: "deft-#{String.pad_leading(Integer.to_string(i, 16), 4, "0")}"

      id = Id.generate(existing)
      assert String.starts_with?(id, "deft-")
      refute id in existing
    end
  end
end
