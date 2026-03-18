defmodule Deft.Git.Job do
  @moduledoc """
  Git operations for job lifecycle management.

  Handles job branch creation, worktree management, merge strategy,
  and cleanup for Deft orchestration jobs.

  ## Job Branch Lifecycle

  1. Job start: Create `deft/job-<job_id>` from current HEAD
  2. Lead execution: Each Lead gets a worktree branched from job branch
  3. Lead completion: Merge Lead branch into job branch
  4. Job completion: Squash-merge job branch into original branch

  See git-strategy spec for full details.
  """

  require Logger

  @doc """
  Creates a job branch from current HEAD.

  Verifies the working tree is clean before creating the branch.
  If uncommitted changes exist, prompts user to stash them.

  ## Options

  - `:job_id` - Required. Unique job identifier.
  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:auto_approve` - Optional. Skip user prompts (defaults to false).

  ## Returns

  - `{:ok, branch_name}` - Branch created successfully
  - `{:error, :dirty_working_tree}` - Working tree has uncommitted changes and user declined to stash
  - `{:error, reason}` - Git command failed

  ## Examples

      # Success with clean working tree
      Deft.Git.Job.create_job_branch(job_id: "abc123", auto_approve: true)
      # => {:ok, "deft/job-abc123"}

      # Error with dirty working tree
      Deft.Git.Job.create_job_branch(job_id: "abc123", auto_approve: true)
      # => {:error, :dirty_working_tree}
  """
  @spec create_job_branch(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_job_branch(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    git = Keyword.get(opts, :git, Deft.Git)
    auto_approve = Keyword.get(opts, :auto_approve, false)

    branch_name = "deft/job-#{job_id}"

    with :ok <- verify_clean_working_tree(git, auto_approve),
         :ok <- create_branch(git, branch_name) do
      Logger.info("Created job branch: #{branch_name}")
      {:ok, branch_name}
    end
  end

  # Verify working tree is clean, prompting user to stash if needed
  defp verify_clean_working_tree(git, auto_approve) do
    case git.cmd(["status", "--porcelain"]) do
      {"", 0} ->
        # Working tree is clean
        :ok

      {output, 0} when byte_size(output) > 0 ->
        # Working tree has uncommitted changes
        handle_dirty_working_tree(output, auto_approve)

      {error_output, exit_code} ->
        Logger.error("Failed to check git status: #{error_output}")
        {:error, {:git_status_failed, exit_code}}
    end
  end

  # Handle dirty working tree by prompting user or auto-failing
  defp handle_dirty_working_tree(status_output, auto_approve) do
    if auto_approve do
      # In auto-approve mode, we can't stash - fail immediately
      Logger.error("""
      Working tree has uncommitted changes (--auto-approve mode):

      #{status_output}

      Please commit or stash your changes before starting a job.
      """)

      {:error, :dirty_working_tree}
    else
      # Interactive mode - prompt user
      IO.puts("""
      Warning: Working tree has uncommitted changes:

      #{status_output}

      You should stash your changes before starting a job.
      This prevents conflicts with the job's work.
      """)

      IO.write("Stash changes and continue? [y/N]: ")

      response = IO.gets("")

      case response do
        :eof ->
          # Non-interactive environment (e.g., tests with no stdin)
          IO.puts("\nJob creation cancelled (no input available).\n")
          {:error, :dirty_working_tree}

        input when is_binary(input) ->
          case String.trim(input) |> String.downcase() do
            answer when answer in ["y", "yes"] ->
              # User agreed to stash - they need to do it manually
              IO.puts("\nPlease run: git stash")
              IO.puts("Then restart the job.\n")
              {:error, :dirty_working_tree}

            _ ->
              IO.puts("\nJob creation cancelled.\n")
              {:error, :dirty_working_tree}
          end
      end
    end
  end

  # Create the job branch from current HEAD
  defp create_branch(git, branch_name) do
    case git.cmd(["branch", branch_name]) do
      {_output, 0} ->
        :ok

      {error_output, exit_code} ->
        Logger.error("Failed to create branch #{branch_name}: #{error_output}")
        {:error, {:branch_creation_failed, exit_code}}
    end
  end

  @doc """
  Creates a worktree for a Lead.

  The worktree is branched from the job branch and contains all previously
  merged Lead work. Each Lead gets an isolated working directory to avoid
  file conflicts during parallel execution.

  ## Options

  - `:lead_id` - Required. Unique Lead identifier.
  - `:job_id` - Required. Job identifier (for job branch name).
  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).

  ## Returns

  - `{:ok, worktree_path}` - Worktree created successfully
  - `{:error, reason}` - Git command failed

  ## Examples

      # Success
      Deft.Git.Job.create_lead_worktree(lead_id: "lead-1", job_id: "abc123")
      # => {:ok, "/path/to/repo/.deft-worktrees/lead-lead-1"}

      # Error if job branch doesn't exist
      Deft.Git.Job.create_lead_worktree(lead_id: "lead-1", job_id: "invalid")
      # => {:error, {:worktree_creation_failed, 128}}
  """
  @spec create_lead_worktree(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_lead_worktree(opts) do
    lead_id = Keyword.fetch!(opts, :lead_id)
    job_id = Keyword.fetch!(opts, :job_id)
    git = Keyword.get(opts, :git, Deft.Git)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    job_branch = "deft/job-#{job_id}"
    lead_branch = "deft/lead-#{lead_id}"
    worktree_path = Path.join([working_dir, ".deft-worktrees", "lead-#{lead_id}"])

    # Ensure .deft-worktrees directory exists
    worktrees_dir = Path.join(working_dir, ".deft-worktrees")

    case File.mkdir_p(worktrees_dir) do
      :ok ->
        # Add .deft-worktrees/ to .gitignore if not already present
        ensure_gitignore_entry(working_dir, ".deft-worktrees/")
        create_worktree(git, worktree_path, lead_branch, job_branch)

      {:error, reason} ->
        Logger.error("Failed to create .deft-worktrees directory: #{inspect(reason)}")
        {:error, {:worktrees_dir_creation_failed, reason}}
    end
  end

  # Create a git worktree branched from the job branch
  defp create_worktree(git, worktree_path, lead_branch, job_branch) do
    # git worktree add <path> -b <lead_branch> <job_branch>
    case git.cmd(["worktree", "add", worktree_path, "-b", lead_branch, job_branch]) do
      {_output, 0} ->
        Logger.info("Created worktree at #{worktree_path} (branch: #{lead_branch})")
        {:ok, worktree_path}

      {error_output, exit_code} ->
        Logger.error("Failed to create worktree at #{worktree_path}: #{error_output}")

        {:error, {:worktree_creation_failed, exit_code}}
    end
  end

  # Ensure entry exists in .gitignore
  defp ensure_gitignore_entry(working_dir, entry) do
    gitignore_path = Path.join(working_dir, ".gitignore")
    content = read_gitignore(gitignore_path)
    normalized_entry = String.trim(entry)

    if gitignore_contains?(content, normalized_entry) do
      Logger.debug("#{entry} already in .gitignore")
    else
      write_gitignore_entry(gitignore_path, content, normalized_entry)
    end
  end

  defp read_gitignore(gitignore_path) do
    case File.read(gitignore_path) do
      {:ok, existing} ->
        existing

      {:error, :enoent} ->
        ""

      {:error, reason} ->
        Logger.warning("Failed to read .gitignore: #{inspect(reason)}")
        ""
    end
  end

  defp gitignore_contains?(content, entry) do
    content
    |> String.split("\n")
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)
      trimmed == entry or trimmed == "/" <> entry
    end)
  end

  defp write_gitignore_entry(gitignore_path, content, entry) do
    new_content =
      if String.ends_with?(content, "\n") or content == "" do
        content <> entry <> "\n"
      else
        content <> "\n" <> entry <> "\n"
      end

    case File.write(gitignore_path, new_content) do
      :ok ->
        Logger.info("Added #{entry} to .gitignore")

      {:error, reason} ->
        Logger.error("Failed to write .gitignore: #{inspect(reason)}")
    end
  end

  @doc """
  Scans for and cleans up orphaned git artifacts from crashed jobs.

  Orphans include:
  - `deft/job-*` branches with no running Deft job
  - `deft/lead-*` worktrees with no running Deft job

  ## Options

  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).
  - `:auto_approve` - Optional. Skip user prompts (defaults to false).

  ## Returns

  - `:ok` - Cleanup completed or user declined
  - `{:error, reason}` - Git command failed

  ## Examples

      # Interactive mode - prompts user
      Deft.Git.Job.cleanup_orphans()
      # => :ok

      # Non-interactive mode - auto-cleans
      Deft.Git.Job.cleanup_orphans(auto_approve: true)
      # => :ok
  """
  @spec cleanup_orphans(keyword()) :: :ok | {:error, term()}
  def cleanup_orphans(opts \\ []) do
    git = Keyword.get(opts, :git, Deft.Git)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    auto_approve = Keyword.get(opts, :auto_approve, false)

    with {:ok, orphaned_worktrees} <- find_orphaned_worktrees(git, working_dir),
         {:ok, orphaned_branches} <- find_orphaned_branches(git) do
      if Enum.empty?(orphaned_worktrees) and Enum.empty?(orphaned_branches) do
        Logger.debug("No orphaned artifacts found")
        :ok
      else
        perform_cleanup(git, orphaned_worktrees, orphaned_branches, auto_approve)
      end
    end
  end

  # Find orphaned deft/lead-* worktrees
  defp find_orphaned_worktrees(git, working_dir) do
    case git.cmd(["worktree", "list", "--porcelain"]) do
      {output, 0} ->
        worktrees = parse_worktree_list(output, working_dir)
        {:ok, worktrees}

      {error_output, exit_code} ->
        Logger.error("Failed to list worktrees: #{error_output}")
        {:error, {:worktree_list_failed, exit_code}}
    end
  end

  # Parse git worktree list --porcelain output
  defp parse_worktree_list(output, _working_dir) do
    output
    |> String.split("\n")
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&(&1 == [""]))
    |> Enum.map(&parse_worktree_entry/1)
    |> Enum.filter(fn
      %{branch: "deft/lead-" <> _} = worktree ->
        # Only include lead worktrees (not job worktrees, if any)
        # Check if worktree path is under .deft-worktrees
        String.contains?(worktree.path, ".deft-worktrees")

      _ ->
        false
    end)
  end

  # Parse a single worktree entry from --porcelain output
  defp parse_worktree_entry(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      cond do
        String.starts_with?(line, "worktree ") ->
          Map.put(acc, :path, String.trim_leading(line, "worktree "))

        String.starts_with?(line, "branch ") ->
          Map.put(acc, :branch, String.trim_leading(line, "branch refs/heads/"))

        true ->
          acc
      end
    end)
  end

  # Find orphaned deft/job-* and deft/lead-* branches
  defp find_orphaned_branches(git) do
    case git.cmd(["branch", "--list", "deft/*"]) do
      {output, 0} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.trim_leading(&1, "* "))
          |> Enum.filter(&String.starts_with?(&1, "deft/"))

        {:ok, branches}

      {error_output, exit_code} ->
        Logger.error("Failed to list branches: #{error_output}")
        {:error, {:branch_list_failed, exit_code}}
    end
  end

  # Perform cleanup after user confirmation (if needed)
  defp perform_cleanup(git, orphaned_worktrees, orphaned_branches, auto_approve) do
    if auto_approve or prompt_user_for_cleanup(orphaned_worktrees, orphaned_branches) do
      do_cleanup(git, orphaned_worktrees, orphaned_branches)
    else
      Logger.info("Orphan cleanup cancelled by user")
      :ok
    end
  end

  # Prompt user to confirm cleanup
  defp prompt_user_for_cleanup(orphaned_worktrees, orphaned_branches) do
    IO.puts("\nFound orphaned git artifacts from previous crashed jobs:\n")

    unless Enum.empty?(orphaned_worktrees) do
      IO.puts("Orphaned worktrees:")

      Enum.each(orphaned_worktrees, fn worktree ->
        IO.puts("  - #{worktree.branch} (#{worktree.path})")
      end)

      IO.puts("")
    end

    unless Enum.empty?(orphaned_branches) do
      IO.puts("Orphaned branches:")

      Enum.each(orphaned_branches, fn branch ->
        IO.puts("  - #{branch}")
      end)

      IO.puts("")
    end

    IO.write("Clean up these artifacts? [y/N]: ")

    case IO.gets("") do
      :eof ->
        false

      input when is_binary(input) ->
        answer = input |> String.trim() |> String.downcase()
        answer in ["y", "yes"]
    end
  end

  # Execute cleanup operations
  defp do_cleanup(git, orphaned_worktrees, orphaned_branches) do
    # Remove orphaned worktrees first
    Enum.each(orphaned_worktrees, fn worktree ->
      case git.cmd(["worktree", "remove", worktree.path, "--force"]) do
        {_output, 0} ->
          Logger.info("Removed orphaned worktree: #{worktree.branch}")

        {error_output, _exit_code} ->
          Logger.warning("Failed to remove worktree #{worktree.path}: #{error_output}")
      end
    end)

    # Delete orphaned branches
    Enum.each(orphaned_branches, fn branch ->
      case git.cmd(["branch", "-D", branch]) do
        {_output, 0} ->
          Logger.info("Deleted orphaned branch: #{branch}")

        {error_output, _exit_code} ->
          Logger.warning("Failed to delete branch #{branch}: #{error_output}")
      end
    end)

    # Prune stale worktree metadata
    case git.cmd(["worktree", "prune"]) do
      {_output, 0} ->
        Logger.info("Pruned stale worktree metadata")

      {error_output, _exit_code} ->
        Logger.warning("Failed to prune worktrees: #{error_output}")
    end

    :ok
  end
end
