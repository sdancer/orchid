defmodule OrchidWeb.AgentLive do
  use Phoenix.LiveView

  @impl true
  def mount(params, _session, socket) do
    agent_id = params["id"]

    socket = socket
    |> assign(:agents, Orchid.Agent.list())
    |> assign(:current_agent, agent_id)
    |> assign(:messages, [])
    |> assign(:input, "")
    |> assign(:streaming, false)
    |> assign(:stream_content, "")
    |> assign(:model, :opus)

    socket = if agent_id do
      case Orchid.Agent.get_state(agent_id) do
        {:ok, state} ->
          assign(socket, :messages, format_messages(state.messages))
        _ ->
          socket
      end
    else
      socket
    end

    {:ok, socket}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg.role, content: msg.content, tool_calls: msg[:tool_calls]}
    end)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    agent_id = params["id"]

    socket = socket
    |> assign(:current_agent, agent_id)
    |> assign(:agents, Orchid.Agent.list())

    socket = if agent_id do
      case Orchid.Agent.get_state(agent_id) do
        {:ok, state} ->
          assign(socket, :messages, format_messages(state.messages))
        _ ->
          assign(socket, :messages, [])
      end
    else
      assign(socket, :messages, [])
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("create_agent", _params, socket) do
    {:ok, agent_id} = Orchid.Agent.create(%{model: socket.assigns.model})
    {:noreply, push_patch(socket, to: "/agent/#{agent_id}")}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/agent/#{id}")}
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    Orchid.Agent.stop(id)
    # Small delay to ensure Registry is updated after process terminates
    Process.sleep(50)
    socket = socket
    |> assign(:agents, Orchid.Agent.list())
    |> then(fn s ->
      if s.assigns.current_agent == id do
        push_patch(s, to: "/")
      else
        s
      end
    end)
    {:noreply, socket}
  end

  def handle_event("update_input", %{"input" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("update_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :model, String.to_existing_atom(model))}
  end

  def handle_event("send_message", _params, socket) do
    input = String.trim(socket.assigns.input)
    if input == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      agent_id = socket.assigns.current_agent
      messages = socket.assigns.messages ++ [%{role: :user, content: input, tool_calls: nil}]

      socket = socket
      |> assign(:messages, messages)
      |> assign(:input, "")
      |> assign(:streaming, true)
      |> assign(:stream_content, "")
      |> assign(:retry_count, 0)
      |> assign(:last_input, input)

      start_stream(socket, agent_id, input)
      {:noreply, socket}
    end
  end

  defp start_stream(socket, agent_id, input) do
    pid = self()
    Task.start(fn ->
      callback = fn chunk ->
        send(pid, {:stream_chunk, chunk})
      end

      case Orchid.Agent.stream(agent_id, input, callback) do
        {:ok, _} -> send(pid, :stream_done)
        {:error, reason} -> send(pid, {:stream_error, reason})
      end
    end)
  end

  @impl true
  def handle_info({:stream_chunk, chunk}, socket) do
    content = socket.assigns.stream_content <> chunk
    {:noreply, assign(socket, :stream_content, content)}
  end

  def handle_info(:stream_done, socket) do
    messages = socket.assigns.messages ++ [%{role: :assistant, content: socket.assigns.stream_content, tool_calls: nil}]
    socket = socket
    |> assign(:messages, messages)
    |> assign(:streaming, false)
    |> assign(:stream_content, "")
    {:noreply, socket}
  end

  def handle_info({:stream_error, reason}, socket) do
    retry_count = socket.assigns[:retry_count] || 0

    if retry_count < 3 do
      # Show retry message and schedule retry
      error_msg = format_error(reason)
      messages = socket.assigns.messages ++ [%{role: :error, content: "#{error_msg} - Retrying in 10s (#{retry_count + 1}/3)...", tool_calls: nil}]
      socket = socket
      |> assign(:messages, messages)
      |> assign(:retry_count, retry_count + 1)
      |> assign(:stream_content, "")

      # Schedule retry
      Process.send_after(self(), :retry_stream, 10_000)
      {:noreply, socket}
    else
      # Max retries reached
      error_msg = format_error(reason)
      messages = socket.assigns.messages ++ [%{role: :error, content: "#{error_msg} - Max retries reached.", tool_calls: nil}]
      socket = socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      {:noreply, socket}
    end
  end

  def handle_info(:retry_stream, socket) do
    agent_id = socket.assigns.current_agent
    input = socket.assigns[:last_input] || ""
    start_stream(socket, agent_id, input)
    {:noreply, socket}
  end

  defp format_error({:api_error, status, body}) do
    "API Error #{status}: #{inspect(body)}"
  end
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="header">
      <h1>Orchid</h1>
      <div style="display: flex; gap: 0.5rem; align-items: center;">
        <select class="model-select" phx-change="update_model" name="model">
          <option value="opus" selected={@model == :opus}>Opus</option>
          <option value="sonnet" selected={@model == :sonnet}>Sonnet</option>
          <option value="haiku" selected={@model == :haiku}>Haiku</option>
        </select>
        <button class="btn" phx-click="create_agent">New Agent</button>
      </div>
    </div>

    <%= if @current_agent do %>
      <div class="chat-container">
        <div class="messages" id="messages" phx-hook="ScrollBottom">
          <%= for msg <- @messages do %>
            <%= case msg.role do %>
              <% :user -> %>
                <div class="message user">
                  <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                </div>
              <% :assistant -> %>
                <%= if msg.content && msg.content != "" do %>
                  <div class="message assistant">
                    <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                  </div>
                <% end %>
                <%= if msg[:tool_calls] do %>
                  <%= for tc <- msg[:tool_calls] do %>
                    <div class="message tool-call">
                      <div class="tool-name"><%= tc.name %></div>
                      <pre class="tool-args"><%= format_tool_args(tc.arguments) %></pre>
                    </div>
                  <% end %>
                <% end %>
              <% :tool -> %>
                <div class="message tool-result">
                  <pre><%= format_tool_result(msg.content) %></pre>
                </div>
              <% :error -> %>
                <div class="message error">
                  <div style="white-space: pre-wrap;"><%= msg.content %></div>
                </div>
              <% _ -> %>
                <div class="message">
                  <div style="white-space: pre-wrap;"><%= format_content(msg.content) %></div>
                </div>
            <% end %>
          <% end %>
          <%= if @streaming and @stream_content != "" do %>
            <div class="message assistant">
              <div style="white-space: pre-wrap;"><%= @stream_content %><span class="streaming-cursor"></span></div>
            </div>
          <% end %>
        </div>
        <form class="input-area" phx-submit="send_message" phx-change="update_input">
          <textarea
            rows="2"
            placeholder="Type a message... (Ctrl+Enter to send)"
            id="message-input"
            phx-hook="CtrlEnterSubmit"
            name="input"
            value={@input}
            disabled={@streaming}
          ><%= @input %></textarea>
          <button class="btn" type="submit" disabled={@streaming}>
            <%= if @streaming, do: "...", else: "Send" %>
          </button>
        </form>
      </div>
    <% else %>
      <p style="color: #8b949e; margin-bottom: 1rem;">Select an agent or create a new one to start chatting.</p>
      <div class="agent-list">
        <%= for agent_id <- @agents do %>
          <div class="agent-card">
            <h3><%= agent_id %></h3>
            <div class="status">Active</div>
            <div class="actions">
              <button class="btn btn-secondary" phx-click="select_agent" phx-value-id={agent_id}>Open</button>
              <button class="btn btn-danger" phx-click="stop_agent" phx-value-id={agent_id}>Stop</button>
            </div>
          </div>
        <% end %>
        <%= if @agents == [] do %>
          <p style="color: #8b949e;">No active agents. Create one to get started.</p>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp format_content(content) when is_binary(content), do: content
  defp format_content(content), do: inspect(content)

  defp format_tool_args(args) when is_map(args) do
    Jason.encode!(args, pretty: true)
  end
  defp format_tool_args(args), do: inspect(args, pretty: true)

  defp format_tool_result(%{content: content}), do: truncate(content, 500)
  defp format_tool_result(content) when is_binary(content), do: truncate(content, 500)
  defp format_tool_result(content), do: truncate(inspect(content), 500)

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end
  defp truncate(str, _max), do: str
end
