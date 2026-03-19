defmodule Deft.Project do
  @moduledoc """
  Project directory layout management.

  Deft stores project-scoped data under `~/.deft/projects/<path-encoded-repo>/`.
  This module handles path encoding, git worktree resolution, and directory creation.

  ## Directory Layout

      ~/.deft/
        projects/
          <path-encoded-repo>/
            sessions/          # Session conversation logs
            cache/             # Session-scoped tool result caches
            jobs/              # Job-scoped orchestration data

  Project directories use path-encoded names (replace `/` with `-`, strip leading `-`).
  """

  @deft_root Path.expand("~/.deft")
  @projects_root Path.join(@deft_root, "projects")

  @doc """
  Returns the project directory for the given working directory.

  Resolves symlinks to real paths, detects git worktrees, and encodes the path.

  ## Examples

      iex> path = Deft.Project.project_dir("/Users/alice/code/myapp")
      iex> String.ends_with?(path, "projects/Users-alice-code-myapp")
      true

      iex> path = Deft.Project.project_dir()
      iex> String.contains?(path, "/.deft/projects/")
      true
  """
  @spec project_dir(String.t()) :: String.t()
  def project_dir(working_dir \\ File.cwd!()) do
    working_dir
    |> resolve_real_path()
    |> resolve_git_root()
    |> encode_path()
    |> build_project_path()
  end

  @doc """
  Ensures the project directory structure exists for the given working directory.

  Creates:
  - ~/.deft/projects/<path-encoded-repo>/
  - ~/.deft/projects/<path-encoded-repo>/sessions/
  - ~/.deft/projects/<path-encoded-repo>/cache/
  - ~/.deft/projects/<path-encoded-repo>/jobs/

  ## Examples

      iex> Deft.Project.ensure_project_dirs("/Users/alice/code/myapp")
      :ok
  """
  @spec ensure_project_dirs(String.t()) :: :ok | {:error, term()}
  def ensure_project_dirs(working_dir \\ File.cwd!()) do
    project_path = project_dir(working_dir)

    with :ok <- File.mkdir_p(project_path),
         :ok <- File.mkdir_p(Path.join(project_path, "sessions")),
         :ok <- File.mkdir_p(Path.join(project_path, "cache")),
         :ok <- File.mkdir_p(Path.join(project_path, "jobs")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the sessions directory for the given working directory.

  ## Examples

      iex> path = Deft.Project.sessions_dir("/Users/alice/code/myapp")
      iex> String.ends_with?(path, "projects/Users-alice-code-myapp/sessions")
      true
  """
  @spec sessions_dir(String.t()) :: String.t()
  def sessions_dir(working_dir \\ File.cwd!()) do
    working_dir
    |> project_dir()
    |> Path.join("sessions")
  end

  @doc """
  Returns the cache directory for the given working directory.

  ## Examples

      iex> path = Deft.Project.cache_dir("/Users/alice/code/myapp")
      iex> String.ends_with?(path, "projects/Users-alice-code-myapp/cache")
      true
  """
  @spec cache_dir(String.t()) :: String.t()
  def cache_dir(working_dir \\ File.cwd!()) do
    working_dir
    |> project_dir()
    |> Path.join("cache")
  end

  @doc """
  Returns the jobs directory for the given working directory.

  ## Examples

      iex> path = Deft.Project.jobs_dir("/Users/alice/code/myapp")
      iex> String.ends_with?(path, "projects/Users-alice-code-myapp/jobs")
      true
  """
  @spec jobs_dir(String.t()) :: String.t()
  def jobs_dir(working_dir \\ File.cwd!()) do
    working_dir
    |> project_dir()
    |> Path.join("jobs")
  end

  # Private functions

  # Resolve symlinks to real path
  defp resolve_real_path(path) do
    abs_path = Path.expand(path)

    case System.cmd("realpath", [abs_path], stderr_to_stdout: true) do
      {real_path, 0} -> String.trim(real_path)
      _ -> abs_path
    end
  end

  # Resolve to git repository root if inside a git repo
  defp resolve_git_root(path) do
    case System.cmd("git", ["rev-parse", "--git-common-dir"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> then(&Path.expand(&1, path))
        |> Path.dirname()

      {_output, _exit_code} ->
        # Not a git repo, use the path as-is
        path
    end
  end

  # Encode path: replace / with -, strip leading -
  defp encode_path(path) do
    path
    |> String.replace("/", "-")
    |> String.trim_leading("-")
  end

  # Build the full project path
  defp build_project_path(encoded_path) do
    Path.join(@projects_root, encoded_path)
  end
end
