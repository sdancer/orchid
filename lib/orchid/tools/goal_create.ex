defmodule Orchid.Tools.GoalCreate do
  @moduledoc "Create a new goal in the agent's project"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "goal_create"

  @impl true
  def description, do: "Create a new goal in the current project"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        name: %{
          type: "string",
          description: "Short, actionable goal name"
        },
        description: %{
          type: "string",
          description: "Detailed description of the goal"
        },
        parent_goal_id: %{
          type: "string",
          description: "ID of the parent goal (for subgoals)"
        },
        depends_on: %{
          type: "array",
          items: %{type: "string"},
          description: "List of goal IDs this goal depends on"
        }
      },
      required: ["name"]
    }
  end

  @impl true
  def execute(%{"name" => name} = args, %{agent_state: %{id: agent_id, project_id: project_id}})
      when not is_nil(project_id) do
    description = args["description"] || ""
    parent_goal_id = args["parent_goal_id"]
    depends_on = args["depends_on"] || []

    metadata = %{
      project_id: project_id,
      status: :pending,
      depends_on: depends_on,
      agent_id: agent_id,
      parent_goal_id: parent_goal_id
    }

    {:ok, goal} = Object.create(:goal, name, description, metadata: metadata)
    {:ok, "Created goal: #{goal.name} (ID: #{goal.id})"}
  end

  def execute(_args, _context) do
    {:error, "No project assigned to this agent. Cannot create goals."}
  end
end
