defmodule Orchid.Agent.Reviser do
  @moduledoc """
  Reviser module for decomposition nodes.
  """
  require Logger

  alias Orchid.Agent.Logging
  alias Orchid.LLM
  alias Orchid.Agent.Planner

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    response_mime_type: "application/json",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 20_000
  }

  @spec fix(list(), String.t(), String.t(), map()) :: [map()]
  def fix(plan, critique, objective, llm_config \\ %{})
      when is_list(plan) and is_binary(critique) and is_binary(objective) do
    Logger.info(
      "[NodeReviser] Starting revision (tasks=#{length(plan)} critique_len=#{String.length(critique)})"
    )

    system_prompt = """
    You are the Plan Reviser in a dynamic, autonomous agent system based on Lazy Hierarchical Planning.
    Your job is to take a flawed task breakdown, read the Verifier's critique, and generate a corrected plan.

    CORE PHILOSOPHY: LAZY HIERARCHICAL PLANNING
    You must maintain the system's "lazy evaluation" approach. Every sub-task must be strictly classified as:

    1. HIGH-LEVEL "DELEGATE" NODES (Blocked / Unresolved)
       For abstract tasks, missing prerequisites, or discovery (e.g., "Find the API key", "Determine the project structure"). Do NOT guess steps or hallucinate details. Use a "delegate" node so a child agent can figure it out later.

    2. ACTIONABLE "TOOL" NODES (Unblocked / Ready)
       For concrete tasks where you know the exact, executable inputs.
       - Never emit placeholders, TODO text, or comment-only shell commands.
       - If details are missing, emit a "delegate" task instead.
       - For shell tasks, "args.command" must be a runnable, concrete command.

    YOUR MISSION:
    The Verifier has rejected the previous plan (usually due to missing prerequisites, logic gaps, or out-of-order execution). You must restructure the plan, add missing "delegate" or "tool" steps to unblock dependencies, and remove flawed steps.
    """

    user_prompt = """
    CURRENT OBJECTIVE:
    #{objective}

    ORIGINAL FLAWED PLAN:
    #{inspect(plan)}

    VERIFIER'S CRITIQUE:
    #{critique}

    INSTRUCTIONS:
    1. Open a <scratchpad> block. Briefly analyze the critique and state exactly which steps you are adding, modifying, or removing to fix the logic gaps.
    2. Close the </scratchpad> block.
    3. Output the rewritten plan as a strictly valid JSON array.

    JSON SCHEMA REQUIREMENTS:
    Each task object in the array MUST include:
    - "id": A stable, short, unique identifier.
    - "type": Strictly either "delegate" or "tool".
    - "objective": A clear, one-sentence description.

    If "type" is "tool", you MUST also include:
    - "tool": The exact Orchid tool name.
    - "args": A JSON object containing the tool arguments.

    Return the new JSON array now:
    """

    case llm_text(system_prompt, user_prompt, llm_config) do
      {:ok, raw} ->
        Logging.log_full("NodeReviser", raw)

        case Planner.from_response_strict(raw) do
          {:ok, revised_plan} ->
            revised_plan

          {:error, reason} ->
            Logger.warning(
              "[NodeReviser] Invalid revised plan JSON; keeping previous plan. reason=#{inspect(reason)}"
            )

            plan
        end

      {:error, _reason} ->
        Logger.warning("[NodeReviser] LLM revision call failed; keeping previous plan")
        plan
    end
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
end
