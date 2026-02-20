defmodule Orchid.Agent.Verifier do
  @moduledoc """
  Verifier module for decomposition nodes.
  """
  require Logger

  alias Orchid.Agent.Logging
  alias Orchid.LLM

  @min_retry_backoff_ms 1_000
  @max_retry_backoff_ms 10_000
  @max_retries 4

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    response_mime_type: "application/json",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 20_000
  }

  @spec critique(String.t(), list(), map()) :: {:approved, String.t()} | {:flawed, String.t()}
  def critique(objective, plan, llm_config \\ %{}) when is_binary(objective) and is_list(plan) do
    system_prompt = """
    You are the Critical Verifier in a lazy hierarchical planning system. Your job is to evaluate a Proposed Plan against a specific Objective.

    CORE PHILOSOPHY: LAZY HIERARCHICAL PLANNING
    The system uses "lazy evaluation" for task decomposition. The plan will consist of two types of nodes:
    1. ACTIONABLE "TOOL" NODES: Concrete steps meant to be executed immediately.
    2. HIGH-LEVEL "DELEGATE" NODES: Blocked, complex, or unresolved tasks that act as placeholders. Child agents will expand these later.

    EVALUATION CRITERIA:
    - Evaluate correctness at the CURRENT abstraction level of the plan.
    - Do NOT reject a plan just because every sub-step is not fully expanded. "Delegate" tasks are perfectly valid for unknown or complex future steps.
    - Do NOT require concrete leaf execution steps (like specific file names or exact shell flags) if a "delegate" step validly owns that discovery work.

    GATING & DEPENDENCY LOGIC (CRITICAL):
    - Dependencies must be logically ordered.
    - If a blocking issue exists (e.g., reconnaissance, credentials, or discovery is needed to unblock later work), the plan MUST explicitly solve that blocker (via a tool or a delegate task) BEFORE subsequent dependent steps.
    - If concrete "tool" tasks are scheduled before their required discovery/setup phases, the plan is deeply flawed.

    BALANCED CRITIQUE PROCESS:
    To prevent confirmation bias, you must analyze the plan from both sides before reaching a verdict.
    1. First, argue why this plan is flawless and logically sound.
    2. Second, argue why this plan is fundamentally broken, focusing on missing prerequisites, logic gaps, or out-of-order execution.
    """

    user_prompt = """
    OBJECTIVE:
    #{objective}

    PROPOSED PLAN:
    #{inspect(plan)}

    INSTRUCTIONS:
    1. Open a <scratchpad> block. Inside it, write your balanced critique:
       - Argue why the plan will succeed.
       - Argue why the plan will fail.
       - Analyze if any blockers/dependencies are out of order.
    2. Close the </scratchpad> block.
    3. Output the final verdict as strictly valid JSON.

    JSON SCHEMA:
    If the plan is logically sound at its current abstraction level:
    {"status": "approved", "reason": "<brief justification>"}

    If the plan has fatal dependency flaws or out-of-order blockers:
    {"status": "flawed", "critique": "<specific instructions on what the Planner needs to fix>"}

    Provide your response now:
    """

    case llm_text(system_prompt, user_prompt, llm_config) do
      {:ok, raw} ->
        Logging.log_full("NodeVerifier", raw)
        parse_verdict(raw)

      {:error, reason} ->
        {:flawed, "Verifier failed: #{inspect(reason)}"}
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

    do_llm_text_with_retry(config, context, 0)
  end

  defp do_llm_text_with_retry(config, context, attempt) do
    case LLM.chat(config, context) do
      {:ok, %{content: content}} when is_binary(content) ->
        text = String.trim(content)

        if text == "" do
          maybe_retry_llm(config, context, attempt, :empty)
        else
          {:ok, text}
        end

      {:error, reason} ->
        maybe_retry_llm(config, context, attempt, reason)
    end
  end

  defp maybe_retry_llm(config, context, attempt, reason) when attempt < @max_retries do
    backoff_ms = retry_backoff_ms(attempt)

    Logger.warning(
      "[NodeVerifier] LLM call failed/empty; retry #{attempt + 1}/#{@max_retries} in #{backoff_ms}ms: #{inspect(reason)}"
    )

    Process.sleep(backoff_ms)
    do_llm_text_with_retry(config, context, attempt + 1)
  end

  defp maybe_retry_llm(_config, _context, _attempt, reason), do: {:error, reason}

  defp parse_verdict(raw) do
    with {:ok, data} <- decode_json(raw),
         status when status in ["approved", "flawed"] <- data["status"] do
      case status do
        "approved" -> {:approved, to_string(data["reason"] || "Approved")}
        "flawed" -> {:flawed, to_string(data["critique"] || "Flawed")}
      end
    else
      _ -> {:flawed, String.slice(raw, 0, 500)}
    end
  end

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, text, capture: :all_but_first) do
          [json] -> Jason.decode(json)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp retry_backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    delay = trunc(@min_retry_backoff_ms * :math.pow(2, attempt))
    min(delay, @max_retry_backoff_ms)
  end
end
