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

    case System.cmd("claude", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, %{content: String.trim(output), tool_calls: nil}}

      {error, code} ->
        Logger.error("Claude CLI error (#{code}): #{error}")
        {:error, {:cli_error, code, error}}
    end
  end

  @doc """
  Stream a chat request via Claude CLI.
  Uses Port for real-time streaming.
  """
  def chat_stream(config, context, callback) do
    prompt = get_prompt(context)
    args = build_args(config, context, prompt, stream: true)

    Logger.debug("Claude CLI stream args: #{inspect(args)}")

    port =
      Port.open({:spawn_executable, System.find_executable("claude")}, [
        {:args, args},
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    collect_stream(port, callback, "")
  end

  defp collect_stream(port, callback, acc) do
    receive do
      {^port, {:data, data}} ->
        callback.(data)
        collect_stream(port, callback, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, %{content: String.trim(acc), tool_calls: nil}}

      {^port, {:exit_status, code}} ->
        Logger.error("Claude CLI stream error (#{code}): #{acc}")
        {:error, {:cli_error, code, acc}}
    after
      120_000 ->
        Port.close(port)
        {:error, :timeout}
    end
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

    args = ["-p", prompt, "--print"]

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

    args
  end

  defp model_flag(nil), do: []
  defp model_flag(:sonnet), do: ["--model", "sonnet"]
  defp model_flag(:haiku), do: ["--model", "haiku"]
  defp model_flag(:opus), do: ["--model", "opus"]
  defp model_flag(model) when is_binary(model), do: ["--model", model]
  defp model_flag(_), do: []
end
