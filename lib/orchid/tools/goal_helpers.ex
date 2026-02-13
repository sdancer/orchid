defmodule Orchid.Tools.GoalHelpers do
  @moduledoc "Shared helpers for goal tools — resolves goal references by ID or name"

  alias Orchid.Object

  @doc """
  Resolve a goal reference (ID or name) within a project.
  Returns the goal ID if found, nil otherwise.
  """
  def resolve_goal_ref(nil, _project_id), do: nil
  def resolve_goal_ref("", _project_id), do: nil

  def resolve_goal_ref(ref, project_id) do
    # Try as ID first
    case Object.get(ref) do
      {:ok, %{type: :goal}} ->
        ref

      _ ->
        # Fall back to name match within project
        Object.list_goals_for_project(project_id)
        |> Enum.find(fn g -> g.name == ref end)
        |> case do
          nil -> nil
          goal -> goal.id
        end
    end
  end

  @doc """
  Resolve a list of goal references (IDs or names) within a project.
  Filters out any that can't be resolved.
  """
  def resolve_goal_refs(refs, project_id) when is_list(refs) do
    refs
    |> Enum.map(&resolve_goal_ref(&1, project_id))
    |> Enum.reject(&is_nil/1)
  end

  def resolve_goal_refs(_, _project_id), do: []
end
