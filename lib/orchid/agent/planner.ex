defmodule Orchid.Agent.Planner do
  @moduledoc """
  Generator module for decomposition nodes.
  """
  require Logger

  alias Orchid.LLM

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_800
  }

  @spec decompose(String.t(), list(), map()) :: [map()] | {:error, term()}
  def decompose(objective, completed_tasks, llm_config \\ %{})
      when is_binary(objective) and is_list(completed_tasks) do
    prompt = """
    You are the Generator node in an Aletheia-style autonomous system.

    CURRENT OBJECTIVE:
    #{objective}

    COMPLETED HISTORY:
    #{inspect(completed_tasks)}

    INSTRUCTIONS:
    1. Decompose the remaining work into an array of sub-tasks.
    2. Each task must include:
       - "id": stable short identifier
       - "type": either "delegate" or "tool"
       - "objective": one sentence description
    3. For "tool" tasks, include:
       - "tool": Orchid tool name
       - "args": JSON object args
    4. Return ONLY valid JSON array.
    """

    case llm_text(prompt, llm_config) do
      {:ok, raw} ->
        Logger.info("[NodePlanner] Raw LLM response:\n#{raw}")

        case parse_tasks_strict(raw) do
          {:ok, tasks} -> tasks
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec from_response(String.t(), String.t()) :: [map()]
  def from_response(raw, objective) when is_binary(raw) and is_binary(objective) do
    parse_tasks(raw, objective)
  end

  @spec from_response_strict(String.t()) :: {:ok, [map()]} | {:error, term()}
  def from_response_strict(raw) when is_binary(raw) do
    parse_tasks_strict(raw)
  end

  defp llm_text(prompt, llm_config) do
    config = Map.merge(@default_config, Map.take(llm_config || %{}, [:provider, :model]))

    context = %{
      system: "",
      messages: [%{role: :user, content: String.trim(prompt)}],
      objects: "",
      memory: %{}
    }

    case LLM.chat(config, context) do
      {:ok, %{content: content}} when is_binary(content) ->
        text = String.trim(content)
        if text == "", do: {:error, :empty}, else: {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_tasks(raw, objective) when is_binary(raw) do
    case parse_tasks_strict(raw) do
      {:ok, tasks} -> tasks
      {:error, _reason} -> fallback_tasks(objective)
    end
  end

  defp parse_tasks_strict(raw) when is_binary(raw) do
    with {:ok, decoded} <- decode_json(raw),
         true <- is_list(decoded),
         normalized <- normalize_tasks(decoded),
         true <- normalized != [] do
      {:ok, normalized}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_or_empty_tasks}
      _ -> {:error, :invalid_tasks}
    end
  end

  defp normalize_tasks(tasks) do
    tasks
    |> Enum.map(&normalize_task/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_task(%{"type" => type, "objective" => objective} = task)
       when type in ["delegate", "tool"] and is_binary(objective) do
    id =
      case task["id"] do
        value when is_binary(value) and value != "" -> value
        _ -> "task_#{System.unique_integer([:positive])}"
      end

    base = %{
      id: id,
      type: if(type == "delegate", do: :delegate, else: :tool),
      objective: String.trim(objective)
    }

    case base.type do
      :delegate ->
        base

      :tool ->
        tool = if(is_binary(task["tool"]), do: task["tool"], else: "wait")
        args = if(is_map(task["args"]), do: task["args"], else: %{})
        Map.merge(base, %{tool: tool, args: args})
    end
  end

  defp normalize_task(_), do: nil

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        case Regex.run(~r/```(?:json)?\s*(\[.*\])\s*```/s, text, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp fallback_tasks(objective) do
    [
      %{
        id: "task_#{System.unique_integer([:positive])}",
        type: :tool,
        objective: "Report objective when decomposition is unavailable",
        tool: "wait",
        args: %{"seconds" => 0, "note" => objective}
      }
    ]
  end
end
