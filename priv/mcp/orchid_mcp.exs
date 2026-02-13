#!/usr/bin/env elixir
# Orchid MCP Server — exposes Orchid tools to Claude CLI via MCP protocol (stdio JSON-RPC)
#
# Usage: elixir --name mcp-<PID>@127.0.0.1 --cookie <cookie> priv/mcp/orchid_mcp.exs <project_id> [agent_id]

defmodule OrchidMCP do
  @node :"orchid@127.0.0.1"

  def main(args) do
    project_id = Enum.at(args, 0)
    agent_id = Enum.at(args, 1)

    unless project_id do
      IO.puts(:stderr, "Usage: orchid_mcp.exs <project_id> [agent_id]")
      System.halt(1)
    end

    unless Node.connect(@node) do
      IO.puts(:stderr, "ERROR: cannot connect to #{@node}")
      System.halt(1)
    end

    IO.puts(:stderr, "OrchidMCP: connected to #{@node}, project=#{project_id}")

    state = %{project_id: project_id, agent_id: agent_id}
    loop(state)
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _} -> :ok
      line ->
        line = String.trim(line)
        if line != "" do
          case Jason.decode(line) do
            {:ok, msg} ->
              response = handle_message(msg, state)
              if response do
                IO.write(:stdio, Jason.encode!(response) <> "\n")
              end
            {:error, _} ->
              :skip
          end
        end
        loop(state)
    end
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg, state) do
    result = handle_method(method, msg["params"] || %{}, state)
    case result do
      {:ok, r} -> %{jsonrpc: "2.0", id: id, result: r}
      {:error, code, message} -> %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  # Notifications (no id)
  defp handle_message(%{"jsonrpc" => "2.0", "method" => "notifications/" <> _}, _state), do: nil
  defp handle_message(_, _state), do: nil

  defp handle_method("initialize", _params, _state) do
    {:ok, %{
      protocolVersion: "2024-11-05",
      capabilities: %{tools: %{}},
      serverInfo: %{name: "orchid-mcp", version: "1.0.0"}
    }}
  end

  defp handle_method("tools/list", _params, _state) do
    {:ok, %{tools: tools()}}
  end

  defp handle_method("tools/call", %{"name" => name, "arguments" => args}, state) do
    IO.puts(:stderr, "OrchidMCP: tool #{name}(#{inspect(args) |> String.slice(0, 200)})")
    result = execute_tool(name, args, state)
    content = case result do
      {:ok, text} -> [%{type: "text", text: to_string(text)}]
      {:error, err} -> [%{type: "text", text: "Error: #{inspect(err)}"}]
    end
    {:ok, %{content: content, isError: match?({:error, _}, result)}}
  end

  defp handle_method(_method, _params, _state) do
    {:error, -32601, "Method not found"}
  end

  # Tool definitions
  defp tools do
    [
      %{name: "goal_list", description: "List all goals for the current project",
        inputSchema: %{type: "object", properties: %{}}},

      %{name: "goal_read", description: "Read a goal's full details",
        inputSchema: %{type: "object", properties: %{
          id: %{type: "string", description: "Goal ID or name"}
        }}},

      %{name: "goal_create", description: "Create a new goal",
        inputSchema: %{type: "object", properties: %{
          name: %{type: "string", description: "Short goal name"},
          description: %{type: "string", description: "Detailed description — this is the work order"},
          depends_on: %{type: "array", items: %{type: "string"}, description: "Goal IDs/names this depends on"},
          parent_goal_id: %{type: "string", description: "Parent goal ID"}
        }}},

      %{name: "goal_update", description: "Update a goal's status",
        inputSchema: %{type: "object", properties: %{
          id: %{type: "string", description: "Goal ID or name"},
          status: %{type: "string", description: "New status: pending or completed"}
        }}},

      %{name: "agent_spawn", description: "Spawn an agent from a template and assign it a goal",
        inputSchema: %{type: "object", properties: %{
          template: %{type: "string", description: "Template name (Coder, Codex Coder, Reverse Engineer, Shell Operator, Explorer)"},
          goal_id: %{type: "string", description: "Goal ID or name to assign"},
          message: %{type: "string", description: "Initial message (only if no goal_id)"}
        }}},

      %{name: "wait", description: "Wait up to N seconds for notifications from spawned agents",
        inputSchema: %{type: "object", properties: %{
          seconds: %{type: "integer", description: "Max seconds to wait (1-300)"}
        }}},

      %{name: "list", description: "List files in the workspace",
        inputSchema: %{type: "object", properties: %{
          path: %{type: "string", description: "Path to list (default: /workspace)"}
        }}},

      %{name: "read", description: "Read a file from the workspace",
        inputSchema: %{type: "object", properties: %{
          path: %{type: "string", description: "File path"}
        }}},

      %{name: "grep", description: "Search file contents with a regex pattern",
        inputSchema: %{type: "object", properties: %{
          pattern: %{type: "string", description: "Regex pattern"},
          path: %{type: "string", description: "Path to search (default: /workspace)"},
          glob: %{type: "string", description: "File glob filter"}
        }}}
    ]
  end

  # Tool execution — calls Orchid via RPC
  defp execute_tool("goal_list", _args, state) do
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])
    if is_list(goals) do
      text = Enum.map_join(goals, "\n", fn g ->
        status = g.metadata[:status] || :pending
        deps = g.metadata[:depends_on] || []
        agent = g.metadata[:agent_id]
        dep_str = if deps == [], do: "", else: " depends_on=[#{Enum.join(deps, ", ")}]"
        agent_str = if agent, do: " agent=#{agent}", else: ""
        "[#{status}] #{g.name} [#{g.id}]#{dep_str}#{agent_str}"
      end)
      {:ok, text}
    else
      {:error, "RPC failed: #{inspect(goals)}"}
    end
  end

  defp execute_tool("goal_read", %{"id" => id}, state) do
    goal = resolve_goal(id, state.project_id)
    case goal do
      nil -> {:error, "Goal not found: #{id}"}
      g ->
        text = """
        Name: #{g.name}
        ID: #{g.id}
        Status: #{g.metadata[:status] || :pending}
        Agent: #{g.metadata[:agent_id] || "none"}
        Dependencies: #{inspect(g.metadata[:depends_on] || [])}
        Parent: #{g.metadata[:parent_goal_id] || "root"}
        Report: #{g.metadata[:report] || "none"}

        Description:
        #{g.content}
        """
        {:ok, String.trim(text)}
    end
  end

  defp execute_tool("goal_create", args, state) do
    name = args["name"] || "Unnamed"
    desc = args["description"] || ""
    parent = args["parent_goal_id"]

    # Resolve parent — default to agent's assigned goal
    parent_id = if parent do
      case resolve_goal(parent, state.project_id) do
        nil -> nil
        g -> g.id
      end
    else
      # Auto-set to creating agent's assigned goal
      if state.agent_id do
        :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])
        |> Enum.find(fn g -> g.metadata[:agent_id] == state.agent_id end)
        |> case do
          nil -> nil
          g -> g.id
        end
      end
    end

    opts = if parent_id, do: [parent_goal_id: parent_id], else: []

    case :rpc.call(@node, Orchid.Goals, :create, [name, desc, state.project_id, opts]) do
      {:ok, goal} ->
        # Resolve depends_on
        if args["depends_on"] && args["depends_on"] != [] do
          dep_ids = Enum.map(args["depends_on"], fn ref ->
            case resolve_goal(ref, state.project_id) do
              nil -> ref  # keep as-is if not found
              g -> g.id
            end
          end)
          :rpc.call(@node, Orchid.Object, :update_metadata, [goal.id, %{depends_on: dep_ids}])
        end
        {:ok, "Created goal: #{goal.name} [#{goal.id}]"}
      error ->
        {:error, "Failed: #{inspect(error)}"}
    end
  end

  defp execute_tool("goal_update", %{"id" => id, "status" => status}, state) do
    case resolve_goal(id, state.project_id) do
      nil -> {:error, "Goal not found: #{id}"}
      g ->
        status_atom = String.to_existing_atom(status)
        :rpc.call(@node, Orchid.Goals, :set_status, [g.id, status_atom])
        {:ok, "Updated goal #{g.name} to #{status}"}
    end
  end

  defp execute_tool("agent_spawn", %{"template" => _template} = args, state) do
    # Call Orchid's agent_spawn tool
    ctx = %{agent_state: %{project_id: state.project_id, id: state.agent_id}}
    case :rpc.call(@node, Orchid.Tools.AgentSpawn, :execute, [args, ctx]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("wait", args, state) do
    unless state.agent_id do
      {:ok, "No agent_id — cannot wait for notifications"}
    else
      seconds = min(max(args["seconds"] || 60, 1), 300)
      deadline = System.monotonic_time(:second) + seconds
      wait_loop(state.agent_id, deadline)
    end
  end

  defp execute_tool("list", args, state) do
    path = args["path"] || "/workspace"
    case :rpc.call(@node, Orchid.Sandbox, :list_files, [state.project_id, path]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("read", %{"path" => path}, state) do
    case :rpc.call(@node, Orchid.Sandbox, :read_file, [state.project_id, path]) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("grep", %{"pattern" => pattern} = args, state) do
    path = args["path"] || "/workspace"
    opts = if args["glob"], do: [glob: args["glob"]], else: []
    case :rpc.call(@node, Orchid.Sandbox, :grep_files, [state.project_id, pattern, path, opts]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool(name, _args, _state) do
    {:error, "Unknown tool: #{name}"}
  end

  # Helpers
  defp resolve_goal(ref, project_id) do
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [project_id])
    if is_list(goals) do
      Enum.find(goals, fn g -> g.id == ref end) ||
        Enum.find(goals, fn g -> String.downcase(g.name) == String.downcase(ref) end)
    end
  end

  defp wait_loop(agent_id, deadline) do
    case :rpc.call(@node, Orchid.Agent, :drain_notifications, [agent_id]) do
      {:ok, []} ->
        if System.monotonic_time(:second) < deadline do
          Process.sleep(2_000)
          wait_loop(agent_id, deadline)
        else
          {:ok, "No notifications received within timeout."}
        end
      {:ok, notifications} ->
        text = Enum.join(notifications, "\n\n---\n\n")
        {:ok, "Received #{length(notifications)} notification(s):\n\n#{text}"}
    end
  end
end

# Parse args from System.argv()
OrchidMCP.main(System.argv())
