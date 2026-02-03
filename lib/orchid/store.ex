defmodule Orchid.Store do
  @moduledoc """
  CubDB-backed persistent storage for objects and agent state.
  Provides ACID-compliant, crash-safe persistence.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Object operations
  def put_object(object) do
    GenServer.call(__MODULE__, {:put_object, object})
  end

  def get_object(id) do
    GenServer.call(__MODULE__, {:get_object, id})
  end

  def delete_object(id) do
    GenServer.call(__MODULE__, {:delete_object, id})
  end

  def list_objects do
    GenServer.call(__MODULE__, :list_objects)
  end

  # Agent state operations
  def put_agent_state(agent_id, state) do
    GenServer.call(__MODULE__, {:put_agent_state, agent_id, state})
  end

  def get_agent_state(agent_id) do
    GenServer.call(__MODULE__, {:get_agent_state, agent_id})
  end

  def delete_agent_state(agent_id) do
    GenServer.call(__MODULE__, {:delete_agent_state, agent_id})
  end

  def list_agent_states do
    GenServer.call(__MODULE__, :list_agent_states)
  end

  # GenServer callbacks
  @impl true
  def init(_opts) do
    data_dir = Application.get_env(:orchid, :data_dir, "priv/data")

    objects_dir = Path.join(data_dir, "objects")
    agents_dir = Path.join(data_dir, "agents")

    File.mkdir_p!(objects_dir)
    File.mkdir_p!(agents_dir)

    {:ok, objects_db} = CubDB.start_link(data_dir: objects_dir)
    {:ok, agents_db} = CubDB.start_link(data_dir: agents_dir)

    {:ok, %{objects_db: objects_db, agents_db: agents_db}}
  end

  @impl true
  def handle_call({:put_object, object}, _from, state) do
    CubDB.put(state.objects_db, object.id, object)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_object, id}, _from, state) do
    result =
      case CubDB.get(state.objects_db, id) do
        nil -> {:error, :not_found}
        object -> {:ok, object}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_object, id}, _from, state) do
    CubDB.delete(state.objects_db, id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_objects, _from, state) do
    objects =
      CubDB.select(state.objects_db)
      |> Enum.map(fn {_id, object} -> object end)

    {:reply, objects, state}
  end

  @impl true
  def handle_call({:put_agent_state, agent_id, agent_state}, _from, state) do
    CubDB.put(state.agents_db, agent_id, agent_state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_agent_state, agent_id}, _from, state) do
    result =
      case CubDB.get(state.agents_db, agent_id) do
        nil -> {:error, :not_found}
        agent_state -> {:ok, agent_state}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_agent_state, agent_id}, _from, state) do
    CubDB.delete(state.agents_db, agent_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_agent_states, _from, state) do
    agent_states =
      CubDB.select(state.agents_db)
      |> Enum.map(fn {_id, agent_state} -> agent_state end)

    {:reply, agent_states, state}
  end
end
