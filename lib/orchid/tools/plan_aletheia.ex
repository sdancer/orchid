defmodule Orchid.Tools.PlanAletheia do
  @moduledoc "Deep multi-path planning via Generator/Verifier/Reviser loop"
  @behaviour Orchid.Tool

  alias Orchid.Planner

  @impl true
  def name, do: "plan_aletheia"

  @impl true
  def description do
    "Generate and refine multiple candidate plans, then return the best verified plan"
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        objective: %{
          type: "string",
          description: "High-level objective to plan"
        },
        num_paths: %{
          type: "integer",
          description: "Number of candidate plans to generate (default: 3, max: 8)"
        },
        max_iterations: %{
          type: "integer",
          description: "Max verifier/reviser rounds per path (default: 3, max: 6)"
        }
      },
      required: ["objective"]
    }
  end

  @impl true
  def execute(%{"objective" => objective} = args, %{agent_state: state}) do
    opts = [
      num_paths: args["num_paths"],
      max_iterations: args["max_iterations"],
      project_id: state.project_id,
      llm_config: %{provider: state.config[:provider], model: state.config[:model]}
    ]

    case Planner.plan(objective, state.sandbox, opts) do
      {:ok, best_plan} ->
        {:ok,
         """
         Aletheia planning completed.

         Objective:
         #{objective}

         Best plan:
         #{best_plan}
         """ |> String.trim()}

      {:error, reason} ->
        {:error, "Aletheia planning failed: #{reason}"}
    end
  end

  def execute(_args, _context) do
    {:error, "plan_aletheia requires agent_state context"}
  end
end
