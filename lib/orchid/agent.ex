defmodule Orchid.Agent do
  @moduledoc """
  GenServer representing a single LLM coding agent.
  Maintains conversation history, attached objects, tool history, and memory.
  """
  use GenServer
  require Logger

  alias Orchid.{Store, Object, LLM}

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :config,
      :project_id,
      messages: [],
      objects: [],
      tool_history: [],
      memory: %{},
      status: :idle
    ]
  end

  # Client API

  @doc """
  Create a new agent with the given configuration.

  ## Config options
  - `:provider` - :anthropic (default) or :openai
  - `:model` - model name (default: "claude-sonnet-4-20250514")
  - `:system_prompt` - system instructions
  - `:api_key` - API key (or reads from env)
  """
  def create(config \\ %{}) do
    id = generate_id()

    # Default to OAuth (uses subscription via .claude_tokens.json)
    config =
      Map.merge(
        %{
          # Uses OAuth tokens (subscription-based)
          provider: :oauth,
          # Can be :sonnet, :haiku, :opus
          model: :opus,
          system_prompt: default_system_prompt()
        },
        config
      )

    case DynamicSupervisor.start_child(
           Orchid.AgentSupervisor,
           {__MODULE__, {id, config}}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Attach objects to the agent's context.
  """
  def attach(agent_id, object_ids) when is_list(object_ids) do
    call(agent_id, {:attach, object_ids})
  end

  def attach(agent_id, object_id) do
    attach(agent_id, [object_id])
  end

  @doc """
  Run the agent with a user message.
  Executes the agent loop: LLM call -> tool calls -> repeat until done.
  """
  def run(agent_id, message) do
    call(agent_id, {:run, message})
  end

  @doc """
  Stream a response from the agent.
  Callback receives chunks as they arrive.
  """
  def stream(agent_id, message, callback) when is_function(callback, 1) do
    call(agent_id, {:stream, message, callback})
  end

  @doc """
  Get the current state of an agent.
  """
  def get_state(agent_id) do
    call(agent_id, :get_state)
  end

  @doc """
  List all active agents.
  """
  def list do
    Registry.select(Orchid.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Stop an agent.
  """
  def stop(agent_id) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Add a message to agent memory.
  """
  def remember(agent_id, key, value) do
    call(agent_id, {:remember, key, value})
  end

  @doc """
  Recall from agent memory.
  """
  def recall(agent_id, key) do
    call(agent_id, {:recall, key})
  end

  # GenServer callbacks

  def start_link({id, config}) do
    GenServer.start_link(__MODULE__, {id, config}, name: via(id))
  end

  def child_spec({id, config}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{id, config}]},
      restart: :temporary
    }
  end

  @impl true
  def init({id, config}) do
    state = %State{
      id: id,
      config: config,
      project_id: config[:project_id]
    }

    Store.put_agent_state(id, state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:attach, object_ids}, _from, state) do
    # Verify all objects exist
    valid_ids =
      Enum.filter(object_ids, fn id ->
        case Object.get(id) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    new_objects = Enum.uniq(state.objects ++ valid_ids)
    state = %{state | objects: new_objects}
    Store.put_agent_state(state.id, state)
    {:reply, :ok, state}
  end

  def handle_call({:run, message}, _from, state) do
    state = %{state | status: :thinking}
    state = add_message(state, :user, message)

    case run_agent_loop(state) do
      {:ok, response, new_state} ->
        new_state = %{new_state | status: :idle}
        Store.put_agent_state(new_state.id, new_state)
        {:reply, {:ok, response}, new_state}

      {:error, reason, new_state} ->
        new_state = %{new_state | status: :idle}
        Store.put_agent_state(new_state.id, new_state)
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:stream, message, callback}, _from, state) do
    state = %{state | status: :thinking}
    state = add_message(state, :user, message)

    case run_agent_loop_streaming(state, callback) do
      {:ok, response, new_state} ->
        new_state = %{new_state | status: :idle}
        Store.put_agent_state(new_state.id, new_state)
        {:reply, {:ok, response}, new_state}

      {:error, reason, new_state} ->
        new_state = %{new_state | status: :idle}
        Store.put_agent_state(new_state.id, new_state)
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:remember, key, value}, _from, state) do
    state = %{state | memory: Map.put(state.memory, key, value)}
    Store.put_agent_state(state.id, state)
    {:reply, :ok, state}
  end

  def handle_call({:recall, key}, _from, state) do
    {:reply, Map.get(state.memory, key), state}
  end

  @impl true
  def terminate(_reason, state) do
    Store.delete_agent_state(state.id)
    :ok
  end

  # Private functions

  defp via(id), do: {:via, Registry, {Orchid.Registry, id}}

  defp call(agent_id, msg) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, msg, :infinity)
      [] -> {:error, :not_found}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp add_message(state, role, content) do
    message = %{role: role, content: content, timestamp: DateTime.utc_now()}
    %{state | messages: state.messages ++ [message]}
  end

  defp add_assistant_message(state, content, tool_calls \\ nil) do
    message = %{
      role: :assistant,
      content: content,
      tool_calls: tool_calls,
      timestamp: DateTime.utc_now()
    }

    %{state | messages: state.messages ++ [message]}
  end

  defp run_agent_loop(state, max_iterations \\ 10) do
    do_run_loop(state, max_iterations, nil)
  end

  defp do_run_loop(state, 0, last_response) do
    {:ok, last_response || "Max iterations reached", state}
  end

  defp do_run_loop(state, iterations_left, _last_response) do
    context = build_context(state)

    case LLM.chat(state.config, context) do
      {:ok, %{content: content, tool_calls: nil}} ->
        state = add_assistant_message(state, content)
        {:ok, content, state}

      {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) ->
        state = add_assistant_message(state, content, tool_calls)
        state = %{state | status: :executing_tool}

        # Execute each tool call
        {state, tool_results} = execute_tool_calls(state, tool_calls)

        # Add tool results as messages
        state =
          Enum.reduce(tool_results, state, fn result, acc ->
            add_message(acc, :tool, result)
          end)

        # Continue the loop
        do_run_loop(state, iterations_left - 1, content)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp run_agent_loop_streaming(state, callback, max_iterations \\ 10) do
    do_run_loop_streaming(state, callback, max_iterations, nil)
  end

  defp do_run_loop_streaming(state, _callback, 0, last_response) do
    {:ok, last_response || "Max iterations reached", state}
  end

  defp do_run_loop_streaming(state, callback, iterations_left, _last_response) do
    context = build_context(state)

    case LLM.chat_stream(state.config, context, callback) do
      {:ok, %{content: content, tool_calls: nil}} ->
        state = add_assistant_message(state, content)
        {:ok, content, state}

      {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) ->
        state = add_assistant_message(state, content, tool_calls)
        state = %{state | status: :executing_tool}

        {state, tool_results} = execute_tool_calls(state, tool_calls)

        state =
          Enum.reduce(tool_results, state, fn result, acc ->
            add_message(acc, :tool, result)
          end)

        do_run_loop_streaming(state, callback, iterations_left - 1, content)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_context(state) do
    # Build context with attached objects
    object_context =
      state.objects
      |> Enum.map(&Object.get/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, obj} ->
        "[Object: #{obj.name} (#{obj.type})]\n#{obj.content}"
      end)
      |> Enum.join("\n\n")

    %{
      system: state.config.system_prompt,
      objects: object_context,
      messages: state.messages,
      memory: state.memory
    }
  end

  defp execute_tool_calls(state, tool_calls) do
    Enum.reduce(tool_calls, {state, []}, fn tool_call, {acc_state, results} ->
      {new_state, result} = execute_tool(acc_state, tool_call)
      {new_state, results ++ [result]}
    end)
  end

  defp execute_tool(state, %{name: name, arguments: args, id: tool_id}) do
    result = Orchid.Tool.execute(name, args, %{agent_state: state})

    tool_record = %{
      id: tool_id,
      tool: name,
      args: args,
      result: result,
      timestamp: DateTime.utc_now()
    }

    state = %{state | tool_history: state.tool_history ++ [tool_record]}

    formatted_result = %{
      tool_use_id: tool_id,
      content: format_tool_result(result)
    }

    {state, formatted_result}
  end

  defp format_tool_result({:ok, value}) when is_binary(value), do: value
  defp format_tool_result({:ok, value}), do: inspect(value)
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

  defp default_system_prompt do
    """
    You are an expert coding assistant. You help users by reading, understanding, and modifying code.

    You have access to objects (files, artifacts, functions) that you can read and modify.
    Use the available tools to accomplish tasks.

    Be concise and focus on solving the user's problem efficiently.
    """
  end
end
