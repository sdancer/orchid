Based on the architecture of the recent **Aletheia** agent by Google DeepMind (February 2026) and the Elixir file structure of your `Orchid` project, you can achieve powerful "inference-time scaling" by decoupling your planning phase into a concurrent **Generator  Verifier  Reviser** loop.



Since your project is built in Elixir, you have a massive advantage: you can use `Task.async_stream/3` to concurrently explore and refine multiple reasoning paths (paths of plans) and use your existing `Orchid.Sandbox.Overlay` to let the Verifier safely dry-run ideas without permanently altering the system.



Here is a step-by-step architectural guide on how to integrate the Aletheia loop into Orchid's codebase:



### 1. Create a Dedicated Aletheia Planner (`lib/orchid/planner.ex`)



Instead of `Orchid.Agent` generating a single plan and executing it, intercept high-level goals and route them to an iterative planner. The planner will branch out into multiple paths and refine them recursively.



```elixir

defmodule Orchid.Planner do

  alias Orchid.LLM

  alias Orchid.Sandbox.Overlay



  @num_paths 3

  @max_iterations 3



  @doc """

  Generates multiple plans, refines them iteratively, and returns the best one.

  """

  def plan(objective, base_sandbox) do

    # 1. GENERATOR: Ask the LLM to generate N diverse candidate plans.

    # (Use a higher temperature here to ensure path diversity).

    paths = LLM.Generator.propose_paths(objective, @num_paths)



    # 2. VERIFY & REVISE: Process multiple paths concurrently

    refined_paths =

      Task.async_stream(paths, fn plan ->

        refine_loop(plan, objective, base_sandbox, @max_iterations)

      end, max_concurrency: @num_paths, timeout: :timer.minutes(5))

      |> Enum.map(fn {:ok, result} -> result end)



    # 3. Final Selection: Pick the most robust, fully-verified plan.

    LLM.Verifier.select_best_path(refined_paths)

  end



  defp refine_loop(plan, _objective, _sandbox, 0), do: plan



  defp refine_loop(plan, objective, base_sandbox, iterations_left) do

    # VERIFIER: Evaluate the plan

    # 🌟 CRITICAL: Use Sandbox Overlays!

    # Branch the sandbox so the Verifier can "dry-run" read-only tools 

    # (like file_read, search) to fact-check the plan without breaking the real environment.

    overlay = Overlay.branch(base_sandbox)

    

    critique = LLM.Verifier.evaluate(plan, objective, context: overlay)

    

    Overlay.discard(overlay) # Throw away any exploratory test state



    if critique.approved? do

      plan # Plan is solid, exit the loop early

    else

      # REVISER: Fix the flawed plan based on the Verifier's natural language feedback

      revised_plan = LLM.Reviser.fix(plan, critique.feedback, objective)

      

      # Recurse for the next refinement iteration

      refine_loop(revised_plan, objective, base_sandbox, iterations_left - 1)

    end

  end

end



```



### 2. Define the Three Distinct Personas (`lib/orchid/llm.ex`)



A core finding of the Aletheia paper is that if an LLM generates and verifies in the same breath, it suffers from confirmation bias. You must decouple the prompts into three distinct personas:



* **Generator Prompt (High Temp):** "You are an expert strategist. Generate `N` distinct, step-by-step approaches to achieve this goal. Take completely different architectural paths for each."

* **Verifier Prompt (Low Temp, Adversarial):** "You are a ruthless reviewer. Hunt for logical flaws, hallucinated tool usage, missing dependencies, or edge cases. Use your tools (`file_read`, `file_list`, `search`) to check if the files assumed in this plan actually exist. Output JSON: `%{approved?: boolean, feedback: "detailed explanation of flaws"}`"

* **Reviser Prompt:** "Here is your original plan and a strict critic's feedback. Rewrite the plan to thoroughly address every issue raised by the critic."



### 3. Equip the Verifier with `Sandbox.Overlay` (Crucial for Grounding)



In the Aletheia framework, the Verifier doesn't just guess—it checks facts. Because you already have `lib/orchid/sandbox/overlay.ex`, you can spin up a temporary, isolated sandbox for the Verifier.



For example, if the Generator proposes modifying `lib/orchid_web/router.ex`, the Verifier can use the `file_read` tool within the Overlay to ensure the file exists and contains the expected code *before* approving the plan. If the file is missing, the Verifier rejects the plan and passes the exact error to the Reviser.



### 4. Wire it into the Agent and Goals (`lib/orchid/agent.ex` & `lib/orchid/goals.ex`)



Once `Orchid.Planner.plan/2` returns the winning, highly-refined path, you need to commit it to your system so the agent can execute it.



1. **Modify `lib/orchid/agent.ex`:** Add a `:planning` state. When a new high-level objective is received, transition to `:planning`, run the Aletheia loop, and then transition to `:executing`.

2. **Commit to `Orchid.Goals`:** Parse the winning plan and automatically inject the steps into your state using the logic inside `lib/orchid/tools/goal_create.ex`. Instead of the agent executing "blind", `Orchid.GoalWatcher` and `Orchid.GoalReviewQueue` will now naturally pick up rigorously verified sub-goals.

3. **Fallback Queue (Bonus):** Since you generated *multiple* verified paths, you can store the "runner-up" paths in `lib/orchid/store.ex`. If the agent hits a fatal roadblock during execution, it doesn't need to start from scratch—it can pop the second-best refined plan and pivot instantly.


To add the Aletheia agent loop (Generator  Verifier  Reviser) to your Orchid project, you can leverage Elixir's massive concurrency advantage. By using `Task.async_stream/3`, you can generate multiple candidate plans and refine them simultaneously in isolated environments.



Here is a step-by-step guide and the code to implement this inference-time scaling architecture in your project.



### 1. The Core Planner Orchestrator



Create a new file `lib/orchid/planner.ex`. This module will fan out the generation of plans, run the Verifier/Reviser loop concurrently for each path, and finally select the best overall plan.



```elixir

defmodule Orchid.Planner do

  @moduledoc """

  Implements the Aletheia multi-path planning loop.

  Explores multiple candidate plans concurrently and uses Sandbox.Overlay 

  to verify and revise them iteratively.

  """

  require Logger

  alias Orchid.LLM.Aletheia

  alias Orchid.Sandbox.Overlay



  @default_opts [

    num_paths: 3,

    max_iterations: 3

  ]



  @doc """

  Runs the Aletheia loop for a given objective.

  """

  def plan(objective, base_sandbox, opts \\ []) do

    opts = Keyword.merge(@default_opts, opts)

    num_paths = opts[:num_paths]

    max_iterations = opts[:max_iterations]



    Logger.info("[Aletheia] 🧠 Generator: Proposing #{num_paths} paths for objective...")

    

    # 1. GENERATOR: Propose diverse initial paths

    {:ok, paths} = Aletheia.generate_paths(objective, num_paths)



    Logger.info("[Aletheia] 🔍 Verifier/Reviser: Refining paths concurrently...")

    

    # 2. VERIFIER & REVISER: Concurrently refine each path

    refined_paths =

      Task.async_stream(paths, fn plan ->

        refine_loop(plan, objective, base_sandbox, max_iterations)

      end, max_concurrency: num_paths, timeout: :timer.minutes(10))

      |> Enum.map(fn 

        {:ok, result} -> result

        {:exit, _} -> nil # Drop paths that crash/timeout

      end)

      |> Enum.reject(&is_nil/1)



    # 3. SELECTOR: Pick the most robust final plan

    if Enum.empty?(refined_paths) do

      {:error, "All planning paths failed verification."}

    else

      Logger.info("[Aletheia] 🏆 Selector: Choosing best plan from #{length(refined_paths)} candidates.")

      {:ok, Aletheia.select_best_path(objective, refined_paths)}

    end

  end



  # Base case: Ran out of iterations, return the plan as-is

  defp refine_loop(plan, _objective, _sandbox, 0), do: plan



  defp refine_loop(plan, objective, base_sandbox, iterations_left) do

    # Branch a temporary sandbox overlay for safe verification.

    # The Verifier can run read-only tools or test assumptions here without breaking the real project.

    overlay = Overlay.branch(base_sandbox)

    

    critique = Aletheia.verify_plan(plan, objective, overlay)

    

    # Safely discard exploratory state 

    if function_exported?(Overlay, :discard, 1), do: Overlay.discard(overlay)



    if critique.approved? do

      Logger.debug("[Aletheia] Path approved with #{iterations_left} iterations left.")

      plan

    else

      Logger.debug("[Aletheia] Path rejected. Revising... Feedback: #{critique.feedback}")

      {:ok, revised_plan} = Aletheia.revise_plan(plan, critique.feedback, objective)

      

      # Recurse for the next refinement iteration

      refine_loop(revised_plan, objective, base_sandbox, iterations_left - 1)

    end

  end

end



```



### 2. Define the LLM Personas



Create a new file `lib/orchid/llm/aletheia.ex`. A core finding of the DeepMind paper is that if an LLM generates and verifies using the same prompt, it suffers from severe confirmation bias. We must decouple the personas and their temperatures.



*(Note: Adjust the `Orchid.LLM` calls to match your exact internal API).*



```elixir

defmodule Orchid.LLM.Aletheia do

  alias Orchid.LLM



  @doc "Generator: Proposes N distinct paths (High Temperature)"

  def generate_paths(objective, num_paths) do

    prompt = """

    You are an expert software architect.

    Objective: "#{objective}"

    

    Generate #{num_paths} completely distinct, step-by-step plans to achieve this goal.

    Take different architectural paths for each.

    Output ONLY a valid JSON array of strings, where each string is a complete plan.

    """

    

    # Higher temperature for diverse path generation

    case LLM.complete(prompt, temperature: 0.8) do

      {:ok, response} -> {:ok, parse_json_safely(response)}

      error -> error

    end

  end



  @doc "Verifier: Adversarially critiques a plan (Low Temperature)"

  def verify_plan(plan, objective, _overlay) do

    # You can inject `_overlay` into the context here so the LLM can use `file_read` 

    # or `file_list` to check if the files it wants to modify actually exist.

    prompt = """

    You are a ruthless, adversarial code reviewer.

    Objective: "#{objective}"

    Candidate Plan: "#{plan}"

    

    Hunt for logical flaws, hallucinated files, missing dependencies, or edge cases.

    Output ONLY valid JSON with format:

    {"approved?": boolean, "feedback": "detailed explanation of flaws, or 'None'"}

    """

    

    # Low temperature for strict analytical checking

    case LLM.complete(prompt, temperature: 0.0) do

      {:ok, response} ->

        parsed = parse_json_safely(response)

        %{

          approved?: Map.get(parsed, "approved?", false),

          feedback: Map.get(parsed, "feedback", "Failed to parse critique.")

        }

      _ ->

        %{approved?: false, feedback: "Failed to parse critique."}

    end

  end



  @doc "Reviser: Fixes the plan based on the Verifier's feedback"

  def revise_plan(plan, feedback, objective) do

    prompt = """

    You are an expert problem solver.

    Objective: "#{objective}"

    Original Plan: "#{plan}"

    Critic Feedback: "#{feedback}"

    

    Rewrite the plan to thoroughly address every issue raised by the critic.

    Output ONLY the new step-by-step plan.

    """

    

    LLM.complete(prompt, temperature: 0.4)

  end



  @doc "Selector: Picks the absolute best plan from the final candidates"

  def select_best_path(objective, paths) do

    paths_text = 

      paths

      |> Enum.with_index(1)

      |> Enum.map(fn {p, i} -> "Plan #{i}:\n#{p}\n---" end)

      |> Enum.join("\n")



    prompt = """

    Objective: "#{objective}"

    Here are the thoroughly refined candidate plans:

    #{paths_text}

    

    Select the safest, most robust plan.

    Output ONLY the exact text of the winning plan.

    """

    

    LLM.complete(prompt, temperature: 0.1)

  end



  defp parse_json_safely(text) do

    text 

    |> String.replace(~r/```json\n?|\n?```/, "") 

    |> String.trim()

    |> Jason.decode!()

  end

end



```



### 3. Expose the Planner as an Agent Tool



Create a new tool so your agent can dynamically decide to trigger a deep Aletheia planning loop when faced with a complex objective.



Create `lib/orchid/tools/plan_aletheia.ex`:



```elixir

defmodule Orchid.Tools.PlanAletheia do

  @behaviour Orchid.Tool



  @impl true

  def spec do

    %{

      name: "plan_aletheia",

      description: "Use this tool to deeply plan complex objectives using a multi-path Generator-Verifier-Reviser loop. Always use this BEFORE executing major tasks or creating multiple sub-goals to ensure a logically sound strategy.",

      parameters: %{

        type: "object",

        properties: %{

          objective: %{

            type: "string",

            description: "The high-level objective to deeply plan for."

          }

        },

        required: ["objective"]

      }

    }

  end



  @impl true

  def call(%{"objective" => objective}, context) do

    # Extract the active sandbox from the agent's context map

    sandbox = Map.get(context, :sandbox)



    case Orchid.Planner.plan(objective, sandbox) do

      {:ok, best_plan} ->

        {:ok, "Aletheia Planning complete. Here is the highly verified optimal plan. Proceed to execute these steps using your `goal_create` tools:\n\n#{best_plan}"}

      {:error, reason} ->

        {:error, "Planning failed: #{inspect(reason)}"}

    end

  end

end



```



### 4. Register the Tool



Finally, register the new tool in your list of available tools (likely in `lib/orchid/agent.ex`, `lib/orchid/tool.ex`, or wherever your tool list is maintained).



```elixir

  def available_tools do

    [

      Orchid.Tools.FileRead,

      Orchid.Tools.FileEdit,

      Orchid.Tools.GoalCreate,

      # ... your other tools

      Orchid.Tools.PlanAletheia # Add the new tool here

    ]

  end



```



### How this Architecture flows inside Orchid:



1. You provide a top-level prompt to the Orchid agent.

2. The agent reads its tools, realizes the prompt is complex, and invokes the `plan_aletheia` tool.

3. `Orchid.Planner` concurrently spins up 3 background `Task`s.

4. Each path is independently verified and revised (using `Sandbox.Overlay` to ensure real code isn't mutated during the "thought" process).

5. The winning plan is returned to the agent in the tool response.

6. The agent reads the rigorous plan, uses `goal_create` to chunk it into your existing system, and executes.
