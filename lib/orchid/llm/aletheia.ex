defmodule Orchid.LLM.Aletheia do
  @moduledoc """
  Prompt/persona helpers for the Aletheia planning loop.
  """

  alias Orchid.{LLM, Project}

  @default_config %{
    provider: :cli,
    model: :sonnet,
    disable_tools: true,
    max_turns: 1,
    max_tokens: 1_800
  }

  @type critique :: %{approved?: boolean(), feedback: String.t()}

  @spec generate_paths(String.t(), pos_integer(), map()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def generate_paths(objective, num_paths, llm_config \\ %{}) do
    prompt = """
    You are an expert software architect.

    Objective:
    #{objective}

    Generate #{num_paths} distinct, step-by-step implementation plans.
    Each plan must follow a meaningfully different approach.

    Return ONLY valid JSON in this exact shape:
    {"plans":["plan 1","plan 2","plan 3"]}
    """

    with {:ok, raw} <- llm_text(prompt, llm_config) do
      text = String.trim(raw)

      if text == "" do
        {:error, "Model returned empty planning output"}
      else
        # Parsing disabled intentionally: return raw model output as-is.
        # Planner can still run on this single path while GUI shows raw text.
        {:ok, [text]}
      end
    end
  end

  @spec verify_plan(String.t(), String.t(), any(), String.t() | nil, map()) :: critique()
  def verify_plan(plan, objective, overlay, project_id, llm_config \\ %{}) do
    workspace_context = workspace_context(project_id, overlay)

    prompt = """
    You are a strict, adversarial technical reviewer.

    Objective:
    #{objective}

    Candidate plan:
    #{plan}

    Workspace context:
    #{workspace_context}

    Evaluate whether this plan is executable and complete.
    Focus on: missing prerequisites, unrealistic assumptions, unsafe sequencing, and unverified claims.

    Return ONLY valid JSON:
    {"approved":true|false,"feedback":"concise critique"}
    """

    case llm_text(prompt, llm_config) do
      {:ok, raw} ->
        parse_critique(raw)

      {:error, reason} ->
        %{approved?: false, feedback: "Verifier failed: #{reason}"}
    end
  end

  @spec revise_plan(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def revise_plan(plan, feedback, objective, llm_config \\ %{}) do
    prompt = """
    You are a plan reviser.

    Objective:
    #{objective}

    Original plan:
    #{plan}

    Critic feedback:
    #{feedback}

    Rewrite the plan so it fully addresses the critique.
    Return only the revised plan text.
    """

    llm_text(prompt, llm_config)
  end

  @spec select_best_path(String.t(), [String.t()], map()) :: String.t()
  def select_best_path(objective, paths, llm_config \\ %{})

  def select_best_path(_objective, [single], _llm_config), do: single

  def select_best_path(objective, paths, llm_config) when is_list(paths) do
    plans_blob =
      paths
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {plan, idx} -> "Plan #{idx}:\n#{plan}" end)

    prompt = """
    Objective:
    #{objective}

    Candidate plans:
    #{plans_blob}

    Choose the safest, most executable plan.
    Return only the exact winning plan text.
    """

    case llm_text(prompt, llm_config) do
      {:ok, best} when is_binary(best) and best != "" -> best
      _ -> List.first(paths) || ""
    end
  end

  defp llm_text(prompt, llm_config) when is_binary(prompt) do
    do_llm_text(prompt, llm_config, false)
  end

  defp do_llm_text(prompt, llm_config, retried?) when is_binary(prompt) do
    config = Map.merge(@default_config, Map.take(llm_config || %{}, [:provider, :model]))

    context = %{
      system: "",
      messages: [%{role: :user, content: String.trim(prompt)}],
      objects: "",
      memory: %{}
    }

    case LLM.chat(config, context) do
      {:ok, %{content: content}} when is_binary(content) ->
        trimmed = String.trim(content)

        cond do
          trimmed != "" ->
            {:ok, trimmed}

          retried? ->
            {:error, "Model returned empty planning output"}

          true ->
            retry_prompt =
              """
              The previous response was empty.
              Reply with a non-empty plain text answer now.

              #{prompt}
              """
              |> String.trim()

            do_llm_text(retry_prompt, llm_config, true)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_critique(raw) when is_binary(raw) do
    candidate =
      case Jason.decode(raw) do
        {:ok, parsed} -> parsed
        _ -> nil
      end

    approved =
      case candidate do
        %{"approved" => v} when is_boolean(v) -> v
        _ -> false
      end

    feedback =
      case candidate do
        %{"feedback" => msg} when is_binary(msg) and msg != "" -> msg
        _ -> String.slice(raw, 0, 500)
      end

    %{approved?: approved, feedback: feedback}
  end

  defp workspace_context(nil, _overlay), do: "(project not set)"

  defp workspace_context(project_id, _overlay) do
    root = Project.files_path(project_id)

    files =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.take(60)
      |> Enum.map(&Path.relative_to(&1, root))

    if files == [] do
      "(workspace appears empty)"
    else
      Enum.join(files, "\n")
    end
  end
end
