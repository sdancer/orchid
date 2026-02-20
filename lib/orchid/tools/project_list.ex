defmodule Orchid.Tools.ProjectList do
  @moduledoc "List Orchid projects with workspace file locations"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "project_list"

  @impl true
  def description, do: "List all Orchid projects with project name and files path"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def execute(_args, _context) do
    projects = Object.list_projects()

    lines =
      Enum.map(projects, fn p ->
        status = p.metadata[:status] || :active
        files_path = Orchid.Project.files_path(p.id)
        "[#{status}] #{p.name} (#{p.id})\nfiles: #{files_path}"
      end)

    text =
      case lines do
        [] -> "No projects found."
        _ -> Enum.join(lines, "\n\n")
      end

    {:ok, text}
  end
end
