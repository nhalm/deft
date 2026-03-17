defmodule Deft.GitMock do
  @moduledoc """
  Test implementation of Deft.Git behaviour for testing worktree detection.

  Configure responses using application config:

      # Simulate being in a worktree
      Application.put_env(:deft, :git_mock_response, {"/path/to/.git/worktrees/lead-123", 0})

      # Simulate not being in a git repo
      Application.put_env(:deft, :git_mock_response, {"fatal: not a git repository", 128})
  """

  @behaviour Deft.Git

  @impl true
  def cmd(_args) do
    case Application.get_env(:deft, :git_mock_response) do
      nil -> {"fatal: not a git repository\n", 128}
      response -> response
    end
  end
end
