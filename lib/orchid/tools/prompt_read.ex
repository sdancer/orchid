defmodule Orchid.Tools.PromptRead do
  @moduledoc "Read a prompt's content by ID"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "prompt_read"

  @impl true
  def description, do: "Read the content of a saved prompt by its ID"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the prompt to read"
        }
      },
      required: ["id"]
    }
  end

  @impl true
  def execute(%{"id" => id}, _context) do
    case Object.get(id) do
      {:ok, obj} when obj.type == :prompt ->
        {:ok,
         """
         Name: #{obj.name}

         Content:
         #{obj.content}
         """}

      {:ok, _obj} ->
        {:error, "Object #{id} is not a prompt"}

      {:error, :not_found} ->
        {:error, "Prompt not found: #{id}"}
    end
  end

  def execute(_args, _context), do: {:error, "Missing required parameter: id"}
end
