defmodule Deft.Git do
  @moduledoc """
  Behaviour for Git operations, allowing for testability through dependency injection.

  This behaviour abstracts git command execution, making it possible to mock
  git operations in tests without requiring an actual git repository.
  """

  @doc """
  Executes a git command with the given arguments.

  Returns `{output, exit_code}` where output is the command's stdout/stderr
  and exit_code is the process exit code.

  ## Examples

      iex> Deft.Git.cmd(Deft.Git.System, ["rev-parse", "--git-common-dir"])
      {"/path/to/.git\\n", 0}

      iex> Deft.Git.cmd(Deft.Git.System, ["invalid-command"])
      {"error message\\n", 1}
  """
  @callback cmd(args :: [String.t()]) :: {String.t(), non_neg_integer()}

  @doc """
  Default implementation for the current git adapter.

  Returns the module to use for git operations. Defaults to Deft.Git.System.
  Can be overridden via application config:

      config :deft, :git_adapter, MyCustomGitAdapter
  """
  def adapter do
    Application.get_env(:deft, :git_adapter, Deft.Git.System)
  end

  @doc """
  Convenience function to execute a git command using the configured adapter.

  ## Examples

      iex> Deft.Git.cmd(["status"])
      {"On branch main\\n", 0}
  """
  def cmd(args) do
    adapter().cmd(args)
  end
end
