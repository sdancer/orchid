defmodule Orchid.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # ETS table for lock-free agent state reads (public so Tasks can write)
    :ets.new(:orchid_agent_states, [:named_table, :public, :set, read_concurrency: true])

    children = [
      # ETS-backed storage for objects and agent state
      Orchid.Store,
      # Registry for looking up agents by ID
      {Registry, keys: :unique, name: Orchid.Registry},
      # DynamicSupervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: Orchid.AgentSupervisor},
      # Serialized completion-review queue to avoid reviewer call floods
      Orchid.GoalReviewQueue,
      # PubSub for Phoenix
      {Phoenix.PubSub, name: Orchid.PubSub},
      # Phoenix endpoint
      OrchidWeb.Endpoint,
      # Auto-spawn agents for projects with unattended goals
      Orchid.GoalWatcher
    ]

    opts = [strategy: :one_for_one, name: Orchid.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      Orchid.Seeds.seed_templates()
      {:ok, pid}
    end
  end
end
