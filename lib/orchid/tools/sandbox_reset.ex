defmodule Orchid.Tools.SandboxReset do
  @moduledoc "Reset sandbox container for an agent"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "sandbox_reset"

  @impl true
  def description, do: "Destroy and recreate sandbox container. Use when container is broken."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def execute(_args, %{agent_state: state}) do
    case Orchid.Sandbox.reset(state.id) do
      {:ok, status} -> {:ok, "Sandbox reset. Status: #{inspect(status)}"}
      {:error, reason} -> {:error, "Failed to reset sandbox: #{inspect(reason)}"}
    end
  end

  def execute(_args, _context) do
    {:error, "No agent context available"}
  end
end
