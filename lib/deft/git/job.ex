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

  - `{:ok, job_branch_name, original_branch}` - Branch created successfully
  - `{:error, :dirty_working_tree}` - Working tree has uncommitted changes and user declined to stash
  - `{:error, reason}` - Git command failed

  ## Examples

      # Success with clean working tree
      Deft.Git.Job.create_job_branch(job_id: "abc123", auto_approve: true)
      # => {:ok, "deft/job-abc123", "main"}

      # Error with dirty working tree
      Deft.Git.Job.create_job_branch(job_id: "abc123", auto_approve: true)
      # => {:error, :dirty_working_tree}
  """
  @spec create_job_branch(keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def create_job_branch(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    git = Keyword.get(opts, :git, Deft.Git)
    auto_approve = Keyword.get(opts, :auto_approve, false)

    branch_name = "deft/job-#{job_id}"

    with {:ok, original_branch} <- get_current_branch(git),
         :ok <- verify_clean_working_tree(git, auto_approve, job_id),
         :ok <- create_branch(git, branch_name) do
      Logger.info("Created job branch: #{branch_name} from #{original_branch}")
      {:ok, branch_name, original_branch}
    end
  end

  # Get the name of the current branch
  defp get_current_branch(git) do
    case git.cmd(["rev-parse", "--abbrev-ref", "HEAD"]) do
      {branch_name, 0} ->
        {:ok, String.trim(branch_name)}

      {error_output, exit_code} ->
        Logger.error("Failed to get current branch: #{error_output}")
        {:error, {:get_branch_failed, exit_code}}
    end
  end

  # Verify working tree is clean, prompting user to stash if needed
  defp verify_clean_working_tree(git, auto_approve, job_id) do
    case git.cmd(["status", "--porcelain"]) do
      {"", 0} ->
        # Working tree is clean
        :ok

      {output, 0} when byte_size(output) > 0 ->
        # Working tree has uncommitted changes
        handle_dirty_working_tree(git, output, auto_approve, job_id)

      {error_output, exit_code} ->
        Logger.error("Failed to check git status: #{error_output}")
        {:error, {:git_status_failed, exit_code}}
    end
  end

  # Handle dirty working tree by prompting user or auto-failing
  defp handle_dirty_working_tree(git, status_output, auto_approve, job_id) do
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
      handle_stash_response(git, response, job_id)
    end
  end

  # Handle user response to stash prompt
  defp handle_stash_response(git, response, job_id) do
    case response do
      :eof ->
        # Non-interactive environment (e.g., tests with no stdin)
        IO.puts("\nJob creation cancelled (no input available).\n")
        {:error, :dirty_working_tree}

      input when is_binary(input) ->
        case String.trim(input) |> String.downcase() do
          answer when answer in ["y", "yes"] ->
            perform_stash(git, job_id)

          _ ->
            IO.puts("\nJob creation cancelled.\n")
            {:error, :dirty_working_tree}
        end
    end
  end

  # Perform the actual git stash operation with a message to identify it later
  defp perform_stash(git, job_id) do
    IO.puts("\nStashing changes...")
    stash_message = "Deft job creation: #{job_id}"

    case git.cmd(["stash", "push", "-m", stash_message]) do
      {output, 0} ->
        IO.puts(output)
        IO.puts("Changes stashed successfully. Continuing with job creation.\n")
        :ok

      {error_output, exit_code} ->
        Logger.error("Failed to stash changes: #{error_output}")
        IO.puts("\nFailed to stash changes. Please resolve manually and restart the job.\n")
        {:error, {:stash_failed, exit_code}}
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
  Merges a Lead branch into the job branch.

  When a Lead completes, the Foreman merges the Lead's branch back into the
  job branch in dependency order. Independent Leads are merged in completion order.

  ## Options

  - `:lead_id` - Required. Lead identifier.
  - `:job_id` - Required. Job identifier (for job branch name).
  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).

  ## Returns

  - `{:ok, :merged}` - Merge completed successfully
  - `{:ok, :conflict, conflicted_files}` - Merge has conflicts (list of file paths)
  - `{:error, reason}` - Git command failed

  ## Examples

      # Successful merge
      Deft.Git.Job.merge_lead_branch(lead_id: "lead-1", job_id: "abc123")
      # => {:ok, :merged}

      # Merge with conflicts
      Deft.Git.Job.merge_lead_branch(lead_id: "lead-1", job_id: "abc123")
      # => {:ok, :conflict, ["lib/app.ex", "test/app_test.exs"]}

      # Error - Lead branch doesn't exist
      Deft.Git.Job.merge_lead_branch(lead_id: "invalid", job_id: "abc123")
      # => {:error, {:merge_failed, 1}}
  """
  @spec merge_lead_branch(keyword()) ::
          {:ok, :merged} | {:ok, :conflict, [String.t()], String.t()} | {:error, term()}
  def merge_lead_branch(opts) do
    lead_id = Keyword.fetch!(opts, :lead_id)
    job_id = Keyword.fetch!(opts, :job_id)
    git = Keyword.get(opts, :git, Deft.Git)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    lead_branch = "deft/lead-#{lead_id}"
    job_branch = "deft/job-#{job_id}"

    # Create a temporary worktree for the merge to avoid checking out
    # the job branch in the main working tree (which conflicts with other worktrees)
    temp_dir =
      Path.join(System.tmp_dir!(), "deft-merge-#{job_id}-#{:erlang.unique_integer([:positive])}")

    File.cd!(working_dir, fn ->
      with {:ok, _} <- create_merge_worktree(git, job_branch, temp_dir),
           merge_result <- attempt_merge_in_worktree(git, temp_dir, lead_branch, job_branch) do
        case merge_result do
          {:ok, :conflict, conflicted_files} ->
            # Preserve the temp worktree for the merge-resolution Runner
            # Return the worktree path so it can be cleaned up later
            {:ok, :conflict, conflicted_files, temp_dir}

          _ ->
            # Clean up immediately for success or errors
            cleanup_merge_worktree(git, working_dir, temp_dir)
            merge_result
        end
      else
        error ->
          cleanup_merge_worktree(git, working_dir, temp_dir)
          error
      end
    end)
  end

  # Create a temporary worktree for the job branch to perform the merge
  defp create_merge_worktree(git, job_branch, temp_dir) do
    case git.cmd(["worktree", "add", temp_dir, job_branch]) do
      {_output, 0} ->
        {:ok, :worktree_created}

      {error_output, exit_code} ->
        Logger.error("Failed to create merge worktree for #{job_branch}: #{error_output}")
        {:error, {:worktree_creation_failed, exit_code}}
    end
  end

  # Attempt to merge the Lead branch into the job branch within the temporary worktree
  defp attempt_merge_in_worktree(git, temp_dir, lead_branch, job_branch) do
    # Ensure directory exists (git worktree add creates it, but mocks may not)
    File.mkdir_p!(temp_dir)

    File.cd!(temp_dir, fn ->
      case git.cmd(["merge", "--no-ff", lead_branch]) do
        {_output, 0} ->
          Logger.info("Successfully merged #{lead_branch} into #{job_branch}")
          {:ok, :merged}

        {output, exit_code} ->
          handle_merge_failure(git, output, exit_code, lead_branch, job_branch)
      end
    end)
  end

  # Clean up the temporary merge worktree
  defp cleanup_merge_worktree(git, working_dir, temp_dir) do
    File.cd!(working_dir, fn ->
      case git.cmd(["worktree", "remove", temp_dir, "--force"]) do
        {_output, 0} ->
          :ok

        {error_output, _exit_code} ->
          Logger.warning("Failed to remove merge worktree #{temp_dir}: #{error_output}")
          # Try to clean up manually if git worktree remove fails
          File.rm_rf(temp_dir)
          :ok
      end
    end)
  end

  # Handle merge failure - either conflict or error
  defp handle_merge_failure(git, output, exit_code, lead_branch, job_branch) do
    if exit_code == 1 and String.contains?(output, "CONFLICT") do
      # Extract conflicted files
      conflicted_files = extract_conflicted_files(git)
      Logger.warning("Merge conflict: #{lead_branch} -> #{job_branch}")
      Logger.warning("Conflicted files: #{inspect(conflicted_files)}")
      {:ok, :conflict, conflicted_files}
    else
      Logger.error("Failed to merge #{lead_branch} into #{job_branch}: #{output}")
      {:error, {:merge_failed, exit_code}}
    end
  end

  # Extract list of conflicted files from git status
  defp extract_conflicted_files(git) do
    case git.cmd(["diff", "--name-only", "--diff-filter=U"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)

      {_error_output, _exit_code} ->
        # Fallback - return empty list if we can't get conflicted files
        []
    end
  end

  # Checkout a branch in the main working tree
  # Used by complete_job to return to the original branch
  defp checkout_branch(git, branch) do
    case git.cmd(["checkout", branch]) do
      {_output, 0} ->
        {:ok, :checkout}

      {error_output, exit_code} ->
        Logger.error("Failed to checkout #{branch}: #{error_output}")
        {:error, {:checkout_failed, exit_code}}
    end
  end

  @doc """
  Runs the configured test command on the job branch after a successful merge.

  This catches semantic conflicts early — tests may fail even when the merge
  succeeds without conflicts. Should be called after each Lead merge.

  ## Options

  - `:job_id` - Required. Job identifier (for job branch name).
  - `:test_command` - Required. Test command to run (e.g., "mix test").
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).
  - `:timeout` - Optional. Test timeout in milliseconds (defaults to 300_000 / 5 minutes).

  ## Returns

  - `{:ok, :passed}` - Tests passed
  - `{:error, :test_failed, output}` - Tests failed with output
  - `{:error, :timeout}` - Tests timed out
  - `{:error, reason}` - Command execution failed

  ## Examples

      # Tests pass
      Deft.Git.Job.run_post_merge_tests(job_id: "abc123", test_command: "mix test")
      # => {:ok, :passed}

      # Tests fail
      Deft.Git.Job.run_post_merge_tests(job_id: "abc123", test_command: "mix test")
      # => {:error, :test_failed, "** (ExUnit.Error) ..."}
  """
  @spec run_post_merge_tests(keyword()) ::
          {:ok, :passed} | {:error, :test_failed, String.t()} | {:error, term()}
  def run_post_merge_tests(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    test_command = Keyword.fetch!(opts, :test_command)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    timeout = Keyword.get(opts, :timeout, 300_000)
    git = Keyword.get(opts, :git, Deft.Git)

    job_branch = "deft/job-#{job_id}"
    worktree_path = Path.join(working_dir, ".deft-worktrees/job-#{job_id}-test")

    Logger.info("Running post-merge tests on #{job_branch}: #{test_command}")

    # Create a temporary worktree for the job branch to run tests in
    with :ok <- create_test_worktree(git, working_dir, worktree_path, job_branch) do
      # Run tests in the worktree
      result = run_tests_in_worktree(worktree_path, test_command, timeout, job_branch)

      # Always clean up the worktree, even if tests failed
      cleanup_test_worktree(git, working_dir, worktree_path)

      result
    else
      {:error, _reason} = error ->
        # Cleanup attempt even if worktree creation failed
        cleanup_test_worktree(git, working_dir, worktree_path)
        error
    end
  end

  # Create a temporary worktree for running post-merge tests
  defp create_test_worktree(git, working_dir, worktree_path, job_branch) do
    File.cd!(working_dir, fn ->
      # git worktree add <path> <job_branch>
      case git.cmd(["worktree", "add", worktree_path, job_branch]) do
        {_output, 0} ->
          Logger.debug("Created test worktree at #{worktree_path}")
          :ok

        {error_output, exit_code} ->
          Logger.error("Failed to create test worktree: #{error_output}")
          {:error, {:test_worktree_creation_failed, exit_code}}
      end
    end)
  end

  # Run tests in the specified worktree with timeout enforcement
  defp run_tests_in_worktree(worktree_path, test_command, timeout, job_branch) do
    # Run the test command in a task with timeout enforcement
    task =
      Task.async(fn ->
        File.cd!(worktree_path, fn ->
          # Parse the test command (may include arguments)
          [cmd | args] = String.split(test_command, " ", trim: true)

          # Run the test command
          System.cmd(cmd, args, stderr_to_stdout: true)
        end)
      end)

    # Wait for the task to complete with timeout
    case Task.yield(task, timeout) do
      {:ok, {_output, 0}} ->
        Logger.info("Post-merge tests passed on #{job_branch}")
        {:ok, :passed}

      {:ok, {output, exit_code}} ->
        Logger.error("Post-merge tests failed on #{job_branch} (exit code: #{exit_code})")
        {:error, :test_failed, output}

      {:exit, reason} ->
        Logger.error("Post-merge tests crashed on #{job_branch}: #{inspect(reason)}")
        {:error, {:test_execution_failed, reason}}

      nil ->
        # Task timed out - kill it to prevent process leak
        Task.shutdown(task, :brutal_kill)
        Logger.error("Post-merge tests timed out on #{job_branch} after #{timeout}ms")
        {:error, :timeout}
    end
  end

  # Clean up the temporary test worktree
  defp cleanup_test_worktree(git, working_dir, worktree_path) do
    File.cd!(working_dir, fn ->
      case git.cmd(["worktree", "remove", "--force", worktree_path]) do
        {_output, 0} ->
          Logger.debug("Cleaned up test worktree at #{worktree_path}")
          :ok

        {error_output, _exit_code} ->
          # Log warning but don't fail - cleanup failure is non-fatal
          Logger.warning("Failed to remove test worktree (non-fatal): #{error_output}")
          :ok
      end
    end)
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
          Map.put(acc, :branch, String.replace_prefix(line, "branch refs/heads/", ""))

        true ->
          acc
      end
    end)
  end

  # Find orphaned deft/job-* and deft/lead-* branches
  defp find_orphaned_branches(git) do
    case git.cmd(["branch", "--list", "deft/*"]) do
      {output, 0} ->
        all_branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.trim_leading(&1, "* "))
          |> Enum.filter(&String.starts_with?(&1, "deft/"))

        # Get running job IDs to filter out active branches
        running_job_ids = get_running_job_ids()

        orphaned_branches =
          all_branches
          |> Enum.reject(&branch_belongs_to_running_job?(&1, running_job_ids))

        {:ok, orphaned_branches}

      {error_output, exit_code} ->
        Logger.error("Failed to list branches: #{error_output}")
        {:error, {:branch_list_failed, exit_code}}
    end
  end

  # Get all running job IDs from the ProcessRegistry
  defp get_running_job_ids do
    # Query the Registry for all registered job supervisors
    Registry.select(Deft.ProcessRegistry, [
      {{{:job_supervisor, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  # Check if a branch belongs to a running job
  defp branch_belongs_to_running_job?(branch, running_job_ids) do
    case branch do
      # Job branches: deft/job-<job_id>
      "deft/job-" <> job_id ->
        job_id in running_job_ids

      # Lead branches: deft/lead-<job_id>-<deliverable>
      # Extract job_id prefix and check if it's in running_job_ids
      "deft/lead-" <> lead_id ->
        Enum.any?(running_job_ids, fn job_id ->
          String.starts_with?(lead_id, job_id <> "-")
        end)

      _ ->
        false
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

  # Pop the stash created during job creation, if it exists
  defp pop_job_stash(git, job_id) do
    stash_message = "Deft job creation: #{job_id}"

    # List stashes and check if our stash exists
    case git.cmd(["stash", "list"]) do
      {output, 0} ->
        # Check if any stash has our message
        stash_index =
          output
          |> String.split("\n", trim: true)
          |> Enum.find_index(&String.contains?(&1, stash_message))

        if stash_index do
          # Pop the stash
          case git.cmd(["stash", "pop", "stash@{#{stash_index}}"]) do
            {_output, 0} ->
              Logger.info("Restored user's stashed changes from job creation")
              IO.puts("Your previously stashed changes have been restored.\n")
              :ok

            {error_output, _exit_code} ->
              Logger.warning("""
              Failed to restore stashed changes from job creation.
              You may need to manually restore them with: git stash pop stash@{#{stash_index}}

              Error: #{error_output}
              """)

              IO.puts("""
              Warning: Failed to automatically restore your stashed changes.
              Please manually restore them with: git stash pop stash@{#{stash_index}}
              """)

              :ok
          end
        else
          # No stash found - this is normal if working tree was clean
          :ok
        end

      {error_output, _exit_code} ->
        Logger.warning("Failed to list stashes: #{error_output}")
        :ok
    end
  end

  @doc """
  Completes a job by merging the job branch into the original branch and cleaning up.

  After verification passes, this function:
  1. Squash-merges (or regular merges) `deft/job-<job_id>` into the original branch
  2. Deletes the job branch
  3. Verifies no worktrees remain
  4. Restores any stashed changes from job creation

  ## Options

  - `:job_id` - Required. Job identifier.
  - `:original_branch` - Required. The branch to merge into (e.g., "main").
  - `:squash` - Optional. Whether to squash-merge (defaults to true).
  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).

  ## Returns

  - `{:ok, :completed}` - Job completed successfully
  - `{:error, reason}` - Git command failed

  ## Examples

      # Squash-merge (default)
      Deft.Git.Job.complete_job(job_id: "abc123", original_branch: "main")
      # => {:ok, :completed}

      # Regular merge (keep history)
      Deft.Git.Job.complete_job(job_id: "abc123", original_branch: "main", squash: false)
      # => {:ok, :completed}

      # Error - job branch doesn't exist
      Deft.Git.Job.complete_job(job_id: "invalid", original_branch: "main")
      # => {:error, {:checkout_failed, 128}}
  """
  @spec complete_job(keyword()) :: {:ok, :completed} | {:error, term()}
  def complete_job(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    original_branch = Keyword.fetch!(opts, :original_branch)
    squash = Keyword.get(opts, :squash, true)
    git = Keyword.get(opts, :git, Deft.Git)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    job_branch = "deft/job-#{job_id}"

    File.cd!(working_dir, fn ->
      result =
        with {:ok, :checkout} <- checkout_branch(git, original_branch),
             {:ok, :merged} <- merge_job_branch(git, job_branch, squash),
             {:ok, :deleted} <- delete_job_branch(git, job_branch) do
          :ok
        end

      # Always restore user's stashed changes, even if worktree verification fails
      pop_job_stash(git, job_id)

      case result do
        :ok ->
          case verify_no_worktrees(git) do
            :ok ->
              Logger.info("Job #{job_id} completed successfully")
              {:ok, :completed}

            error ->
              error
          end

        error ->
          error
      end
    end)
  end

  # Merge the job branch into the current branch
  defp merge_job_branch(git, job_branch, squash) do
    merge_args =
      if squash do
        ["merge", "--squash", job_branch]
      else
        ["merge", "--no-ff", job_branch]
      end

    case git.cmd(merge_args) do
      {_output, 0} ->
        # If squash merge, we need to commit the squashed changes
        if squash do
          commit_squash_merge(git, job_branch)
        else
          Logger.info("Successfully merged #{job_branch} with history")
          {:ok, :merged}
        end

      {error_output, exit_code} ->
        Logger.error("Failed to merge #{job_branch}: #{error_output}")
        {:error, {:merge_failed, exit_code}}
    end
  end

  # Commit the squashed merge
  defp commit_squash_merge(git, job_branch) do
    commit_message = "Complete job: #{job_branch}\n\nSquash-merged all changes from #{job_branch}"

    case git.cmd(["commit", "-m", commit_message]) do
      {_output, 0} ->
        Logger.info("Successfully squash-merged #{job_branch}")
        {:ok, :merged}

      {error_output, exit_code} ->
        Logger.error("Failed to commit squash merge: #{error_output}")
        {:error, {:commit_failed, exit_code}}
    end
  end

  # Delete the job branch
  defp delete_job_branch(git, job_branch) do
    case git.cmd(["branch", "-d", job_branch]) do
      {_output, 0} ->
        Logger.info("Deleted job branch: #{job_branch}")
        {:ok, :deleted}

      {error_output, exit_code} ->
        Logger.error("Failed to delete branch #{job_branch}: #{error_output}")
        {:error, {:branch_deletion_failed, exit_code}}
    end
  end

  # Verify no worktrees remain (only main working tree should exist)
  defp verify_no_worktrees(git) do
    case git.cmd(["worktree", "list", "--porcelain"]) do
      {output, 0} ->
        worktrees = count_worktrees(output)

        if worktrees <= 1 do
          Logger.debug("Verified only main working tree remains")
          :ok
        else
          Logger.warning("#{worktrees} worktrees remain (expected 1)")
          {:error, {:worktrees_remain, worktrees}}
        end

      {error_output, exit_code} ->
        Logger.error("Failed to list worktrees: #{error_output}")
        {:error, {:worktree_list_failed, exit_code}}
    end
  end

  # Count number of worktrees from --porcelain output
  defp count_worktrees(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> length()
  end

  @doc """
  Cleans up after a job failure or abort.

  Removes all Lead worktrees, deletes the job branch (respecting `keep_failed_branches`
  config), restores the original branch, and pops any stashed changes from job creation.

  ## Options

  - `:job_id` - Required. Job identifier.
  - `:original_branch` - Required. The branch to restore (e.g., "main").
  - `:git` - Optional. Git adapter module (defaults to Deft.Git).
  - `:working_dir` - Optional. Repository root (defaults to File.cwd!()).
  - `:keep_failed_branches` - Optional. Keep job branch for debugging (defaults to false).

  ## Returns

  - `:ok` - Cleanup completed
  - `{:error, reason}` - Cleanup failed (partial cleanup may have occurred)

  ## Examples

      # Abort a job and clean up everything
      Deft.Git.Job.abort_job(job_id: "abc123", original_branch: "main")
      # => :ok

      # Keep the job branch for debugging
      Deft.Git.Job.abort_job(
        job_id: "abc123",
        original_branch: "main",
        keep_failed_branches: true
      )
      # => :ok
  """
  @spec abort_job(keyword()) :: :ok | {:error, term()}
  def abort_job(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    original_branch = Keyword.get(opts, :original_branch)
    git = Keyword.get(opts, :git, Deft.Git)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    keep_failed_branches = Keyword.get(opts, :keep_failed_branches, false)

    job_branch = "deft/job-#{job_id}"

    Logger.info("Aborting job #{job_id}...")

    File.cd!(working_dir, fn ->
      # Step 1: Remove all Lead worktrees for this job
      remove_lead_worktrees(git, working_dir, job_id)

      # Step 2: Restore the original branch (skip if job branch was never created)
      restore_original_branch(git, original_branch)

      # Step 3: Delete the job branch if not keeping failed branches (skip if never created)
      cleanup_job_branch(git, job_branch, original_branch, keep_failed_branches)

      # Step 4: Restore user's stashed changes if they were stashed during job creation
      pop_job_stash(git, job_id)

      Logger.info("Job #{job_id} aborted - cleanup completed")
      :ok
    end)
  end

  defp restore_original_branch(_git, nil) do
    Logger.info("Skipping branch checkout - job branch was never created")
  end

  defp restore_original_branch(git, original_branch) do
    case checkout_branch(git, original_branch) do
      {:ok, :checkout} ->
        Logger.info("Restored original branch: #{original_branch}")

      {:error, reason} ->
        Logger.warning(
          "Failed to checkout original branch #{original_branch}: #{inspect(reason)}"
        )
    end
  end

  defp cleanup_job_branch(_git, _job_branch, nil, _keep_failed_branches) do
    # Job branch was never created, nothing to clean up
    :ok
  end

  defp cleanup_job_branch(_git, job_branch, _original_branch, true) do
    Logger.info("Keeping job branch #{job_branch} for debugging")
  end

  defp cleanup_job_branch(git, job_branch, _original_branch, false) do
    case delete_job_branch_force(git, job_branch) do
      {:ok, :deleted} ->
        Logger.info("Deleted job branch: #{job_branch}")

      {:error, reason} ->
        Logger.warning("Failed to delete job branch #{job_branch}: #{inspect(reason)}")
    end
  end

  # Remove all Lead worktrees associated with a job
  defp remove_lead_worktrees(git, working_dir, job_id) do
    case git.cmd(["worktree", "list", "--porcelain"]) do
      {output, 0} ->
        worktrees = parse_worktree_list(output, working_dir)

        # Find all Lead worktrees for this job
        job_worktrees =
          Enum.filter(worktrees, fn worktree ->
            case worktree.branch do
              # Lead branches: deft/lead-<job_id>-<deliverable>
              "deft/lead-" <> lead_id ->
                String.starts_with?(lead_id, job_id <> "-")

              _ ->
                false
            end
          end)

        # Remove each Lead worktree
        Enum.each(job_worktrees, fn worktree ->
          case git.cmd(["worktree", "remove", worktree.path, "--force"]) do
            {_output, 0} ->
              Logger.info("Removed Lead worktree: #{worktree.branch} at #{worktree.path}")

            {error_output, _exit_code} ->
              Logger.warning("Failed to remove worktree #{worktree.path}: #{error_output}")
          end
        end)

      {error_output, _exit_code} ->
        Logger.warning("Failed to list worktrees during abort: #{error_output}")
    end
  end

  # Delete the job branch forcefully (used during abort)
  defp delete_job_branch_force(git, job_branch) do
    case git.cmd(["branch", "-D", job_branch]) do
      {_output, 0} ->
        {:ok, :deleted}

      {error_output, exit_code} ->
        Logger.error("Failed to force-delete branch #{job_branch}: #{error_output}")
        {:error, {:branch_deletion_failed, exit_code}}
    end
  end
end
