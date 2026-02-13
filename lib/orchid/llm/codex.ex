defmodule Orchid.LLM.Codex do
  @moduledoc """
  OpenAI Codex CLI-based provider.
  Uses `codex exec` for non-interactive agentic coding.

  Codex handles its own tool calls internally (shell, file ops).
  Returns text-only responses to Orchid (no tool_calls).

  ## Config options
  - `:model` - model string (default: from codex config, typically "gpt-5.3-codex")
  - `:project_id` - project ID for workspace directory
  - `:use_orchid_tools` - when true, runs as orchestrator with Orchid MCP tools
  - `:agent_id` - agent ID (passed to MCP server for tool context)
  """
  require Logger

  @doc """
  Send a chat request via Codex CLI.
  """
  def chat(config, context) do
    prompt = build_prompt(context)
    args = build_args(config, prompt)

    Logger.debug("Codex args: #{inspect(args)}")

    task = Task.async(fn ->
      cmd = build_shell_command(args, config)
      Logger.info("Codex exec: #{String.slice(cmd, 0, 300)}")
      output = :os.cmd(String.to_charlist(cmd))
      raw = to_string(output) |> String.trim()
      Logger.info("Codex raw (#{byte_size(raw)} bytes): #{String.slice(raw, 0, 200)}")
      parse_jsonl(raw)
    end)

    # Orchestrators with MCP tools need much longer — they spawn agents and wait
    timeout = if config[:use_orchid_tools], do: 3_600_000, else: 600_000

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, ""} ->
        Logger.error("Codex returned empty response")
        {:error, "Codex returned empty response"}

      {:ok, content} ->
        if String.starts_with?(content, "Error:") or String.starts_with?(content, "error:") do
          Logger.error("Codex error: #{String.slice(content, 0, 500)}")
          {:error, {:api_error, content}}
        else
          {:ok, %{content: content, tool_calls: nil}}
        end

      nil ->
        Logger.error("Codex timeout after #{div(timeout, 1000)}s")
        {:error, :timeout}
    end
  end

  @doc """
  Stream a chat request via Codex CLI.
  """
  def chat_stream(config, context, callback) do
    case chat(config, context) do
      {:ok, %{content: content}} = result ->
        callback.(content)
        result

      error ->
        error
    end
  end

  # Parse JSONL output from `codex exec --json`
  # Extract agent_message items and command_execution results
  defp parse_jsonl(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      line = String.trim(line)
      case Jason.decode(line) do
        {:ok, %{"type" => "item.completed", "item" => item}} ->
          case item do
            %{"type" => "agent_message", "text" => text} ->
              acc ++ [{:message, text}]

            %{"type" => "command_execution", "command" => cmd, "aggregated_output" => output, "exit_code" => code} ->
              summary = "$ #{cmd}\n#{output}" <>
                if(code != 0, do: "\n(exit code: #{code})", else: "")
              acc ++ [{:command, summary}]

            _ ->
              acc
          end

        {:ok, %{"type" => "error", "message" => msg}} ->
          acc ++ [{:message, "Error: #{msg}"}]

        _ ->
          acc
      end
    end)
    |> Enum.map(fn
      {:message, text} -> text
      {:command, text} -> "```\n#{text}\n```"
    end)
    |> Enum.join("\n\n")
  end

  defp build_prompt(context) do
    # Codex doesn't have a separate system prompt flag.
    # Prepend system prompt to the user message.
    user_msg =
      context.messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == :user end)
      |> case do
        nil -> ""
        msg -> msg.content
      end

    case context[:system] do
      nil -> user_msg
      "" -> user_msg
      system -> "## Instructions\n#{system}\n\n## Task\n#{user_msg}"
    end
  end

  defp build_args(config, prompt) do
    args = ["exec", "--json"]

    # Model
    args = case config[:model] do
      nil -> args
      model when is_atom(model) -> args ++ ["-m", to_string(model)]
      model when is_binary(model) -> args ++ ["-m", model]
    end

    # Working directory — point at project files
    args = case config[:project_id] do
      nil -> args
      project_id ->
        workspace = Orchid.Project.files_path(project_id) |> Path.expand()
        File.mkdir_p!(workspace)
        args ++ ["-C", workspace]
    end

    # Sandbox mode — use full-auto (workspace-write + auto-approve)
    args = args ++ ["--full-auto"]

    # Orchestrators: disable shell tool, only use MCP tools
    args = if config[:use_orchid_tools] do
      args ++ ["--disable", "shell_tool"]
    else
      args
    end

    # Prompt at the end
    args ++ [prompt]
  end

  defp build_shell_command(args, config) do
    codex_path = System.find_executable("codex") || "codex"
    escaped_args = Enum.map(args, &shell_escape/1)

    if config[:use_orchid_tools] && config[:project_id] do
      # Orchestrator: create temp CODEX_HOME with MCP config
      codex_home = setup_orchestrator_home(config[:project_id], config[:agent_id])
      "CODEX_HOME=#{shell_escape(codex_home)} #{codex_path} #{Enum.join(escaped_args, " ")} 2>&1"
    else
      "#{codex_path} #{Enum.join(escaped_args, " ")} 2>&1"
    end
  end

  # Create a temp CODEX_HOME directory with config.toml that includes the Orchid MCP server.
  # Codex persists MCP config in config.toml rather than accepting it per-invocation.
  defp setup_orchestrator_home(project_id, agent_id) do
    cookie = File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
    orchid_root = File.cwd!()
    script = Path.join(orchid_root, "priv/mcp/orchid_mcp.exs")

    # Build MCP server command args
    mcp_args = [
      "--name", "mcp-#{:erlang.unique_integer([:positive])}@127.0.0.1",
      "--cookie", cookie,
      script,
      project_id
    ] ++ if(agent_id, do: [agent_id], else: [])

    # Format args as TOML array
    args_toml = "[" <> Enum.map_join(mcp_args, ", ", &"\"#{&1}\"") <> "]"

    # Build config.toml with MCP server and project trust
    workspace = Orchid.Project.files_path(project_id) |> Path.expand()

    config_toml = """
    [mcp_servers.orchid]
    command = "elixir"
    args = #{args_toml}

    [projects."#{workspace}"]
    trust_level = "trusted"
    """

    # Write to temp directory
    home = Path.join(System.tmp_dir!(), "orchid-codex-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), config_toml)

    Logger.info("Codex orchestrator CODEX_HOME: #{home}")
    home
  end

  defp shell_escape(arg) do
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end
end
