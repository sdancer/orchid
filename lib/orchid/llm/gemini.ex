defmodule Orchid.LLM.Gemini do
  @moduledoc """
  Google Gemini API client.
  Handles chat completion with streaming support.
  """
  require Logger

  @base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @models %{
    gemini_pro: "gemini-3-pro-preview",
    gemini_flash: "gemini-3-flash-preview",
    gemini_flash_image: "gemini-2.5-flash-preview-image-generation"
  }

  @doc """
  Send a chat request to Gemini.
  """
  def chat(config, context) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("gemini_api_key") || System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, {:api_key_missing, "GEMINI_API_KEY not set. Add it in Settings > Facts as 'gemini_api_key', or set the GEMINI_API_KEY env var."}}
    else

    model = resolve_model(config[:model])
    url = "#{@base_url}/#{model}:generateContent"
    body = build_request_body(config, context)

    IO.puts("[Gemini] chat request to model=#{model}")
    IO.puts("[Gemini] url=#{url}")
    IO.puts("[Gemini] messages count=#{length(context.messages)}")

    case Req.post(url,
           json: body,
           headers: headers(api_key),
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: response}} ->
        IO.puts("[Gemini] chat response OK (200)")
        parse_response(response)

      {:ok, %{status: status, body: body}} ->
        IO.puts("[Gemini] chat error status=#{status}")
        Logger.error("Gemini API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        IO.puts("[Gemini] chat request failed: #{inspect(reason)}")
        Logger.error("Gemini request failed: #{inspect(reason)}")
        {:error, reason}
    end
    end
  end

  @doc """
  Send a streaming chat request to Gemini.
  """
  def chat_stream(config, context, callback) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("gemini_api_key") || System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, {:api_key_missing, "GEMINI_API_KEY not set. Add it in Settings > Facts as 'gemini_api_key', or set the GEMINI_API_KEY env var."}}
    else

    model = resolve_model(config[:model])
    url = "#{@base_url}/#{model}:streamGenerateContent?alt=sse"
    body = build_request_body(config, context)

    IO.puts("[Gemini] chat_stream request to model=#{model}")
    IO.puts("[Gemini] stream url=#{url}")
    IO.puts("[Gemini] messages count=#{length(context.messages)}")

    acc = %{content: ""}

    stream_fun = fn {:data, chunk}, {req, resp} ->
      acc = Process.get(:gemini_acc, acc)
      new_acc = process_stream_chunk(chunk, acc, callback)
      Process.put(:gemini_acc, new_acc)
      {:cont, {req, resp}}
    end

    case Req.post(url,
           json: body,
           headers: headers(api_key),
           receive_timeout: 120_000,
           into: stream_fun
         ) do
      {:ok, %{status: 200}} ->
        final_acc = Process.get(:gemini_acc, acc)
        Process.delete(:gemini_acc)
        IO.puts("[Gemini] stream complete, total length=#{String.length(final_acc.content)}")
        {:ok, %{content: final_acc.content, tool_calls: nil}}

      {:ok, %{status: status, body: body}} ->
        Process.delete(:gemini_acc)
        IO.puts("[Gemini] stream error status=#{status}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Process.delete(:gemini_acc)
        IO.puts("[Gemini] stream request failed: #{inspect(reason)}")
        {:error, reason}
    end
    end
  end

  @doc """
  Format tools for Gemini API format.
  """
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  # Private functions

  defp resolve_model(model) do
    Map.get(@models, model, Map.get(@models, :gemini_pro))
  end

  defp headers(api_key) do
    [
      {"x-goog-api-key", api_key},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(config, context) do
    contents = format_messages(context.messages)

    body = %{
      contents: contents,
      generationConfig: %{
        maxOutputTokens: Map.get(config, :max_tokens, 8192)
      }
    }

    # Add system instruction if present
    if context.system && context.system != "" do
      system_text = build_system_prompt(context.system, context.objects, context.memory)
      Map.put(body, :system_instruction, %{parts: [%{text: system_text}]})
    else
      body
    end
  end

  defp build_system_prompt(base_prompt, objects, memory) do
    parts = [base_prompt]

    parts =
      if objects && objects != "" do
        parts ++ ["\n\n## Available Objects\n\n#{objects}"]
      else
        parts
      end

    parts =
      if memory && map_size(memory) > 0 do
        memory_str =
          memory
          |> Enum.map(fn {k, v} -> "- #{k}: #{inspect(v)}" end)
          |> Enum.join("\n")

        parts ++ ["\n\n## Memory\n\n#{memory_str}"]
      else
        parts
      end

    Enum.join(parts)
  end

  defp format_messages(messages) do
    messages
    |> Enum.filter(fn msg -> msg.role in [:user, :assistant] end)
    |> Enum.map(fn msg ->
      role =
        case msg.role do
          :user -> "user"
          :assistant -> "model"
        end

      %{role: role, parts: [%{text: msg.content || ""}]}
    end)
  end

  defp parse_response(response) do
    text =
      case get_in(response, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
        nil -> ""
        text -> text
      end

    {:ok, %{content: text, tool_calls: nil}}
  end

  defp process_stream_chunk(chunk, acc, callback) do
    chunk
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      cond do
        String.starts_with?(line, "data: ") ->
          data = String.trim_leading(line, "data: ")

          case Jason.decode(data) do
            {:ok, event} ->
              case get_in(event, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
                nil ->
                  acc

                text ->
                  callback.(text)
                  %{acc | content: acc.content <> text}
              end

            _ ->
              acc
          end

        true ->
          acc
      end
    end)
  end
end
