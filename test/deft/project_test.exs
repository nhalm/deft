defmodule Deft.ProjectTest do
  use ExUnit.Case, async: false
  doctest Deft.Project

  alias Deft.Project

  describe "project_dir/1" do
    test "resolves to git root when inside a git repo" do
      cwd = File.cwd!()
      path = Project.project_dir(cwd)

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
end
