defmodule Deft.Issue.Id do
  @moduledoc """
  ID generation for Deft issues.

  Generates short, hash-based IDs in the format `deft-<hex>` where `<hex>` is
  4 hex characters derived from random bytes. On collision, extends to 5, 6,
  or more characters until a unique ID is found.
  """

  @doc """
  Generates a unique issue ID.

  Accepts a list of existing IDs and ensures the generated ID doesn't collide.
  On collision, extends the hex portion from 4 to 5+ characters until unique.

  ## Examples

      iex> Deft.Issue.Id.generate([])
      "deft-" <> _hex

      iex> id = Deft.Issue.Id.generate(["deft-a1b2"])
      iex> id != "deft-a1b2"
      true

  ## Parameters

    - `existing_ids` - List of existing issue IDs to check for collisions

  ## Returns

  A string in the format `deft-<hex>` where `<hex>` is 4+ hex characters.
  """
  @spec generate([Deft.Issue.id()]) :: Deft.Issue.id()
  def generate(existing_ids) when is_list(existing_ids) do
    # Generate random bytes and convert to hex
    hex_source =
      :crypto.strong_rand_bytes(16)
      |> Base.encode16(case: :lower)

    # Start with 4 characters and extend if there's a collision
    find_unique_id(hex_source, existing_ids, 4)
  end

  # Recursively try increasing lengths until we find a unique ID
  defp find_unique_id(hex_source, existing_ids, length) do
    candidate_hex = String.slice(hex_source, 0, length)
    candidate_id = "deft-#{candidate_hex}"

    if candidate_id in existing_ids do
      # Collision detected, try with one more character
      find_unique_id(hex_source, existing_ids, length + 1)
    else
      candidate_id
    end
  end
end
