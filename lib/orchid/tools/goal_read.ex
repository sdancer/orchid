defmodule Orchid.Tools.GoalRead do
  @moduledoc "Read a specific goal by ID"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "goal_read"

  @impl true
  def description, do: "Read full details of a goal by its ID"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the goal to read"
        }
      },
      required: ["id"]
    }
  end

  @impl true
  def execute(%{"id" => id}, _context) do
    case Object.get(id) do
      {:ok, obj} when obj.type == :goal ->
        status = obj.metadata[:status] || :pending
        deps = obj.metadata[:depends_on] || []
        agent = obj.metadata[:agent_id]
        parent = obj.metadata[:parent_goal_id]
        project = obj.metadata[:project_id]

        details = [
          "Goal: #{obj.name}",
          "ID: #{obj.id}",
          "Status: #{status}",
          "Project: #{project || "none"}",
          "Agent: #{agent || "unassigned"}",
          "Parent: #{parent || "none"}",
          "Depends on: #{if deps == [], do: "none", else: Enum.join(deps, ", ")}"
        ]

        details =
          if obj.content && obj.content != "" do
            details ++ ["", "Description:", obj.content]
          else
            details
          end

        {:ok, Enum.join(details, "\n")}

      {:ok, _obj} ->
        {:error, "Object #{id} is not a goal"}

      {:error, :not_found} ->
        {:error, "Goal not found: #{id}"}
    end
  end
end
