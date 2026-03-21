defmodule PhoenixMinimal.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:email, :string)
    field(:name, :string)
    field(:password_hash, :string)

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password_hash])
    |> validate_required([:email, :name])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end
