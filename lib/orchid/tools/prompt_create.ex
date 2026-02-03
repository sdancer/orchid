defmodule Orchid.Tools.PromptCreate do
  @moduledoc "Create a new prompt"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "prompt_create"

  @impl true
  def description, do: "Create a new system prompt"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "Name of the prompt"
        },
        content: %{
          type: "string",
          description: "The prompt content"
        }
      },
      required: ["name", "content"]
    }
  end

  @impl true
  def execute(%{"name" => name, "content" => content}, _context) do
    {:ok, obj} = Object.create(:prompt, name, content)
    {:ok, "Created prompt: #{obj.name} (ID: #{obj.id})"}
  end
end
