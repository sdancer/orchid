defmodule Orchid.Tools.Wait do
  @moduledoc "Wait for notifications from spawned agents"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "wait"

  @impl true
  def description,
    do:
      "Wait up to N seconds for notifications from spawned agents. Returns immediately when notifications arrive. Use this after spawning agents to wait for their completion reports."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        seconds: %{
          type: "integer",
          description: "Maximum seconds to wait (1-300)"
        }
      },
      required: ["seconds"]
    }
  end

  @impl true
  def execute(%{"seconds" => seconds}, %{agent_state: state}) do
    max_wait = min(max(seconds, 1), 300)
    deadline = System.monotonic_time(:second) + max_wait
    wait_loop(state.id, deadline)
  end

  def execute(_args, %{agent_state: state}) do
    # Default 60s if no seconds provided
    deadline = System.monotonic_time(:second) + 60
    wait_loop(state.id, deadline)
  end

  defp wait_loop(agent_id, deadline) do
    case Orchid.Agent.drain_notifications(agent_id) do
      {:ok, []} ->
        if System.monotonic_time(:second) < deadline do
          Process.sleep(2_000)
          wait_loop(agent_id, deadline)
        else
          {:ok, "No notifications received within timeout."}
        end

      {:ok, notifications} ->
        tool_result = %{
          tool_use_id: nil,
          tool_name: "wait",
          content: "Received #{length(notifications)} notification(s)."
        }

        {:notifications, notifications, tool_result}
    end
  end
end
