defmodule Mix.Tasks.Deft do
  @moduledoc """
  Mix task wrapper for Deft CLI commands.

  Ensures the Deft OTP application is started, then dispatches to Deft.CLI.main/1.

  ## Usage

      mix deft                          # Start web UI
      mix deft work                     # Run highest-priority issue
      mix deft work --loop              # Keep running issues
      mix deft -p "prompt"              # Non-interactive mode
      mix deft issue list               # List issues
      mix deft issue create <title>     # Create issue

  All subcommands and flags are passed through to Deft.CLI.main/1.
  """

  @shortdoc "Run Deft CLI commands"

  use Mix.Task

  alias Deft.CLI

  @impl Mix.Task
  def run(args) do
    # Ensure the OTP application and all dependencies are started
    {:ok, _} = Application.ensure_all_started(:deft)

    # Delegate to the CLI dispatcher
    CLI.main(args)
  end
end
