defmodule Orchid.McpEvents do
  @moduledoc """
  In-memory store and PubSub broadcaster for MCP tool-call events.
  """
  use GenServer

  @topic "mcp_calls"
  @max_events 500

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def record_call(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:record_call, event})
  end

  def list_recent(project_id, limit \\ 40, timeout \\ 250) do
    GenServer.call(__MODULE__, {:list_recent, project_id, limit}, timeout)
  end

  @impl true
  def init(:ok) do
    {:ok, %{events: []}}
  end

  @impl true
  def handle_cast({:record_call, event}, state) do
    normalized =
      event
      |> Map.put_new(:inserted_at, DateTime.utc_now())
      |> Map.put_new(:agent_id, nil)
      |> Map.put_new(:project_id, nil)
      |> Map.put_new(:tool, "unknown")
      |> Map.put_new(:outcome, "unknown")
      |> Map.put_new(:duration_ms, nil)
      |> Map.put_new(:request_id, nil)

    Phoenix.PubSub.broadcast(Orchid.PubSub, @topic, {:mcp_call, normalized})

    events =
      [normalized | state.events]
      |> Enum.take(@max_events)

    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_call({:list_recent, project_id, limit}, _from, state) do
    events =
      state.events
      |> Enum.filter(fn e -> is_nil(project_id) or e.project_id == project_id end)
      |> Enum.take(limit)

    {:reply, events, state}
  end
end
