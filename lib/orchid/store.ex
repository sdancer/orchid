defmodule Orchid.Store do
  @moduledoc """
  ETS-backed storage for objects and agent state.
  Provides fast in-memory persistence with future LMDB support.
  """
  use GenServer

  @objects_table :orchid_objects
  @agents_table :orchid_agents

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Object operations
  def put_object(object) do
    :ets.insert(@objects_table, {object.id, object})
    :ok
  end

  def get_object(id) do
    case :ets.lookup(@objects_table, id) do
      [{^id, object}] -> {:ok, object}
      [] -> {:error, :not_found}
    end
  end

  def delete_object(id) do
    :ets.delete(@objects_table, id)
    :ok
  end

  def list_objects do
    :ets.tab2list(@objects_table)
    |> Enum.map(fn {_id, object} -> object end)
  end

  # Agent state operations
  def put_agent_state(agent_id, state) do
    :ets.insert(@agents_table, {agent_id, state})
    :ok
  end

  def get_agent_state(agent_id) do
    case :ets.lookup(@agents_table, agent_id) do
      [{^agent_id, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  def delete_agent_state(agent_id) do
    :ets.delete(@agents_table, agent_id)
    :ok
  end

  def list_agent_states do
    :ets.tab2list(@agents_table)
    |> Enum.map(fn {_id, state} -> state end)
  end

  # GenServer callbacks
  @impl true
  def init(_opts) do
    :ets.new(@objects_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@agents_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
