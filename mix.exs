defmodule Deft.MixProject do
  use Mix.Project

  def project do
    [
      app: :deft,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Deft.Application, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime
      {:req, "~> 0.5"},                    # HTTP client
      {:jason, "~> 1.4"},                  # JSON
      {:yaml_elixir, "~> 2.11"},           # Config parsing
      {:server_sent_events, "~> 0.2"},     # SSE parsing
      {:breeze, "~> 0.2"},                 # TUI framework (pulls in back_breeze, termite)
      {:burrito, "~> 1.0"},                # Single-binary distribution

      # Dev/Test only
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:stream_data, "~> 1.0", only: [:test]},
      {:mox, "~> 1.1", only: [:test]},
      {:tribunal, "~> 1.3", only: [:test]},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      test: "test --exclude eval --exclude integration"
    ]
  end
end
