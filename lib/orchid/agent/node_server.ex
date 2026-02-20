defmodule Orchid.Agent.NodeServer do
  @moduledoc """
  Hierarchical execution node with a Generate -> Verify -> Revise loop.
  """
  use GenServer
  require Logger

  alias Orchid.Agent.NodeServer.State

  @min_retry_backoff_ms 1_000
  @max_retry_backoff_ms 10_000

  def get_state(pid, timeout \\ 1_000) when is_pid(pid) do
    GenServer.call(pid, :state, timeout)
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :id, make_ref())},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    state = %State{
      id: Keyword.get(opts, :id, default_id()),
      parent_pid: Keyword.get(opts, :parent_pid),
      objective: Keyword.fetch!(opts, :objective),
      depth: Keyword.get(opts, :depth, 0),
      max_depth: Keyword.get(opts, :max_depth, 4),
      llm_config: Keyword.get(opts, :llm_config, %{}),
      tool_context: Keyword.get(opts, :tool_context, %{}),
      planner_module: Keyword.get(opts, :planner_module, Orchid.Agent.Planner),
      verifier_module: Keyword.get(opts, :verifier_module, Orchid.Agent.Verifier),
      reviser_module: Keyword.get(opts, :reviser_module, Orchid.Agent.Reviser),
      tools_module: Keyword.get(opts, :tools_module, Orchid.Agent.Tools),
      node_supervisor: Keyword.get(opts, :node_supervisor, Orchid.Agent.NodeSupervisor)
    }

    send(self(), :generate_plan)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:generate_plan, state) do
    Logger.info("[NodeServer #{state.id}] Generating plan")
    {:noreply, start_generate_async(state)}
  end

  @impl true
  def handle_info(:verify_plan, state) do
    Logger.info(
      "[NodeServer #{state.id}] Verifying plan (tasks=#{length(state.plan)}) #{summarize_plan(state.plan)}"
    )

    {:noreply, start_verify_async(state)}
  end

  @impl true
  def handle_info({:phase_done, token, :generate, result}, state) do
    if token == state.phase_token and state.active_phase == :generate do
      case normalize_generate_result(result) do
        {:ok, plan} ->
          send(self(), :verify_plan)

          {:noreply,
           %{state | plan: plan, status: :verifying, active_phase: nil, planner_retry_count: 0}}

        {:error, reason} ->
          retry_count = state.planner_retry_count
          backoff_ms = retry_backoff_ms(retry_count)

          Logger.warning(
            "[NodeServer #{state.id}] Planner failed; backing off #{backoff_ms}ms (retry #{retry_count + 1}): #{inspect(reason)}"
          )

          Process.send_after(self(), :generate_plan, backoff_ms)

          {:noreply,
           %{state | status: :replanning, active_phase: nil, planner_retry_count: retry_count + 1}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:phase_done, token, :verify, verdict}, state) do
    if token == state.phase_token and state.active_phase == :verify do
      case verdict do
        {:approved, _reason} ->
          send(self(), :execute_next)

          {:noreply,
           %{
             state
             | pending_tasks: state.plan,
               status: :executing,
               active_phase: nil,
               verifier_retry_count: 0
           }}

        {:flawed, critique} ->
          retry_count = state.verifier_retry_count
          backoff_ms = retry_backoff_ms(retry_count)

          Logger.warning(
            "[NodeServer #{state.id}] Verifier requested retry; backing off #{backoff_ms}ms (retry #{retry_count + 1})"
          )

          Process.send_after(self(), {:retry_revise, critique}, backoff_ms)

          {:noreply,
           %{
             state
             | status: :replanning,
               active_phase: nil,
               verifier_retry_count: retry_count + 1
           }}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:retry_revise, critique}, state) do
    {:noreply, start_revise_async(state, critique)}
  end

  @impl true
  def handle_info({:phase_done, token, :revise, revised_plan}, state) do
    if token == state.phase_token and state.active_phase == :revise do
      send(self(), :verify_plan)
      {:noreply, %{state | plan: revised_plan, status: :replanning, active_phase: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:execute_next, %State{pending_tasks: []} = state) do
    Logger.info("[NodeServer #{state.id}] All tasks completed")
    maybe_report_success(state)
    {:stop, :normal, state}
  end

  def handle_info(:execute_next, %State{pending_tasks: [task | remaining]} = state) do
    state = %{state | pending_tasks: remaining, current_task: task}

    case task_type(task) do
      :delegate ->
        delegate_task(task, state)

      :tool ->
        execute_tool_task(task, state)

      _ ->
        send(self(), {:child_failed, task_id(task), "Invalid task type", %{task: task}})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:child_success, task_id, result}, state) do
    completed = state.completed_tasks ++ [%{task_id: task_id, result: result}]
    send(self(), :execute_next)
    {:noreply, %{state | completed_tasks: completed, current_task: nil}}
  end

  @impl true
  def handle_info({:child_failed, task_id, failure_reason, context}, state) do
    Logger.error(
      "[NodeServer #{state.id}] Task #{task_id} failed: #{failure_reason} (#{inspect(context)})"
    )

    replanning_context = """
    We were trying to achieve: #{state.objective}.
    We successfully completed: #{inspect(state.completed_tasks)}.
    We attempted task '#{task_id}' but it failed because: #{failure_reason}.
    Additional context: #{inspect(context)}.
    Generate a new plan from this exact state, avoiding the failed route.
    """

    send(self(), :generate_plan)

    {:noreply,
     %{
       state
       | objective: String.trim(replanning_context),
         pending_tasks: [],
         plan: [],
         current_task: nil,
         status: :replanning,
         active_phase: nil
     }}
  end

  defp delegate_task(task, state) do
    if state.depth >= state.max_depth do
      send(
        self(),
        {:child_failed, task_id(task), "Max delegation depth reached",
         %{depth: state.depth, max_depth: state.max_depth}}
      )

      {:noreply, state}
    else
      child_opts = [
        parent_pid: self(),
        objective: task_objective(task),
        depth: state.depth + 1,
        max_depth: state.max_depth,
        llm_config: state.llm_config,
        tool_context: state.tool_context,
        planner_module: state.planner_module,
        verifier_module: state.verifier_module,
        reviser_module: state.reviser_module,
        tools_module: state.tools_module,
        node_supervisor: state.node_supervisor
      ]

      case DynamicSupervisor.start_child(state.node_supervisor, {__MODULE__, child_opts}) do
        {:ok, child_pid} ->
          Logger.info(
            "[NodeServer #{state.id}] Delegated task #{task_id(task)} to #{inspect(child_pid)}"
          )

          {:noreply, state}

        {:error, reason} ->
          send(
            self(),
            {:child_failed, task_id(task), "Delegation failed", %{reason: inspect(reason)}}
          )

          {:noreply, state}
      end
    end
  end

  defp execute_tool_task(task, state) do
    case state.tools_module.execute(task, state.tool_context) do
      {:ok, result} ->
        send(self(), {:child_success, task_id(task), result})
        {:noreply, state}

      {:error, failure_reason, context} ->
        send(self(), {:child_failed, task_id(task), failure_reason, context})
        {:noreply, state}
    end
  end

  defp maybe_report_success(%State{parent_pid: nil}), do: :ok

  defp maybe_report_success(%State{parent_pid: parent, id: id, completed_tasks: completed}) do
    send(parent, {:child_success, id, completed})
  end

  defp task_id(task), do: task[:id] || task["id"] || "unknown_task"

  defp task_objective(task),
    do: task[:objective] || task["objective"] || "Complete delegated task"

  defp task_type(task) do
    case task[:type] || task["type"] do
      :delegate -> :delegate
      :tool -> :tool
      "delegate" -> :delegate
      "tool" -> :tool
      _ -> :unknown
    end
  end

  defp default_id do
    "node_#{System.unique_integer([:positive])}"
  end

  defp start_generate_async(state) do
    token = state.phase_token + 1
    owner = self()

    Task.start(fn ->
      plan =
        state.planner_module.decompose(state.objective, state.completed_tasks, state.llm_config)

      send(owner, {:phase_done, token, :generate, plan})
    end)

    %{state | phase_token: token, active_phase: :generate, status: :planning}
  end

  defp start_verify_async(state) do
    token = state.phase_token + 1
    owner = self()

    Task.start(fn ->
      verdict = state.verifier_module.critique(state.objective, state.plan, state.llm_config)
      send(owner, {:phase_done, token, :verify, verdict})
    end)

    %{state | phase_token: token, active_phase: :verify, status: :verifying}
  end

  defp start_revise_async(state, critique) do
    token = state.phase_token + 1
    owner = self()

    Task.start(fn ->
      revised_plan =
        state.reviser_module.fix(state.plan, critique, state.objective, state.llm_config)

      send(owner, {:phase_done, token, :revise, revised_plan})
    end)

    %{state | phase_token: token, active_phase: :revise, status: :replanning}
  end

  defp retry_backoff_ms(retry_count) when is_integer(retry_count) and retry_count >= 0 do
    delay = trunc(@min_retry_backoff_ms * :math.pow(2, retry_count))
    min(delay, @max_retry_backoff_ms)
  end

  defp normalize_generate_result({:error, reason}), do: {:error, reason}

  defp normalize_generate_result(plan) when is_list(plan) do
    if plan == [], do: {:error, :empty_plan}, else: {:ok, plan}
  end

  defp normalize_generate_result(other), do: {:error, {:invalid_plan_result, other}}

  defp summarize_plan(plan) when is_list(plan) do
    ids =
      plan
      |> Enum.take(5)
      |> Enum.map(fn task -> task[:id] || task["id"] || "unknown" end)
      |> Enum.join(", ")

    if ids == "", do: "", else: "[#{ids}]"
  end
end
