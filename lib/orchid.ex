defmodule Orchid do
  @moduledoc """
  Orchid - LLM Agent Orchestration Framework

  Manages multiple LLM coding agents with full context tracking,
  object-based editing, and REPL-like evaluation.
  """

  alias Orchid.{Agent, Object}

  # Delegate agent operations
  defdelegate create_agent(config), to: Agent, as: :create
  defdelegate run(agent_id, message), to: Agent
  defdelegate stream(agent_id, message, callback), to: Agent
  defdelegate get_state(agent_id), to: Agent
  defdelegate list_agents(), to: Agent, as: :list
  defdelegate stop_agent(agent_id), to: Agent, as: :stop
  defdelegate attach(agent_id, object_ids), to: Agent

  # Delegate object operations
  defdelegate create_object(type, name, content, opts \\ []), to: Object, as: :create
  defdelegate get_object(id), to: Object, as: :get
  defdelegate update_object(id, content), to: Object, as: :update
  defdelegate delete_object(id), to: Object, as: :delete
  defdelegate eval_object(id), to: Object, as: :eval
  defdelegate list_objects(), to: Object, as: :list
end
