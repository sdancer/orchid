defmodule Orchid.Agent.Verifier do
  @moduledoc """
  Verifier module for decomposition nodes.
  """
  require Logger

  alias Orchid.LLM

  @min_retry_backoff_ms 1_000
  @max_retry_backoff_ms 10_000
  @max_retries 4

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_200
  }

  @spec critique(String.t(), list(), map()) :: {:approved, String.t()} | {:flawed, String.t()}
  def critique(objective, plan, llm_config \\ %{}) when is_binary(objective) and is_list(plan) do
    prompt = """
    You are the Verifier node. Your job is to evaluate a Proposed Plan.

    OBJECTIVE:
    #{objective}

    PROPOSED PLAN:
    #{inspect(plan)}

    INSTRUCTIONS:
    0. Assume decomposition is hierarchical and lazy:
       - High-level tasks may defer lower-level details until execution.
       - Do not reject a plan only because every sub-step is not fully expanded yet.
       - But dependencies must still be logically ordered.
    1. First argue why this plan could succeed.
    2. Then argue why it could fail, focusing on missing prerequisites and logic gaps.
    3. Treat true blockers as gating items:
       - If a blocking issue exists (for example, reconnaissance/discovery needed to unblock later work),
         the plan must explicitly solve that blocker before subsequent dependent steps.
       - If blockers are not resolved early enough, mark the plan as flawed.
    4. Return ONLY valid JSON:
       {"status":"approved","reason":"..."}
       or
       {"status":"flawed","critique":"..."}
    """

    case llm_text(prompt, llm_config) do
      {:ok, raw} ->
        Logger.info("[NodeVerifier] Raw LLM response:\n#{raw}")
        parse_verdict(raw)

      {:error, reason} ->
        {:flawed, "Verifier failed: #{inspect(reason)}"}
    end
  end

  defp llm_text(prompt, llm_config) do
    config = Map.merge(@default_config, Map.take(llm_config || %{}, [:provider, :model]))

    context = %{
      system: "",
      messages: [%{role: :user, content: String.trim(prompt)}],
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
