defmodule Orchid.Project do
  @moduledoc """
  Project directory management.
  Each project gets an Orchid-managed directory under `<data_dir>/projects/<id>/files/`.
  """

  def data_dir, do: Application.get_env(:orchid, :data_dir, "priv/data")

  def files_path(project_id) do
    Path.join([data_dir(), "projects", project_id, "files"])
  end

  def ensure_dir(project_id) do
    path = files_path(project_id)
    File.mkdir_p!(path)
    {:ok, path}
  end

  def delete_dir(project_id) do
    path = Path.join([data_dir(), "projects", project_id])
    File.rm_rf(path)
    :ok
  end
end
