defmodule Orchid.LLM.ClaudeSDK do
  @moduledoc """
  Claude Agent SDK client via Python port.
  Uses Claude subscription (Pro/Max) instead of API billing.

  Requires:
  - Python 3.10+
  - claude-code-sdk package: `pip install claude-code-sdk`
  - Logged in via: `claude login`
  """
  use GenServer
  require Logger

  @python_script Path.join(:code.priv_dir(:orchid), "python/claude_agent.py")

  defmodule State do
    defstruct [:port, :caller, :buffer, :callback]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a query using the Claude subscription.
  Returns streamed responses.
  """
  def query(prompt, opts \\ []) do
    GenServer.call(__MODULE__, {:query, prompt, opts}, :infinity)
  end

  @doc """
  Stream a query, calling the callback for each chunk.
  """
  def stream(prompt, callback, opts \\ []) when is_function(callback, 1) do
    GenServer.call(__MODULE__, {:stream, prompt, callback, opts}, :infinity)
  end

  @doc """
  Check if the Python bridge is responsive.
  """
  def ping do
    GenServer.call(__MODULE__, :ping, 5000)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    case start_python_port() do
      {:ok, port} ->
        {:ok, %State{port: port, buffer: ""}}

      {:error, reason} ->
        Logger.warning("Failed to start Claude SDK port: #{inspect(reason)}")
        {:ok, %State{port: nil, buffer: ""}}
    end
  end

  @impl true
  def handle_call({:query, prompt, opts}, from, %{port: nil} = state) do
    # Try to start the port if not running
    case start_python_port() do
      {:ok, port} ->
        handle_call({:query, prompt, opts}, from, %{state | port: port})

      {:error, reason} ->
        {:reply, {:error, {:port_not_started, reason}}, state}
    end
  end

  def handle_call({:query, prompt, opts}, from, state) do
    cmd = build_command(prompt, opts)
    send_command(state.port, cmd)
    {:noreply, %{state | caller: from, buffer: "", callback: nil}}
  end

  def handle_call({:stream, prompt, callback, opts}, from, %{port: nil} = state) do
    case start_python_port() do
      {:ok, port} ->
        handle_call({:stream, prompt, callback, opts}, from, %{state | port: port})

      {:error, reason} ->
        {:reply, {:error, {:port_not_started, reason}}, state}
    end
  end

  def handle_call({:stream, prompt, callback, opts}, from, state) do
    cmd = build_command(prompt, opts)
    send_command(state.port, cmd)
    {:noreply, %{state | caller: from, buffer: "", callback: callback}}
  end

  def handle_call(:ping, _from, %{port: nil} = state) do
    {:reply, {:error, :port_not_started}, state}
  end

  def handle_call(:ping, from, state) do
    send_command(state.port, %{action: "ping"})
    {:noreply, %{state | caller: from, buffer: ""}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line, state)
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Claude SDK port exited with status #{status}")

    if state.caller do
      GenServer.reply(state.caller, {:error, {:port_exited, status}})
    end

    {:noreply, %{state | port: nil, caller: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp start_python_port do
    python = System.find_executable("python3") || System.find_executable("python")

    unless python do
      {:error, :python_not_found}
    else
      unless File.exists?(@python_script) do
        {:error, :script_not_found}
      else
        port =
          Port.open(
            {:spawn_executable, python},
            [
              {:args, [@python_script]},
              :binary,
              :use_stdio,
              {:line, 65536},
              :exit_status
            ]
          )

        {:ok, port}
      end
    end
  end

  defp send_command(port, cmd) do
    json = Jason.encode!(cmd) <> "\n"
    Port.command(port, json)
  end

  defp build_command(prompt, opts) do
    %{
      action: "query",
      prompt: prompt,
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.get(opts, :system_prompt)
    }
  end

  defp handle_line(line, state) do
    full_line = state.buffer <> line

    case Jason.decode(full_line) do
      {:ok, %{"type" => "done"}} ->
        if state.caller do
          GenServer.reply(state.caller, :ok)
        end

        {:noreply, %{state | caller: nil, buffer: "", callback: nil}}

      {:ok, %{"type" => "pong"}} ->
        if state.caller do
          GenServer.reply(state.caller, :ok)
        end

        {:noreply, %{state | caller: nil, buffer: ""}}

      {:ok, %{"type" => "error", "content" => error}} ->
        if state.caller do
          GenServer.reply(state.caller, {:error, error})
        end

        {:noreply, %{state | caller: nil, buffer: "", callback: nil}}

      {:ok, %{"type" => "result"}} ->
        # Result message - just continue, done will follow
        {:noreply, %{state | buffer: ""}}

      {:ok, %{"type" => type, "content" => content} = msg} ->
        # Stream content to callback if provided
        if state.callback && content do
          state.callback.(%{type: type, content: content, tool_use: msg["tool_use"]})
        end

        {:noreply, %{state | buffer: ""}}

      {:ok, other} ->
        # Unknown message type, log it
        IO.inspect(other, label: "SDK unknown message")
        {:noreply, %{state | buffer: ""}}

      {:error, _} ->
        # Incomplete JSON, keep buffering
        {:noreply, %{state | buffer: full_line}}
    end
  end
end
