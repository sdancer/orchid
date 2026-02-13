defmodule Orchid.Tools.GoalList do
  @moduledoc "List goals for the agent's project"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "goal_list"

  @impl true
  def description, do: "List all goals for the current project"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def execute(_args, %{agent_state: %{project_id: project_id}}) when not is_nil(project_id) do
    goals = Object.list_goals_for_project(project_id)

    if goals == [] do
      {:ok, "No goals found for this project."}
    else
      list =
        goals
        |> Enum.map(fn goal ->
          status = goal.metadata[:status] || :pending
          deps = goal.metadata[:depends_on] || []
          agent = goal.metadata[:agent_id]
          parent = goal.metadata[:parent_goal_id]

          parts = ["- #{goal.id}: #{goal.name} [#{status}]"]
          parts = if agent, do: parts ++ ["  Agent: #{agent}"], else: parts
          parts = if parent, do: parts ++ ["  Parent: #{parent}"], else: parts
          parts = if deps != [], do: parts ++ ["  Depends on: #{Enum.join(deps, ", ")}"], else: parts

          Enum.join(parts, "\n")
        end)
        |> Enum.join("\n")

      {:ok, "Goals:\n#{list}"}
    end
  end

  def execute(_args, _context) do
    {:error, "No project assigned to this agent. Cannot list goals."}
  end
end
