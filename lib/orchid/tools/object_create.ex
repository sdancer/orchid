defmodule Orchid.Tools.ObjectCreate do
  @moduledoc "Create a new object"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "object_create"

  @impl true
  def description, do: "Create a new object (file, artifact, markdown, function, prompt, or project)"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        type: %{
          type: "string",
          enum: ["file", "artifact", "markdown", "function", "prompt", "project"],
          description: "The type of object to create"
        },
        name: %{
          type: "string",
          description: "Name of the object (e.g., filename)"
        },
        content: %{
          type: "string",
          description: "Initial content of the object"
        },
        path: %{
          type: "string",
          description: "Filesystem path (for file type)"
        },
        language: %{
          type: "string",
          description: "Programming language (optional, auto-detected from name)"
        }
      },
      required: ["type", "name", "content"]
    }
  end

  @impl true
  def execute(args, _context) do
    type = String.to_existing_atom(args["type"])
    name = args["name"]
    content = args["content"]

    opts = []
    opts = if args["path"], do: [{:path, args["path"]} | opts], else: opts
    opts = if args["language"], do: [{:language, args["language"]} | opts], else: opts

    {:ok, obj} = Object.create(type, name, content, opts)
    {:ok, "Created #{obj.type} object: #{obj.name} (ID: #{obj.id})"}
  end
end
