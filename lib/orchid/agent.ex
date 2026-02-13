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
      :sandbox,
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
  Returns immediately; caller is notified via callback or can poll get_state.
  """
  def run(agent_id, message) do
    cast(agent_id, {:run, message, nil})
  end

  @doc """
  Stream a response from the agent.
  Callback receives chunks as they arrive.
  The caller_pid receives {:agent_done, agent_id, result} when complete.
  """
  def stream(agent_id, message, callback) when is_function(callback, 1) do
    caller = self()
    cast(agent_id, {:run, message, {callback, caller}})
    # Block caller until done, so existing callers keep working
    receive do
      {:agent_done, ^agent_id, result} -> result
    after
      660_000 -> {:error, :timeout}
    end
  end

  @doc """
  Retry the last LLM call without adding a new message.
  Use when the agent failed mid-turn and the last message is already in history.
  """
  def retry(agent_id, callback \\ fn _chunk -> :ok end) do
    caller = self()
    cast(agent_id, {:retry, {callback, caller}})
    receive do
      {:agent_done, ^agent_id, result} -> result
    after
      660_000 -> {:error, :timeout}
    end
  end

  @doc """
  Get the current state of an agent.
  Optional timeout (ms or :infinity, default :infinity).
  """
  def get_state(agent_id, timeout \\ :infinity) do
    call(agent_id, :get_state, timeout)
  end

  @doc """
  List all active agents.
  """
  def list do
    Registry.select(Orchid.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Reset the sandbox for an agent.
  """
  def reset_sandbox(agent_id) do
    call(agent_id, :reset_sandbox)
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

    state =
      if state.project_id do
        case Orchid.Projects.ensure_sandbox(state.project_id) do
          {:ok, _} ->
            sandbox_status = Orchid.Sandbox.status(state.project_id)
            %{state | sandbox: sandbox_status}

          {:error, reason} ->
            Logger.warning("Agent #{id}: sandbox failed to start: #{inspect(reason)}")
            state
        end
      else
        state
      end

    Logger.info("Agent #{id} started, project=#{inspect(state.project_id)}, provider=#{config[:provider]}, model=#{config[:model]}")
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

  def handle_call(:reset_sandbox, _from, state) do
    if state.project_id do
      case Orchid.Sandbox.reset(state.project_id) do
        {:ok, status} ->
          new_state = %{state | sandbox: status}
          Store.put_agent_state(state.id, new_state)
          {:reply, {:ok, status}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_sandbox}, state}
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
  def handle_cast({:retry, notify}, state) do
    # Re-run the LLM without adding a new message (last message already in history)
    state = %{state | status: :thinking}
    Store.put_agent_state(state.id, state)

    agent_pid = self()
    agent_id = state.id

    {callback, caller} =
      case notify do
        {cb, caller_pid} -> {cb, caller_pid}
        nil -> {fn _chunk -> :ok end, nil}
      end

    Task.start(fn ->
      result =
        case run_agent_loop_streaming(state, callback, 10, agent_pid) do
          {:ok, response, new_state} ->
            send(agent_pid, {:work_done, new_state, {:ok, response}})
            {:ok, response}

          {:error, reason, new_state} ->
            send(agent_pid, {:work_done, new_state, {:error, reason}})
            {:error, reason}
        end

      if caller, do: send(caller, {:agent_done, agent_id, result})
    end)

    {:noreply, state}
  end

  def handle_cast({:run, message, notify}, state) do
    state = %{state | status: :thinking}
    state = add_message(state, :user, message)
    Store.put_agent_state(state.id, state)

    agent_pid = self()
    agent_id = state.id

    {callback, caller} =
      case notify do
        {cb, caller_pid} -> {cb, caller_pid}
        nil -> {fn _chunk -> :ok end, nil}
      end

    Task.start(fn ->
      result =
        case run_agent_loop_streaming(state, callback, 10, agent_pid) do
          {:ok, response, new_state} ->
            send(agent_pid, {:work_done, new_state, {:ok, response}})
            {:ok, response}

          {:error, reason, new_state} ->
            send(agent_pid, {:work_done, new_state, {:error, reason}})
            {:error, reason}
        end

      if caller, do: send(caller, {:agent_done, agent_id, result})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:update_status, status}, state) do
    state = %{state | status: status}
    Store.put_agent_state(state.id, state)
    {:noreply, state}
  end

  def handle_info({:work_done, new_state, _result}, _state) do
    new_state = %{new_state | status: :idle}
    Store.put_agent_state(new_state.id, new_state)
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    Store.delete_agent_state(state.id)
    :ok
  end

  # Private functions

  defp via(id), do: {:via, Registry, {Orchid.Registry, id}}

  defp call(agent_id, msg, timeout \\ :infinity) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, msg, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp cast(agent_id, msg) do
    case Registry.lookup(Orchid.Registry, agent_id) do
      [{pid, _}] -> GenServer.cast(pid, msg)
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

  @max_retries 10
  @initial_backoff 2_000

  defp run_agent_loop_streaming(state, callback, max_iterations, agent_pid) do
    do_run_loop_streaming(state, callback, max_iterations, nil, agent_pid)
  end

  defp do_run_loop_streaming(state, _callback, 0, last_response, _agent_pid) do
    {:ok, last_response || "Max iterations reached", state}
  end

  defp do_run_loop_streaming(state, callback, iterations_left, _last_response, agent_pid) do
    context = build_context(state)
    config = build_llm_config(state)

    case llm_call_with_retry(config, context, callback, agent_pid) do
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

        do_run_loop_streaming(state, callback, iterations_left - 1, content, agent_pid)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp llm_call_with_retry(config, context, callback, agent_pid) do
    do_llm_retry(config, context, callback, 0, agent_pid)
  end

  defp do_llm_retry(config, context, callback, attempt, _agent_pid) when attempt >= @max_retries do
    LLM.chat_stream(config, context, callback)
  end

  defp do_llm_retry(config, context, callback, attempt, agent_pid) do
    case LLM.chat_stream(config, context, callback) do
      {:ok, _} = success ->
        success

      {:error, {:api_error, status, _}} when status in [429, 500, 502, 503, 504] ->
        backoff = min(@initial_backoff * :math.pow(2, attempt) |> round(), 30_000)
        Logger.warning("Agent LLM call failed (#{status}), retry #{attempt + 1}/#{@max_retries} in #{backoff}ms")
        if agent_pid, do: send(agent_pid, {:update_status, {:retrying, attempt + 1, @max_retries, status}})
        Process.sleep(backoff)
        if agent_pid, do: send(agent_pid, {:update_status, :thinking})
        do_llm_retry(config, context, callback, attempt + 1, agent_pid)

      {:error, _} = error ->
        error
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

  defp build_llm_config(state) do
    config = state.config

    # For CLI provider, use a UUID session_id and resume if messages exist
    if config[:provider] == :cli do
      # Check if we have previous assistant messages (indicating ongoing conversation)
      has_history = Enum.any?(state.messages, fn msg -> msg.role == :assistant end)

      # Generate a deterministic UUID from agent ID for session
      session_uuid = agent_id_to_uuid(state.id)

      config
      |> Map.put(:session_id, session_uuid)
      |> Map.put(:resume, has_history)
    else
      config
    end
  end

  defp agent_id_to_uuid(agent_id) do
    # Create a deterministic UUID v5-like ID from agent_id
    # Using SHA256 and formatting as UUID
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, agent_id)

    # Format as UUID string
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
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
      tool_name: name,
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
