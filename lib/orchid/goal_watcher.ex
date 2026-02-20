defmodule Orchid.GoalWatcher do
  @moduledoc """
  Periodically checks for projects that have pending goals but no running agents.
  Executes ready root goals with NodeServer when no project agents are active.
  Also detects dead agents (assigned to goals but no longer running) and
  re-kicks idle agents that still have unfinished work.
  """
  use GenServer
  require Logger
  alias Orchid.LLM
  alias Orchid.Goals

  @interval :timer.seconds(10)
  @log_file "priv/data/goal_watcher.log"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Don't re-kick an agent more than once per cooldown period
  @re_kick_cooldown :timer.minutes(5)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Path.dirname(@log_file))
    log("started, checking every #{div(@interval, 1000)}s")
    schedule()
    # kicked_agents: %{agent_id => last_kick_time}
    # node_runs: %{goal_id => %{pid: pid, monitor_ref: ref, project_id: project_id}}
    {:ok, %{kicked_agents: %{}, node_runs: %{}}}
  end

  @impl true
  def handle_info({:child_success, goal_id, completed_tasks}, state) when is_binary(goal_id) do
    state = finish_node_goal(goal_id, completed_tasks, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.node_runs, fn {_goal_id, run} -> run.monitor_ref == ref end) do
      nil ->
        {:noreply, state}

      {goal_id, _run} ->
        state = handle_node_down(goal_id, reason, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check, state) do
    state =
      try do
        check_projects(state)
      rescue
        e ->
          log(
            "CRASH in check_projects: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          state
      catch
        kind, reason ->
          log("CRASH in check_projects: #{inspect(kind)} #{inspect(reason)}")
          state
      end

    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :check, @interval)
  end

  defp check_projects(state) do
    state = cleanup_dead_node_runs(state)
    projects = Orchid.Object.list_projects()
    running_agent_ids = MapSet.new(Orchid.Agent.list())

    # Build map of running agent states keyed by project_id
    agent_states =
      running_agent_ids
      |> Enum.reduce(%{}, fn id, acc ->
        case Orchid.Agent.get_state(id, 2000) do
          {:ok, agent_state} when not is_nil(agent_state.project_id) ->
            Map.update(acc, agent_state.project_id, [agent_state], &[agent_state | &1])

          _ ->
            acc
        end
      end)

    Enum.reduce(projects, state, fn project, acc_state ->
      if project.metadata[:status] in [nil, :active] do
        goals = Orchid.Object.list_goals_for_project(project.id)
        pending = Enum.filter(goals, fn g -> g.metadata[:status] != :completed end)

        if pending != [] do
          project_agents = Map.get(agent_states, project.id, [])
          handle_project(project, pending, project_agents, running_agent_ids, acc_state)
        else
          acc_state
        end
      else
        acc_state
      end
    end)
  end

  defp handle_project(project, pending_goals, project_agents, running_agent_ids, state) do
    # 1. Clean up goals assigned to dead agents
    orphaned =
      Enum.filter(pending_goals, fn g ->
        aid = g.metadata[:agent_id]
        aid != nil and aid not in running_agent_ids
      end)

    if orphaned != [] do
      log(
        "project \"#{project.name}\": #{length(orphaned)} goal(s) assigned to dead agents — clearing assignments"
      )

      for goal <- orphaned do
        Orchid.Object.update_metadata(goal.id, %{agent_id: nil})
        log("  cleared dead agent from goal \"#{goal.name}\" [#{goal.id}]")
      end
    end

    # Clean dead agents from kicked tracking
    state = %{
      state
      | kicked_agents:
          Map.reject(state.kicked_agents, fn {id, _} -> id not in running_agent_ids end)
    }

    # 2. No agents at all -> execute ready root goals with NodeServer
    if project_agents == [] do
      run_root_nodes(project, state)
    else
      # 3. Has idle agents with pending assigned goals → re-kick (with cooldown)
      re_kick_idle_agents(project, project_agents, state)
    end
  end

  defp run_root_nodes(project, state) do
    root_goals =
      project.id
      |> Goals.list_ready_root_goals()
      |> Enum.reject(fn g -> Map.has_key?(state.node_runs, g.id) end)

    if root_goals == [] do
      state
    else
      log(
        "project \"#{project.name}\" has #{length(root_goals)} ready root goal(s), 0 agents — starting NodeServer"
      )

      case Orchid.Projects.ensure_sandbox(project.id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          log("WARNING: sandbox failed for project \"#{project.name}\": #{inspect(reason)}")
      end

      Enum.reduce(root_goals, state, fn goal, acc ->
        start_root_node(project, goal, acc)
      end)
    end
  end

  defp start_root_node(project, goal, state) do
    objective = root_goal_objective(goal)

    tool_context = %{
      agent_state: %{
        id: "node_#{goal.id}",
        project_id: project.id,
        execution_mode: :vm,
        sandbox: Orchid.Sandbox.status(project.id),
        config: %{}
      }
    }

    opts = [
      id: goal.id,
      parent_pid: self(),
      objective: objective,
      tool_context: tool_context
    ]

    case DynamicSupervisor.start_child(
           Orchid.Agent.NodeSupervisor,
           {Orchid.Agent.NodeServer, opts}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Orchid.Object.update_metadata(goal.id, %{status: :in_progress, node_pid: inspect(pid)})
        log("  started node for root goal \"#{goal.name}\" [#{goal.id}] pid=#{inspect(pid)}")
        put_in(state.node_runs[goal.id], %{pid: pid, monitor_ref: ref, project_id: project.id})

      {:error, reason} ->
        log(
          "ERROR: failed to start node for goal \"#{goal.name}\" [#{goal.id}]: #{inspect(reason)}"
        )

        state
    end
  end

  defp re_kick_idle_agents(project, project_agents, state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(project_agents, state, fn agent_state, acc_state ->
      if agent_state.status != :idle do
        acc_state
      else
        last_kick = Map.get(acc_state.kicked_agents, agent_state.id)

        if last_kick && now - last_kick < @re_kick_cooldown do
          acc_state
        else
          goals = Orchid.Object.list_goals_for_project(project.id)

          assigned_pending =
            Enum.filter(goals, fn g ->
              g.metadata[:agent_id] == agent_state.id and g.metadata[:status] != :completed
            end)

          if assigned_pending != [] do
            goal_names = Enum.map_join(assigned_pending, ", ", & &1.name)
            tag = agent_tag(agent_state)
            last_role = List.last(agent_state.messages) && List.last(agent_state.messages).role

            if last_role in [:user, :tool] do
              log(
                "agent #{agent_state.id} (#{tag}) idle, last msg=#{last_role}, goals: #{goal_names} — retrying"
              )

              Task.start(fn ->
                case Orchid.Agent.retry(agent_state.id) do
                  {:ok, response} ->
                    preview = response |> String.slice(0, 200) |> String.replace("\n", " ")
                    log("agent #{agent_state.id} (#{tag}) retry responded: #{preview}")

                  {:error, reason} ->
                    log(
                      "ERROR: agent #{agent_state.id} (#{tag}) retry failed: #{inspect(reason)}"
                    )
                end
              end)
            else
              log("agent #{agent_state.id} (#{tag}) idle, goals: #{goal_names} — re-kicking")

              Task.start(fn ->
                message = build_rekick_message(agent_state, assigned_pending)

                case Orchid.Agent.stream(agent_state.id, message, fn _chunk -> :ok end) do
                  {:ok, response} ->
                    preview = response |> String.slice(0, 200) |> String.replace("\n", " ")
                    log("agent #{agent_state.id} (#{tag}) re-kick responded: #{preview}")

                  {:error, reason} ->
                    log(
                      "ERROR: agent #{agent_state.id} (#{tag}) re-kick failed: #{inspect(reason)}"
                    )
                end
              end)
            end

            %{acc_state | kicked_agents: Map.put(acc_state.kicked_agents, agent_state.id, now)}
          else
            acc_state
          end
        end
      end
    end)
  end

  # Short tag for log lines: "TemplateName/provider"
  defp agent_tag(agent_state) do
    provider = agent_state.config[:provider] || "?"
    model = agent_state.config[:model]

    tname =
      case agent_state.config[:template_id] do
        nil ->
          nil

        tid ->
          case Orchid.Object.get(tid) do
            {:ok, t} -> t.name
            _ -> nil
          end
      end

    tname || "#{provider}#{if model, do: "/#{model}", else: ""}"
  end

  defp finish_node_goal(goal_id, completed_tasks, state) do
    case Map.pop(state.node_runs, goal_id) do
      {nil, _remaining} ->
        state

      {run, remaining} ->
        Process.demonitor(run.monitor_ref, [:flush])
        report = node_report(completed_tasks)

        _ =
          Orchid.Object.update_metadata(goal_id, %{
            completion_summary: "Completed by NodeServer",
            report: report,
            task_outcome: "success",
            reported_by_tool: false,
            reported_at: DateTime.utc_now(),
            node_pid: nil
          })

        _ = Goals.set_status(goal_id, :completed)
        log("node completed root goal [#{goal_id}]")
        %{state | node_runs: remaining}
    end
  end

  defp handle_node_down(goal_id, reason, state) do
    case Map.pop(state.node_runs, goal_id) do
      {nil, _remaining} ->
        state

      {run, remaining} ->
        Process.demonitor(run.monitor_ref, [:flush])

        if reason != :normal do
          _ =
            Orchid.Object.update_metadata(goal_id, %{
              status: :pending,
              last_error: "NodeServer exited: #{inspect(reason)}",
              node_pid: nil
            })

          log("node exited abnormally for goal [#{goal_id}]: #{inspect(reason)}")
        end

        %{state | node_runs: remaining}
    end
  end

  defp cleanup_dead_node_runs(state) do
    Enum.reduce(state.node_runs, state, fn {goal_id, run}, acc ->
      if Process.alive?(run.pid) do
        acc
      else
        %{acc | node_runs: Map.delete(acc.node_runs, goal_id)}
      end
    end)
  end

  defp root_goal_objective(goal) do
    details =
      if is_binary(goal.content) and String.trim(goal.content) != "" do
        "\n\nDetails:\n#{goal.content}"
      else
        ""
      end

    "Execute root goal: #{goal.name} (#{goal.id})#{details}"
  end

  defp node_report(completed_tasks) do
    lines =
      Enum.map(completed_tasks, fn entry ->
        task_id = entry[:task_id] || "unknown_task"
        result = entry[:result]
        "- #{task_id}: #{inspect(result)}"
      end)

    Enum.join(lines, "\n")
  end

  defp log(msg) do
    ts = DateTime.utc_now() |> DateTime.to_string()
    line = "[#{ts}] GoalWatcher: #{msg}\n"
    File.write!(@log_file, line, [:append])
    Logger.info("GoalWatcher: #{msg}")
  end

  defp build_rekick_message(agent_state, assigned_pending) do
    goal_names = Enum.map_join(assigned_pending, ", ", & &1.name)
    assistant_msg = last_assistant_message(agent_state)

    case summarize_last_update(assistant_msg, assigned_pending) do
      {:ok, %{status: status, summary: summary, error: error}} ->
        """
        Review of your last update (Sonnet):
        - Status: #{status}
        - Summary: #{summary}
        #{if(error, do: "- Error: #{error}", else: "")}

        Pending goals: #{goal_names}

        If work is complete, call `task_report` with `outcome: "success"` and include a concise report.
        If blocked, continue execution and report the exact failing command/output.
        """
        |> String.trim()

      _ ->
        "Pending goals: #{goal_names}. Continue execution and report exact command/output for progress or blockers."
    end
  end

  defp summarize_last_update(last_msg, goals) do
    goal_text =
      goals
      |> Enum.map(fn g -> "- #{g.name}: #{g.content || ""}" end)
      |> Enum.join("\n")

    system = """
    You summarize worker status for orchestration.
    Return exactly one JSON object in a single response. Do not call tools.
    Return strict JSON only with keys:
    - status: one of "completed", "error", "in_progress", "unknown"
    - summary: short string (<= 220 chars)
    - error: string or null
    Be conservative.
    """

    user = """
    Goals:
    #{goal_text}

    Last assistant message:
    #{truncate(last_msg || "(none)", 6000)}
    """

    context = %{
      system: system,
      messages: [%{role: :user, content: String.trim(user)}],
      objects: "",
      memory: %{}
    }

    config = %{provider: :cli, model: :sonnet, max_turns: 8, max_tokens: 500, disable_tools: true}

    with {:ok, %{content: raw}} <- LLM.chat(config, context),
         {:ok, parsed} <- parse_summary_json(raw) do
      {:ok, parsed}
    end
  end

  defp parse_summary_json(raw) when is_binary(raw) do
    parsed =
      case Jason.decode(raw) do
        {:ok, v} ->
          v

        _ ->
          case Regex.run(~r/\{.*\}/s, raw) do
            [json] ->
              case Jason.decode(json) do
                {:ok, v} -> v
                _ -> nil
              end

            _ ->
              nil
          end
      end

    case parsed do
      %{"status" => status, "summary" => summary} when is_binary(status) and is_binary(summary) ->
        normalized =
          case status do
            "completed" -> "completed"
            "error" -> "error"
            "in_progress" -> "in_progress"
            _ -> "unknown"
          end

        err =
          case Map.get(parsed, "error") do
            e when is_binary(e) and e != "" -> e
            _ -> nil
          end

        {:ok, %{status: normalized, summary: truncate(summary, 220), error: err}}

      _ ->
        {:error, :invalid_summary}
    end
  end

  defp last_assistant_message(agent_state) do
    agent_state.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :assistant end)
    |> case do
      nil -> nil
      msg -> msg.content
    end
  end

  defp truncate(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
