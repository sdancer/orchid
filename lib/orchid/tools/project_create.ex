defmodule Orchid.Tools.ProjectCreate do
  @moduledoc "Create Orchid projects"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "project_create"

  @impl true
  def description, do: "Create a new Orchid project and return its workspace path"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "Project name"
        }
      },
      required: ["name"]
    }
  end

  @impl true
  def execute(%{"name" => raw_name}, _context) when is_binary(raw_name) do
    name = String.trim(raw_name)

    if name == "" do
      {:error, "Project name cannot be empty."}
    else
      {:ok, project} = Orchid.Projects.create(name)

      {:ok,
       "Created project #{project.name} (#{project.id})\nfiles: #{Orchid.Project.files_path(project.id)}"}
    end
  end

  def execute(_args, _context) do
    {:error, "name is required"}
  end
end
