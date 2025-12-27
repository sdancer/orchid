defmodule Orchid.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS-backed storage for objects and agent state
      Orchid.Store,
      # Registry for looking up agents by ID
      {Registry, keys: :unique, name: Orchid.Registry},
      # DynamicSupervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor},
      # PubSub for Phoenix
      {Phoenix.PubSub, name: Orchid.PubSub},
      # Phoenix endpoint
      OrchidWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Orchid.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
