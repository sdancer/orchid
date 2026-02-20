defmodule Orchid.Agent.Planner do
  @moduledoc """
  Generator module for decomposition nodes.
  """
  require Logger

  alias Orchid.Agent.Logging
  alias Orchid.LLM

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    response_mime_type: "application/json",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 20_000
  }

  @spec decompose(String.t(), list(), map()) :: [map()] | {:error, term()}
  def decompose(objective, completed_tasks, llm_config \\ %{})
      when is_binary(objective) and is_list(completed_tasks) do
    system_prompt = """
    You are the Master Planner (Generator node) in a dynamic, autonomous agent system.

    CORE PHILOSOPHY: LAZY HIERARCHICAL PLANNING
    Your goal is to break down tasks using "lazy evaluation." You do not need to plan every single atomic step of a complex goal from the beginning. Instead, you decompose the current objective into immediate, logical sub-tasks.

    You must classify every sub-task into one of two categories:

    1. HIGH-LEVEL "DELEGATE" NODES (Blocked / Unresolved)
       If a sub-task is abstract, complex, or requires discovering information before it can be executed (e.g., "Find the database credentials", "Figure out how to compile this project"), you must make it a "delegate" task. Do NOT guess the steps. A child agent will be spawned later to investigate and break this node down further.

    2. ACTIONABLE "TOOL" NODES (Unblocked / Ready)
       If a sub-task is fully understood and you know the exact, concrete inputs required, make it a "tool" task. These nodes will be executed immediately. They must be perfectly actionable.

    STRICT RULES FOR ACTIONABLE NODES:
    - Never emit placeholders, TODO text, or comment-only shell commands.
    - If details are missing (e.g., you don't know the exact filename or flag), DO NOT use a tool node. Emit a "delegate" node to figure it out instead.
    - For shell tasks, "args.command" must be a concrete, runnable command.
    - BAD shell command examples (NEVER output these):
      * "# Placeholder: run translator"
      * "TODO: figure out script"
      * "insert_command_here"
    - GOOD alternative when unknown:
      * {"type": "delegate", "objective": "Determine exact translator invocation and run it"}

    OUTPUT FORMAT:
    You must return ONLY a valid JSON array of task objects. Do not include markdown formatting like ```json unless explicitly requested by the parser, just return the raw array.
    """

    user_prompt = """
    CURRENT OBJECTIVE:
    #{objective}

    COMPLETED HISTORY:
    #{inspect(completed_tasks)}

    INSTRUCTIONS:
    Analyze the current objective and the completed history. Determine the immediate next steps required.

    Decompose the remaining work into an array of JSON objects.
    Each task object MUST include:
    - "id": A stable, short, unique identifier string (e.g., "setup_db", "read_readme").
    - "type": Strictly either "delegate" or "tool".
    - "objective": A clear, one-sentence description of what this sub-task achieves.

    If "type" is "tool", you MUST also include:
    - "tool": The exact Orchid tool name to use.
    - "args": A JSON object containing the exact arguments for the tool.

    Generate the JSON array now:
    """

    case llm_text(system_prompt, user_prompt, llm_config) do
      {:ok, raw} ->
        Logging.log_full("NodePlanner", raw)

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

  defp llm_text(system_prompt, user_prompt, llm_config) do
    config = Map.merge(@default_config, Map.take(llm_config || %{}, [:provider, :model]))

    context = %{
      system: String.trim(system_prompt),
      messages: [%{role: :user, content: String.trim(user_prompt)}],
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
        task = Map.merge(base, %{tool: tool, args: args})
        if valid_tool_task?(task), do: task, else: nil
    end
  end

  defp normalize_task(_), do: nil

  defp valid_tool_task?(%{tool: tool, args: args}) when is_binary(tool) and is_map(args) do
    normalized_tool = String.downcase(String.trim(tool))

    if normalized_tool == "shell" do
      command = args["command"] || args[:command] || ""
      concrete_shell_command?(command)
    else
      true
    end
  end

  defp valid_tool_task?(_), do: false

  defp concrete_shell_command?(command) when is_binary(command) do
    trimmed = String.trim(command)
    lower = String.downcase(trimmed)

    trimmed != "" and
      not String.starts_with?(trimmed, "#") and
      not String.contains?(lower, "placeholder") and
      not String.contains?(lower, "todo") and
      not String.contains?(lower, "insert_")
  end

  defp concrete_shell_command?(_), do: false

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
