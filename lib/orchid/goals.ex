defmodule Orchid.Goals do
  @moduledoc """
  Context module for goal business logic.
  All goal operations go through here — no LiveView awareness.
  """

  alias Orchid.Object

  @doc "List goals for a project."
  def list_for_project(project_id) do
    Object.list_goals_for_project(project_id)
  end

  @doc "Create a goal in a project."
  def create(name, description, project_id, opts \\ []) do
    metadata = %{
      project_id: project_id,
      status: :pending,
      depends_on: [],
      parent_goal_id: opts[:parent_goal_id]
    }

    Object.create(:goal, name, description, metadata: metadata)
  end

  @doc "Delete a goal and clean up references from other goals' depends_on lists."
  def delete(goal_id) do
    # Find the goal to get its project_id for the cleanup query
    case Object.get(goal_id) do
      {:ok, goal} ->
        project_id = goal.metadata[:project_id]

        # Remove this goal from any depends_on lists in the same project
        if project_id do
          for other <- list_for_project(project_id) do
            depends_on = other.metadata[:depends_on] || []

            if goal_id in depends_on do
              Object.update_metadata(other.id, %{depends_on: List.delete(depends_on, goal_id)})
            end
          end
        end

        Object.delete(goal_id)

      _ ->
        Object.delete(goal_id)
    end
  end

  @doc "Delete all goals for a project."
  def clear_project(project_id) do
    for goal <- list_for_project(project_id) do
      Object.delete(goal.id)
    end

    :ok
  end

  @doc "Toggle a goal between :pending and :completed."
  def toggle_status(goal_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        new_status =
          case goal.metadata[:status] do
            :completed -> :pending
            _ -> :completed
          end

        Object.update_metadata(goal_id, %{status: new_status})

      error ->
        error
    end
  end

  @doc "Set a goal's status explicitly."
  def set_status(goal_id, status) when is_atom(status) do
    Object.update_metadata(goal_id, %{status: status})
  end

  @doc "Add a dependency to a goal."
  def add_dependency(goal_id, depends_on_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []

        if depends_on_id not in current_deps do
          Object.update_metadata(goal_id, %{depends_on: [depends_on_id | current_deps]})
        else
          {:ok, goal}
        end

      error ->
        error
    end
  end

  @doc "Remove a dependency from a goal."
  def remove_dependency(goal_id, depends_on_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []
        Object.update_metadata(goal_id, %{depends_on: List.delete(current_deps, depends_on_id)})

      error ->
        error
    end
  end

  @doc "Assign a goal to an agent and kick off a message."
  def assign_to_agent(goal_id, agent_id) do
    case Object.get(goal_id) do
      {:ok, goal} ->
        {:ok, _} = Object.update_metadata(goal_id, %{agent_id: agent_id})

        message = "Work on goal: #{goal.name}\nGoal ID: #{goal_id}"

        Task.start(fn ->
          Orchid.Agent.stream(agent_id, message, fn _chunk -> :ok end)
        end)

        :ok

      error ->
        error
    end
  end
end
