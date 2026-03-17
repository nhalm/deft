defmodule Deft.Git.System do
  @moduledoc """
  Default implementation of Deft.Git behaviour using System.cmd/3.

  This implementation executes actual git commands on the system.
  """

  @behaviour Deft.Git

  @impl true
  def cmd(args) do
    System.cmd("git", args, stderr_to_stdout: true)
  end
end
