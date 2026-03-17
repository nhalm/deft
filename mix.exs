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
      aliases: aliases(),
      escript: escript(),
      releases: releases()
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
      # HTTP client
      {:req, "~> 0.5"},
      # JSON
      {:jason, "~> 1.4"},
      # Config parsing
      {:yaml_elixir, "~> 2.11"},
      # SSE parsing
      {:server_sent_events, "~> 0.2"},
      # TUI framework (pulls in back_breeze, termite)
      {:breeze, "~> 0.2"},
      # Single-binary distribution
      {:burrito, "~> 1.0"},

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
    []
  end

  defp escript do
    [
      main_module: Deft.CLI
    ]
  end

  defp releases do
    [
      deft: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
