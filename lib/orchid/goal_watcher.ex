defmodule Orchid.GoalWatcher do
  @moduledoc """
  Periodically checks for projects that have pending goals but no running agents.
  Spawns a Planner agent per project to orchestrate goals.
  Also detects dead agents (assigned to goals but no longer running) and
  re-kicks idle agents that still have unfinished work.
  """
  use GenServer
  require Logger

  @interval :timer.seconds(10)
  @log_file "priv/data/goal_watcher.log"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    File.mkdir_p!(Path.dirname(@log_file))
    log("started, checking every #{div(@interval, 1000)}s")
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_projects()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :check, @interval)
  end

  defp check_projects do
    projects = Orchid.Object.list_projects()
    running_agent_ids = MapSet.new(Orchid.Agent.list())

    # Build map of running agent states keyed by project_id
    agent_states =
      running_agent_ids
      |> Enum.reduce(%{}, fn id, acc ->
        case Orchid.Agent.get_state(id, 2000) do
          {:ok, state} when not is_nil(state.project_id) ->
            Map.update(acc, state.project_id, [state], &[state | &1])

          _ ->
            acc
        end
      end)

    for project <- projects,
        project.metadata[:status] in [nil, :active] do
      goals = Orchid.Object.list_goals_for_project(project.id)
      pending = Enum.filter(goals, fn g -> g.metadata[:status] != :completed end)

      if pending != [] do
        project_agents = Map.get(agent_states, project.id, [])
        handle_project(project, pending, project_agents, running_agent_ids)
      end
    end
  end

  defp handle_project(project, pending_goals, project_agents, running_agent_ids) do
    # 1. Clean up goals assigned to dead agents
    orphaned =
      Enum.filter(pending_goals, fn g ->
        aid = g.metadata[:agent_id]
        aid != nil and aid not in running_agent_ids
      end)

    if orphaned != [] do
      log("project \"#{project.name}\": #{length(orphaned)} goal(s) assigned to dead agents — clearing assignments")

      for goal <- orphaned do
        Orchid.Object.update_metadata(goal.id, %{agent_id: nil})
        log("  cleared dead agent from goal \"#{goal.name}\" [#{goal.id}]")
      end
    end

    # 2. No agents at all → spawn planner
    if project_agents == [] do
      # Re-fetch pending goals with cleared assignments
      pending =
        if orphaned != [] do
          Orchid.Object.list_goals_for_project(project.id)
          |> Enum.filter(fn g -> g.metadata[:status] != :completed end)
        else
          pending_goals
        end

      log("project \"#{project.name}\" has #{length(pending)} pending goal(s), 0 agents — spawning planner")
      spawn_planner(project, pending)
    else
      # 3. Has idle agents with pending assigned goals → re-kick
      re_kick_idle_agents(project, project_agents)
    end
  end

  defp re_kick_idle_agents(project, project_agents) do
    for agent_state <- project_agents,
        agent_state.status == :idle do
      # Check if this agent has pending goals assigned to it
      goals = Orchid.Object.list_goals_for_project(project.id)

      assigned_pending =
        Enum.filter(goals, fn g ->
          g.metadata[:agent_id] == agent_state.id and g.metadata[:status] != :completed
        end)

      if assigned_pending != [] do
        goal_names = Enum.map_join(assigned_pending, ", ", & &1.name)

        log(
          "project \"#{project.name}\": agent #{agent_state.id} is idle with #{length(assigned_pending)} pending goal(s) (#{goal_names}) — re-kicking"
        )

        message = """
        You still have pending goals assigned to you. Resume work.
        Use `goal_list` to see current state, then continue executing.
        """

        Task.start(fn ->
          result =
            Orchid.Agent.stream(agent_state.id, String.trim(message), fn _chunk -> :ok end)

          case result do
            {:ok, response} ->
              preview = response |> String.slice(0, 200) |> String.replace("\n", " ")
              log("re-kick agent #{agent_state.id} responded: #{preview}")

            {:error, reason} ->
              log("ERROR: re-kick agent #{agent_state.id} failed: #{inspect(reason)}")
          end
        end)
      end
    end
  end

  defp spawn_planner(project, pending_goals) do
    case find_planner_template() do
      nil ->
        log("ERROR: no Planner template found, skipping project \"#{project.name}\"")

      planner ->
        # Build goal summary for system prompt interpolation
        goal_summary =
          pending_goals
          |> Enum.map(fn g ->
            deps = g.metadata[:depends_on] || []
            dep_str = if deps == [], do: "", else: " (depends on: #{Enum.join(deps, ", ")})"
            desc_str = if g.content != "", do: "\n  #{g.content}", else: ""
            "- #{g.name} [#{g.id}]#{dep_str}#{desc_str}"
          end)
          |> Enum.join("\n")

        # Substitute placeholders in the template system prompt
        system_prompt =
          planner.content
          |> String.replace("{project name}", project.name)
          |> String.replace("{goals list}", goal_summary)

        config = %{
          model: planner.metadata[:model] || :opus,
          provider: planner.metadata[:provider] || :cli,
          system_prompt: system_prompt,
          template_id: planner.id,
          project_id: project.id
        }

        case Orchid.Agent.create(config) do
          {:ok, agent_id} ->
            log("spawned planner #{agent_id} for project \"#{project.name}\"")

            # Assign all unassigned goals to this planner
            for goal <- pending_goals, is_nil(goal.metadata[:agent_id]) do
              Orchid.Object.update_metadata(goal.id, %{agent_id: agent_id})
              log("  assigned goal \"#{goal.name}\" [#{goal.id}] -> #{agent_id}")
            end

            message = """
            Begin your Standard Operating Procedure now. Inspect the workspace, synchronize with the goal registry, and execute.
            """

            Task.start(fn ->
              log("streaming kickoff to #{agent_id}...")

              result =
                Orchid.Agent.stream(agent_id, String.trim(message), fn _chunk -> :ok end)

              case result do
                {:ok, response} ->
                  preview = response |> String.slice(0, 200) |> String.replace("\n", " ")
                  log("agent #{agent_id} responded: #{preview}")

                {:error, reason} ->
                  log("ERROR: agent #{agent_id} stream failed: #{inspect(reason)}")
              end
            end)

            log("sent kickoff message to #{agent_id}")

          {:error, reason} ->
            log("ERROR: failed to spawn agent for \"#{project.name}\": #{inspect(reason)}")
        end
    end
  end

  defp find_planner_template do
    Orchid.Object.list_agent_templates()
    |> Enum.find(fn t -> t.name == "Planner" end)
  end

  defp log(msg) do
    ts = DateTime.utc_now() |> DateTime.to_string()
    line = "[#{ts}] GoalWatcher: #{msg}\n"
    File.write!(@log_file, line, [:append])
    Logger.info("GoalWatcher: #{msg}")
  end
end
