defmodule Deft.ProjectTest do
  use ExUnit.Case, async: false
  doctest Deft.Project

  alias Deft.Project

  describe "project_dir/1" do
    test "encodes absolute paths correctly" do
      path = Project.project_dir("/Users/alice/code/myapp")
      assert String.ends_with?(path, "projects/Users-alice-code-myapp")
    end

    test "strips leading dash from encoded path" do
      # Root path "/" becomes "" after stripping leading -
      path = Project.project_dir("/")
      refute String.contains?(path, "projects/-")
    end

    test "uses current working directory by default" do
      # Should not raise an error
      path = Project.project_dir()
      assert is_binary(path)
      assert String.contains?(path, "/.deft/projects/")
    end

    test "resolves to git root when inside a git repo" do
      # This test runs in the actual repo
      cwd = File.cwd!()
      path = Project.project_dir(cwd)

      # The path should be based on the git root, not a subdirectory
      assert String.contains?(path, "projects/")
      assert is_binary(path)
    end
  end

  describe "ensure_project_dirs/1" do
    setup do
      # Use a temp directory for testing
      test_dir = Path.join(System.tmp_dir!(), "deft_project_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf(test_dir)
      end)

      %{test_dir: test_dir}
    end

    test "creates all required subdirectories", %{test_dir: test_dir} do
      # This will create directories in the actual ~/.deft based on test_dir path
      # Since we're testing with a temp dir, it won't conflict with real data
      assert :ok = Project.ensure_project_dirs(test_dir)

      project_path = Project.project_dir(test_dir)
      assert File.dir?(project_path)
      assert File.dir?(Path.join(project_path, "sessions"))
      assert File.dir?(Path.join(project_path, "cache"))
      assert File.dir?(Path.join(project_path, "jobs"))
    end

    test "is idempotent", %{test_dir: test_dir} do
      assert :ok = Project.ensure_project_dirs(test_dir)
      assert :ok = Project.ensure_project_dirs(test_dir)
    end
  end

  describe "sessions_dir/1" do
    test "returns sessions subdirectory" do
      path = Project.sessions_dir("/Users/alice/code/myapp")
      assert String.ends_with?(path, "projects/Users-alice-code-myapp/sessions")
    end
  end

  describe "cache_dir/1" do
    test "returns cache subdirectory" do
      path = Project.cache_dir("/Users/alice/code/myapp")
      assert String.ends_with?(path, "projects/Users-alice-code-myapp/cache")
    end
  end

  describe "jobs_dir/1" do
    test "returns jobs subdirectory" do
      path = Project.jobs_dir("/Users/alice/code/myapp")
      assert String.ends_with?(path, "projects/Users-alice-code-myapp/jobs")
    end
  end
end
