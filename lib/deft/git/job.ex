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
end
