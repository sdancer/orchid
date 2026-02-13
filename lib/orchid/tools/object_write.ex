defmodule Orchid.Tools.ObjectWrite do
  @moduledoc "Update an object's content"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "object_write"

  @impl true
  def description, do: "Update the content of an existing object"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the object to update"
        },
        content: %{
          type: "string",
          description: "The new content for the object"
        }
      },
      required: ["id", "content"]
    }
  end

  @impl true
  def execute(%{"id" => id, "content" => content}, _context) do
    case Object.update(id, content) do
      {:ok, obj} ->
        {:ok, "Updated object #{obj.name} (#{obj.id})"}

      {:error, :not_found} ->
        {:error, "Object not found: #{id}"}
    end
  end

  def execute(_args, _context), do: {:error, "Missing required parameters: id, content"}
end
