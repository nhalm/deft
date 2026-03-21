defmodule PhoenixMinimalWeb.UserController do
  use PhoenixMinimalWeb, :controller

  alias PhoenixMinimal.Accounts.User
  alias PhoenixMinimal.Repo

  def index(conn, _params) do
    users = Repo.all(User)
    json(conn, %{data: users})
  end

  def show(conn, %{"id" => id}) do
    user = Repo.get!(User, id)
    json(conn, %{data: user})
  end

  def create(conn, %{"user" => user_params}) do
    changeset = User.changeset(%User{}, user_params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        conn
        |> put_status(:created)
        |> json(%{data: user})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset})
    end
  end
end
