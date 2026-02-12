defmodule Orchid.ProjectTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)
    # Use a unique project ID per test to avoid collisions
    project_id = "test-project-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

    on_exit(fn ->
      # Clean up project dir
      Orchid.Project.delete_dir(project_id)
    end)

    %{project_id: project_id}
  end

  describe "Project directory management" do
    test "data_dir returns configured path" do
      assert Orchid.Project.data_dir() == "tmp/test_data"
    end

    test "files_path returns correct path", %{project_id: project_id} do
      path = Orchid.Project.files_path(project_id)
      assert path == "tmp/test_data/projects/#{project_id}/files"
    end

    test "ensure_dir creates the directory", %{project_id: project_id} do
      {:ok, path} = Orchid.Project.ensure_dir(project_id)
      assert File.dir?(path)
    end

    test "ensure_dir is idempotent", %{project_id: project_id} do
      {:ok, path1} = Orchid.Project.ensure_dir(project_id)
      {:ok, path2} = Orchid.Project.ensure_dir(project_id)
      assert path1 == path2
      assert File.dir?(path1)
    end

    test "delete_dir removes the directory", %{project_id: project_id} do
      {:ok, path} = Orchid.Project.ensure_dir(project_id)
      assert File.dir?(path)

      :ok = Orchid.Project.delete_dir(project_id)
      refute File.dir?(path)
    end

    test "canary file: write a file and read it back", %{project_id: project_id} do
      {:ok, path} = Orchid.Project.ensure_dir(project_id)

      canary = Path.join(path, "canary.txt")
      File.write!(canary, "Hello from project #{project_id}")

      assert File.read!(canary) == "Hello from project #{project_id}"
    end
  end
end
