defmodule Orchid.LLM.CLI do
  @moduledoc """
  Claude CLI-based provider.
  Uses the `claude` CLI tool which handles auth via subscription.

  ## Config options
  - `:model` - :sonnet, :haiku, :opus, or model string
  - `:session_id` - Session ID for persistent conversations
  - `:resume` - Resume an existing session (boolean)
  - `:output_format` - "text", "json", or "stream-json" (default: "text")
  - `:max_turns` - Maximum agentic turns (default: unlimited)
  - `:allowed_tools` - List of allowed tools
  - `:permission_mode` - Permission mode for tool execution
  """
  require Logger

  @doc """
  Send a chat request via Claude CLI.
  """
  def chat(config, context) do
    prompt = get_prompt(context)
    args = build_args(config, context, prompt)

    Logger.debug("Claude CLI args: #{inspect(args)}")

    # Run in a Task to avoid blocking the caller
    task = Task.async(fn ->
      cmd = build_shell_command(args)
      output = :os.cmd(String.to_charlist(cmd))
      to_string(output) |> String.trim()
    end)

    case Task.yield(task, 120_000) || Task.shutdown(task) do
      {:ok, content} ->
        {:ok, %{content: content, tool_calls: nil}}

      nil ->
        {:error, :timeout}
    end
  end

  @doc """
  Stream a chat request via Claude CLI.
  Streams output via callback.
  """
  def chat_stream(config, context, callback) do
    # For CLI, we run the command and stream the result after
    # True streaming would require parsing stream-json format
    case chat(config, context) do
      {:ok, %{content: content}} = result ->
        callback.(content)
        result

      error ->
        error
    end
  end

  defp build_shell_command(args) do
    claude_path = System.find_executable("claude") || "claude"
    escaped_args = Enum.map(args, &shell_escape/1)
    "#{claude_path} #{Enum.join(escaped_args, " ")}"
  end

  defp shell_escape(arg) do
    # Escape single quotes and wrap in single quotes
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp get_prompt(context) do
    # Get the last user message as the prompt
    context.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :user end)
    |> case do
      nil -> ""
      msg -> msg.content
    end
  end

  defp build_args(config, context, prompt, opts \\ []) do
    streaming = Keyword.get(opts, :stream, false)

    # Start with --print flag (non-interactive mode)
    args = ["--print"]

    # Output format
    args =
      if streaming do
        args ++ ["--output-format", "stream-json"]
      else
        format = config[:output_format] || "text"
        args ++ ["--output-format", format]
      end

    # Model
    args = args ++ model_flag(config[:model])

    # System prompt
    args =
      if context[:system] && context.system != "" do
        args ++ ["--system-prompt", context.system]
      else
        args
      end

    # Session ID for persistent conversations
    args =
      if config[:session_id] do
        args ++ ["--session-id", config[:session_id]]
      else
        args
      end

    # Resume existing session
    args =
      if config[:resume] do
        args ++ ["--resume"]
      else
        args
      end

    # Max turns for agentic mode
    args =
      if config[:max_turns] do
        args ++ ["--max-turns", to_string(config[:max_turns])]
      else
        args
      end

    # Allowed tools
    args =
      if config[:allowed_tools] && config[:allowed_tools] != [] do
        tools = Enum.join(config[:allowed_tools], ",")
        args ++ ["--allowed-tools", tools]
      else
        args
      end

    # Permission mode
    args =
      if config[:permission_mode] do
        args ++ ["--permission-mode", config[:permission_mode]]
      else
        args
      end

    # Prompt is a positional argument at the end
    args ++ [prompt]
  end

  defp model_flag(nil), do: []
  defp model_flag(:sonnet), do: ["--model", "sonnet"]
  defp model_flag(:haiku), do: ["--model", "haiku"]
  defp model_flag(:opus), do: ["--model", "opus"]
  defp model_flag(model) when is_binary(model), do: ["--model", model]
  defp model_flag(_), do: []
end
