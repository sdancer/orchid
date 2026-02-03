defmodule Orchid.Tools.ObjectRead do
  @moduledoc "Read an object's content by ID"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "object_read"

  @impl true
  def description, do: "Read the content of an object by its ID"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the object to read"
        }
      },
      required: ["id"]
    }
  end

  @impl true
  def execute(%{"id" => id}, _context) do
    case Object.get(id) do
      {:ok, obj} ->
        {:ok,
         """
         Name: #{obj.name}
         Type: #{obj.type}
         Language: #{obj.language || "unknown"}
         Path: #{obj.path || "N/A"}

         Content:
         #{obj.content}
         """}

      {:error, :not_found} ->
        {:error, "Object not found: #{id}"}
    end
  end
end
