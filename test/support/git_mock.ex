defmodule Deft.GitMock do
  @moduledoc """
  Test implementation of Deft.Git behaviour for testing worktree detection.

  Configure responses using application config:

      # Simulate being in a worktree
      Application.put_env(:deft, :git_mock_response, {"/path/to/.git/worktrees/lead-123", 0})

      # Simulate not being in a git repo
      Application.put_env(:deft, :git_mock_response, {"fatal: not a git repository", 128})

      # Configure command-specific responses (map of args list to response tuple)
      Application.put_env(:deft, :git_mock_responses, %{
        ["worktree", "remove", "--force", "/path/to/worktree"] => {"", 0}
      })
  """

  @behaviour Deft.Git

  @impl true
  def cmd(args) do
    # First try command-specific responses
    case Application.get_env(:deft, :git_mock_responses) do
      responses when is_map(responses) ->
        Map.get(responses, args, get_default_response())

      nil ->
        get_default_response()
    end
  end

  defp get_default_response do
    case Application.get_env(:deft, :git_mock_response) do
      nil -> {"fatal: not a git repository\n", 128}
      response -> response
    end
  end
end
