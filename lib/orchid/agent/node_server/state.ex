defmodule Orchid.Agent.NodeServer.State do
  @moduledoc """
  State for a decomposition node in the Aletheia execution hierarchy.
  """

  @type task :: map()

  defstruct [
    :id,
    :parent_pid,
    :objective,
    :current_task,
    :llm_config,
    :tool_context,
    :planner_module,
    :verifier_module,
    :reviser_module,
    :tools_module,
    :node_supervisor,
    :active_phase,
    plan: [],
    pending_tasks: [],
    completed_tasks: [],
    status: :init,
    depth: 0,
    max_depth: 10,
    phase_token: 0,
    verifier_retry_count: 0,
    planner_retry_count: 0
  ]
end
