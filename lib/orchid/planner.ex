defmodule Orchid.Planner do
  @moduledoc """
  Multi-path planning loop (Generator -> Verifier -> Reviser).

  This module explores several candidate plans concurrently, iteratively
  critiques/revises each path, and returns the strongest final plan.
  """

  require Logger

  alias Orchid.LLM.Aletheia
  alias Orchid.Sandbox.Overlay

  @default_opts [
    num_paths: 3,
    max_iterations: 3,
    max_concurrency: 3
  ]

  @spec plan(String.t(), any(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def plan(objective, base_sandbox, opts \\ []) when is_binary(objective) do
    opts = Keyword.merge(@default_opts, opts)
    num_paths = bounded_int(opts[:num_paths], 3, 1, 8)
    max_iterations = bounded_int(opts[:max_iterations], 3, 0, 6)
    max_concurrency = bounded_int(opts[:max_concurrency], num_paths, 1, 8)

    llm_config = opts[:llm_config] || %{}
    project_id = opts[:project_id]

    Logger.info("[Aletheia] generator: proposing #{num_paths} candidate plans")

    with {:ok, paths} <- Aletheia.generate_paths(objective, num_paths, llm_config) do
      refined_paths =
        paths
        |> Task.async_stream(
          fn initial_plan ->
            refine_loop(initial_plan, objective, base_sandbox, max_iterations, project_id, llm_config)
          end,
          max_concurrency: max_concurrency,
          timeout: :timer.minutes(10),
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, path} when is_binary(path) and path != "" -> [path]
          _ -> []
        end)

      if refined_paths == [] do
        {:error, "All planning paths failed verification."}
      else
        Logger.info("[Aletheia] selector: choosing best plan from #{length(refined_paths)} candidates")
        {:ok, Aletheia.select_best_path(objective, refined_paths, llm_config)}
      end
    end
  end

  defp refine_loop(plan, _objective, _base_sandbox, 0, _project_id, _llm_config), do: plan

  defp refine_loop(plan, objective, base_sandbox, iterations_left, project_id, llm_config) do
    overlay = Overlay.branch(base_sandbox)
    critique = Aletheia.verify_plan(plan, objective, overlay, project_id, llm_config)
    Overlay.discard(overlay)

    if critique.approved? do
      plan
    else
      case Aletheia.revise_plan(plan, critique.feedback, objective, llm_config) do
        {:ok, revised_plan} ->
          refine_loop(revised_plan, objective, base_sandbox, iterations_left - 1, project_id, llm_config)

        {:error, _reason} ->
          plan
      end
    end
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_int(_value, default, _min, _max), do: default
end
