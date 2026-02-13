# Inspect agent state and history
# Usage: elixir --name inspect-$$@127.0.0.1 --cookie "$(cat ~/.erlang.cookie)" priv/scripts/inspect_agent.exs [agent_id]
#   No args: list all agents with summary
#   With agent_id: show full history for that agent

node = :"orchid@127.0.0.1"

unless Node.connect(node) do
  IO.puts("ERROR: Cannot connect to #{node}")
  System.halt(1)
end

rpc = fn mod, fun, args ->
  case :rpc.call(node, mod, fun, args) do
    {:badrpc, reason} ->
      IO.puts("RPC ERROR: #{inspect(reason)}")
      nil
    result -> result
  end
end

agent_id = List.first(System.argv())

if agent_id do
  # Show full agent history
  case rpc.(Orchid.Agent, :get_state, [agent_id]) do
    {:ok, state} ->
      IO.puts("=== Agent #{agent_id} ===")
      IO.puts("Status: #{inspect(state.status)}")
      IO.puts("Provider: #{state.config[:provider]}, Model: #{state.config[:model]}")
      IO.puts("Project: #{state.project_id}")
      IO.puts("Notifications pending: #{length(state.notifications)}")
      IO.puts("")

      IO.puts("=== Messages (#{length(state.messages)}) ===")
      for {msg, i} <- Enum.with_index(state.messages) do
        role = msg.role
        ts = msg[:timestamp]
        ts_str = if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "?"

        case role do
          :user ->
            content = String.slice(msg.content || "", 0, 300) |> String.replace("\n", " ")
            IO.puts("[#{i}] #{ts_str} USER: #{content}")

          :assistant ->
            content = String.slice(msg.content || "", 0, 200) |> String.replace("\n", " ")
            tools = if msg[:tool_calls], do: " -> tools: #{Enum.map_join(msg.tool_calls, ", ", & &1.name)}", else: ""
            IO.puts("[#{i}] #{ts_str} ASSISTANT: #{content}#{tools}")

          :tool ->
            tool_name = msg.content[:tool_name] || "?"
            result = String.slice(msg.content[:content] || "", 0, 200) |> String.replace("\n", " ")
            IO.puts("[#{i}] #{ts_str} TOOL(#{tool_name}): #{result}")
        end
      end

      IO.puts("")
      IO.puts("=== Tool History (#{length(state.tool_history)}) ===")
      for th <- Enum.take(state.tool_history, -10) do
        ts = Calendar.strftime(th.timestamp, "%H:%M:%S")
        args = th.args |> inspect() |> String.slice(0, 100)
        result_preview = case th.result do
          {:ok, v} when is_binary(v) -> String.slice(v, 0, 100) |> String.replace("\n", " ")
          {:ok, v} -> inspect(v) |> String.slice(0, 100)
          {:error, e} -> "ERROR: #{inspect(e) |> String.slice(0, 100)}"
        end
        IO.puts("  #{ts} #{th.tool}(#{args}) -> #{result_preview}")
      end

    {:error, :not_found} ->
      IO.puts("Agent #{agent_id} not found")
  end
else
  # List all agents
  agents = rpc.(Orchid.Agent, :list, [])
  IO.puts("=== Active Agents (#{length(agents)}) ===")

  for id <- agents do
    case rpc.(Orchid.Agent, :get_state, [id]) do
      {:ok, state} ->
        template = case state.config[:template_id] do
          nil -> "?"
          tid ->
            case rpc.(Orchid.Object, :get, [tid]) do
              {:ok, obj} -> obj.name
              _ -> tid
            end
        end

        # Find assigned goal
        goal_name = if state.project_id do
          goals = rpc.(Orchid.Object, :list_goals_for_project, [state.project_id])
          case Enum.find(goals || [], fn g -> g.metadata[:agent_id] == id end) do
            nil -> "none"
            g -> g.name
          end
        else
          "no project"
        end

        msg_count = length(state.messages)
        last_role = case List.last(state.messages) do
          nil -> "none"
          msg -> "#{msg.role}"
        end

        IO.puts("  #{id} [#{inspect(state.status)}] #{template} | #{goal_name} | #{msg_count} msgs (last: #{last_role})")

      _ ->
        IO.puts("  #{id} [state unavailable]")
    end
  end
end
