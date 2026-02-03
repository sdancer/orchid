defmodule Orchid.Tools.Memory do
  @moduledoc "Store and recall from agent memory"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "memory"

  @impl true
  def description, do: "Store or recall information from the agent's working memory"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["store", "recall", "list", "delete"],
          description: "The memory operation to perform"
        },
        key: %{
          type: "string",
          description: "The key to store/recall (required for store/recall/delete)"
        },
        value: %{
          type: "string",
          description: "The value to store (required for store action)"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "store", "key" => key, "value" => _value}, %{agent_state: _state}) do
    # Note: The actual memory update happens in the Agent module
    # This tool just signals the intent
    {:ok, "Stored '#{key}' in memory"}
  end

  def execute(%{"action" => "recall", "key" => key}, %{agent_state: state}) do
    case Map.get(state.memory, key) do
      nil -> {:ok, "No value found for key: #{key}"}
      value -> {:ok, "#{key}: #{inspect(value)}"}
    end
  end

  def execute(%{"action" => "list"}, %{agent_state: state}) do
    if map_size(state.memory) == 0 do
      {:ok, "Memory is empty"}
    else
      list =
        state.memory
        |> Enum.map(fn {k, v} -> "- #{k}: #{inspect(v)}" end)
        |> Enum.join("\n")

      {:ok, "Memory contents:\n#{list}"}
    end
  end

  def execute(%{"action" => "delete", "key" => key}, %{agent_state: _state}) do
    {:ok, "Deleted '#{key}' from memory"}
  end

  def execute(%{"action" => action}, _context) do
    {:error, "Unknown memory action: #{action}"}
  end
end
