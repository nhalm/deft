defmodule PhoenixMinimal.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_minimal,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {PhoenixMinimal.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"}
    ]
  end
end
