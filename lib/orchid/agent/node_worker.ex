defmodule Orchid.Agent.NodeWorker do
  @moduledoc """
  Introspection helpers for active NodeServer worker processes.
  """

  alias Orchid.Agent.NodeServer

  @spec list() :: [map()]
  def list do
    children =
      case DynamicSupervisor.which_children(Orchid.Agent.NodeSupervisor) do
        list when is_list(list) -> list
        _ -> []
      end

    Enum.map(children, fn {_id, pid, _type, _modules} ->
      build_worker(pid)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_worker(pid) when is_pid(pid) do
    case safe_state(pid) do
      {:ok, state} ->
        goal_id = to_string(state.id)

        project_id =
          case Orchid.Object.get(goal_id) do
            {:ok, goal} when goal.type == :goal -> goal.metadata[:project_id]
            _ -> nil
          end

        %{
          id: goal_id,
          pid: pid,
          status: state.status,
          depth: state.depth,
          objective: state.objective,
          project_id: project_id
        }

      _ ->
        nil
    end
  end

  defp safe_state(pid) do
    try do
      {:ok, NodeServer.get_state(pid, 500)}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end
end
