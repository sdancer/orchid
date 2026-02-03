defmodule Orchid.LLM.CLI do
  @moduledoc """
  Claude CLI-based provider.
  Uses the `claude` CLI tool which handles auth via subscription.
  """
  require Logger

  @doc """
  Send a chat request via Claude CLI.
  """
  def chat(config, context) do
    prompt = build_prompt(context)
    model_arg = model_flag(config[:model])
    system_arg = if context[:system], do: ["--system-prompt", context.system], else: []

    # Use -p to pass prompt as argument
    args = ["--print", "-p", prompt, "--output-format", "text"] ++ model_arg ++ system_arg

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
  Uses System.cmd for reliability, streams result to callback after completion.
  """
  def chat_stream(config, context, callback) do
    # For streaming, just call chat and stream the result
    case chat(config, context) do
      {:ok, %{content: content} = result} ->
        callback.(content)
        {:ok, result}

      error ->
        error
    end
  end

  defp build_prompt(context) do
    parts = []

    # Add system context
    parts =
      if context[:system] && context.system != "" do
        parts ++ ["System: #{context.system}\n"]
      else
        parts
      end

    # Add messages
    parts =
      parts ++
        Enum.map(context.messages, fn msg ->
          case msg.role do
            :user -> msg.content
            :assistant -> "Assistant: #{msg.content}"
            :tool -> "Tool result: #{inspect(msg.content)}"
          end
        end)

    Enum.join(parts, "\n\n")
  end

  defp model_flag(nil), do: []
  defp model_flag(:sonnet), do: ["--model", "sonnet"]
  defp model_flag(:haiku), do: ["--model", "haiku"]
  defp model_flag(:opus), do: ["--model", "opus"]
  defp model_flag(model) when is_binary(model), do: ["--model", model]
  defp model_flag(_), do: []
end
