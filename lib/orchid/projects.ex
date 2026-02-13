defmodule Orchid.Projects do
  @moduledoc """
  Context module for project business logic.
  All project operations go through here — no LiveView awareness.
  """

  alias Orchid.Object

  @doc "Create a new project with its directory."
  def create(name) do
    {:ok, project} = Object.create(:project, name, "")
    Orchid.Project.ensure_dir(project.id)
    {:ok, project}
  end

  @doc "Delete a project and its directory."
  def delete(project_id) do
    stop_sandbox(project_id)
    Orchid.Project.delete_dir(project_id)
    Object.delete(project_id)
  end

  @doc "Pause a project and stop its agents and sandbox (fire-and-forget)."
  def pause(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :paused})
    stop_sandbox(project_id)
    stop_agents_async(project_id)
    :ok
  end

  @doc "Resume a paused project."
  def resume(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :active})
    :ok
  end

  @doc "Archive a project and stop its agents and sandbox (fire-and-forget)."
  def archive(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :archived})
    stop_sandbox(project_id)
    stop_agents_async(project_id)
    :ok
  end

  @doc "Restore an archived project."
  def restore(project_id) do
    {:ok, _} = Object.update_metadata(project_id, %{status: :active})
    :ok
  end

  @doc "Get a project's status from its metadata."
  def status(project) do
    project.metadata[:status]
  end

  @doc "Ensure a sandbox is running for the given project. Idempotent."
  def ensure_sandbox(project_id) do
    case Orchid.Sandbox.status(project_id) do
      nil ->
        DynamicSupervisor.start_child(
          Orchid.AgentSupervisor,
          {Orchid.Sandbox, project_id}
        )

      _status ->
        {:ok, :already_running}
    end
  end

  @doc "Stop the sandbox for a project if running."
  def stop_sandbox(project_id) do
    Orchid.Sandbox.stop(project_id)
  end

  @doc "Get sandbox status for a project, or nil if not running."
  def sandbox_status(project_id) do
    Orchid.Sandbox.status(project_id)
  end

  # Stop all agents for a project using fire-and-forget tasks
  defp stop_agents_async(project_id) do
    for agent_id <- Orchid.Agent.list() do
      case Orchid.Agent.get_state(agent_id, 1000) do
        {:ok, state} when state.project_id == project_id ->
          Task.start(fn -> Orchid.Agent.stop(agent_id) end)

        _ ->
          :ok
      end
    end
  end
end
