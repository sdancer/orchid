defmodule Orchid.Agent.Reviser do
  @moduledoc """
  Reviser module for decomposition nodes.
  """
  require Logger

  alias Orchid.LLM
  alias Orchid.Agent.Planner

  @default_config %{
    provider: :gemini,
    model: :gemini_3_1_pro_preview,
    thinking_level: "HIGH",
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_600
  }

  @spec fix(list(), String.t(), String.t(), map()) :: [map()]
  def fix(plan, critique, objective, llm_config \\ %{})
      when is_list(plan) and is_binary(critique) and is_binary(objective) do
    prompt = """
    You are a plan reviser.

    OBJECTIVE:
    #{objective}

    ORIGINAL PLAN:
    #{inspect(plan)}

    CRITIQUE:
    #{critique}

    Rewrite the plan so it addresses all issues.
    Return ONLY a valid JSON array of task objects using fields:
    "id", "type", "objective", and for "tool" tasks: "tool", "args".
    """

    case llm_text(prompt, llm_config) do
      {:ok, raw} ->
        Logger.info("[NodeReviser] Raw LLM response:\n#{raw}")

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
        plan
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

    case LLM.chat(config, context) do
      {:ok, %{content: content}} when is_binary(content) ->
        text = String.trim(content)
        if text == "", do: {:error, :empty}, else: {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
