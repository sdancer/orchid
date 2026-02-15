defmodule Orchid.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude API client.
  Handles chat completion with tool use support.
  """
  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @doc """
  Send a chat request to Claude.
  """
  def chat(config, context) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("anthropic_api_key")

    if is_nil(api_key) do
      {:error, {:api_key_missing, "anthropic_api_key fact not set. Add it in Settings > Facts or local facts file."}}
    else

    body = build_request_body(config, context)

    case Req.post(@api_url,
           json: body,
           headers: headers(api_key),
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: response}} ->
        parse_response(response)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic request failed: #{inspect(reason)}")
        {:error, reason}
    end
    end
  end

  @doc """
  Send a streaming chat request to Claude.
  """
  def chat_stream(config, context, callback) do
    api_key = config[:api_key] || Orchid.Object.get_fact_value("anthropic_api_key")

    if is_nil(api_key) do
      {:error, {:api_key_missing, "anthropic_api_key fact not set. Add it in Settings > Facts or local facts file."}}
    else

    body = build_request_body(config, context) |> Map.put(:stream, true)

    # Accumulate the response
    initial_acc = %{content: "", tool_calls: [], current_tool: nil}

    case Req.post(@api_url,
           json: body,
           headers: headers(api_key),
           receive_timeout: 120_000,
           into:
             {initial_acc,
              fn {:data, chunk}, acc ->
                {new_acc, _} = process_stream_chunk(chunk, acc, callback)
                {:cont, new_acc}
              end}
         ) do
      {:ok, %{status: 200, body: {final_acc, _}}} ->
        tool_calls = if final_acc.tool_calls == [], do: nil, else: final_acc.tool_calls
        {:ok, %{content: final_acc.content, tool_calls: tool_calls}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
    end
  end

  @doc """
  Format tools for Anthropic API format.
  """
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  # Private functions

  defp headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(config, context) do
    messages = format_messages(context.messages, context.objects)

    body = %{
      model: config.model,
      max_tokens: Map.get(config, :max_tokens, 4096),
      messages: messages
    }

    # Add system prompt if present
    body =
      if context.system && context.system != "" do
        system_with_context = build_system_prompt(context.system, context.objects, context.memory)
        Map.put(body, :system, system_with_context)
      else
        body
      end

    # Add tools if available
    tools = Orchid.Tool.list_tools()

    if tools != [] do
      Map.put(body, :tools, format_tools(tools))
    else
      body
    end
  end

  defp build_system_prompt(base_prompt, objects, memory) do
    parts = [base_prompt]

    # Add object context
    parts =
      if objects && objects != "" do
        parts ++ ["\n\n## Available Objects\n\n#{objects}"]
      else
        parts
      end

    # Add memory context
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

  defp format_messages(messages, _objects) do
    messages
    |> Enum.map(fn msg ->
      case msg.role do
        :user -> %{role: "user", content: msg.content}
        :assistant -> format_assistant_message(msg)
        :tool -> format_tool_message(msg)
      end
    end)
  end

  defp format_assistant_message(msg) do
    content =
      cond do
        msg.tool_calls && msg.tool_calls != [] ->
          text_block =
            if msg.content && msg.content != "" do
              [%{type: "text", text: msg.content}]
            else
              []
            end

          tool_blocks =
            Enum.map(msg.tool_calls, fn tc ->
              %{
                type: "tool_use",
                id: tc.id,
                name: tc.name,
                input: tc.arguments
              }
            end)

          text_block ++ tool_blocks

        true ->
          msg.content
      end

    %{role: "assistant", content: content}
  end

  defp format_tool_message(msg) do
    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: msg.content.tool_use_id,
          content: msg.content.content
        }
      ]
    }
  end

  defp parse_response(response) do
    content_blocks = response["content"] || []

    # Extract text content
    text_content =
      content_blocks
      |> Enum.filter(fn block -> block["type"] == "text" end)
      |> Enum.map(fn block -> block["text"] end)
      |> Enum.join("")

    # Extract tool calls
    tool_calls =
      content_blocks
      |> Enum.filter(fn block -> block["type"] == "tool_use" end)
      |> Enum.map(fn block ->
        %{
          id: block["id"],
          name: block["name"],
          arguments: block["input"]
        }
      end)

    tool_calls = if tool_calls == [], do: nil, else: tool_calls

    {:ok, %{content: text_content, tool_calls: tool_calls}}
  end

  defp process_stream_chunk(chunk, acc, callback) do
    # Parse SSE events from chunk
    chunk
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc ->
      cond do
        String.starts_with?(line, "data: ") ->
          data = String.trim_leading(line, "data: ")

          if data != "[DONE]" do
            case Jason.decode(data) do
              {:ok, event} -> handle_stream_event(event, acc, callback)
              _ -> acc
            end
          else
            acc
          end

        true ->
          acc
      end
    end)
    |> then(fn acc -> {acc, acc} end)
  end

  defp handle_stream_event(event, acc, callback) do
    case event["type"] do
      "content_block_delta" ->
        delta = event["delta"]

        case delta["type"] do
          "text_delta" ->
            text = delta["text"]
            callback.(text)
            %{acc | content: acc.content <> text}

          "input_json_delta" ->
            # Accumulate tool input JSON
            acc

          _ ->
            acc
        end

      "content_block_start" ->
        content_block = event["content_block"]

        case content_block["type"] do
          "tool_use" ->
            tool = %{
              id: content_block["id"],
              name: content_block["name"],
              arguments: %{}
            }

            %{acc | current_tool: tool}

          _ ->
            acc
        end

      "content_block_stop" ->
        if acc.current_tool do
          %{acc | tool_calls: acc.tool_calls ++ [acc.current_tool], current_tool: nil}
        else
          acc
        end

      _ ->
        acc
    end
  end
end
