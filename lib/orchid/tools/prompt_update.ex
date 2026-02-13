defmodule Orchid.Tools.PromptUpdate do
  @moduledoc "Update an existing prompt"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "prompt_update"

  @impl true
  def description, do: "Update the content of an existing prompt"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the prompt to update"
        },
        content: %{
          type: "string",
          description: "The new content for the prompt"
        }
      },
      required: ["id", "content"]
    }
  end

  @impl true
  def execute(%{"id" => id, "content" => content}, _context) do
    case Object.get(id) do
      {:ok, obj} when obj.type == :prompt ->
        {:ok, updated} = Object.update(id, content)
        {:ok, "Updated prompt: #{updated.name} (ID: #{updated.id})"}

      {:ok, _obj} ->
        {:error, "Object #{id} is not a prompt"}

      {:error, :not_found} ->
        {:error, "Prompt not found: #{id}"}
    end
  end

  def execute(_args, _context), do: {:error, "Missing required parameters: id, content"}
end
