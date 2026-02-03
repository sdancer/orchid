defmodule Orchid.Tools.PromptList do
  @moduledoc "List all saved prompts"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "prompt_list"

  @impl true
  def description, do: "List all saved system prompts"

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
    prompts = Object.list_prompts()

    if prompts == [] do
      {:ok, "No prompts found"}
    else
      list =
        prompts
        |> Enum.map(fn obj ->
          preview = obj.content |> String.slice(0, 100) |> String.replace("\n", " ")
          "- #{obj.id}: #{obj.name}\n  Preview: #{preview}..."
        end)
        |> Enum.join("\n")

      {:ok, "Prompts:\n#{list}"}
    end
  end
end
