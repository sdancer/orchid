defmodule Orchid.Tools.ObjectList do
  @moduledoc "List all objects"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "object_list"

  @impl true
  def description, do: "List all available objects with their IDs and types"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        type: %{
          type: "string",
          enum: ["file", "artifact", "markdown", "function"],
          description: "Filter by object type (optional)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(args, _context) do
    objects = Object.list()

    objects = if args["type"] do
      type = String.to_existing_atom(args["type"])
      Enum.filter(objects, fn obj -> obj.type == type end)
    else
      objects
    end

    if objects == [] do
      {:ok, "No objects found"}
    else
      list = objects
      |> Enum.map(fn obj ->
        "- #{obj.id}: #{obj.name} (#{obj.type})"
      end)
      |> Enum.join("\n")

      {:ok, "Objects:\n#{list}"}
    end
  end
end
