defmodule OrchidWeb.AgentLive do
  use Phoenix.LiveView

  @impl true
  def mount(params, _session, socket) do
    agent_id = params["id"]

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> assign(:current_agent, agent_id)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:model, :opus)
      |> assign(:provider, :cli)
      |> assign(:projects, Orchid.Object.list_projects())
      |> assign(:project_query, "")
      |> assign(:current_project, nil)
      |> assign(:creating_project, false)
      |> assign(:new_project_name, "")
      |> assign(:goals, [])
      |> assign(:creating_goal, false)
      |> assign(:new_goal_name, "")
      |> assign(:editing_goal, nil)
      |> assign(:adding_dependency_to, nil)
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> assign(:selected_template, nil)
      |> assign(:current_agent_template, nil)
      |> assign(:creating_template, false)
      |> assign(:template_name, "")
      |> assign(:template_model, :opus)
      |> assign(:template_provider, :cli)
      |> assign(:template_system_prompt, "")

    socket =
      if agent_id do
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

    socket =
      socket
      |> assign(:current_agent, agent_id)
      |> assign(:agents, list_agents_with_info())

    socket =
      if agent_id do
        case Orchid.Agent.get_state(agent_id) do
          {:ok, state} ->
            template_info = get_template_info(state.config[:template_id])

            socket
            |> assign(:messages, format_messages(state.messages))
            |> assign(:current_agent_template, template_info)

          _ ->
            socket
            |> assign(:messages, [])
            |> assign(:current_agent_template, nil)
        end
      else
        socket
        |> assign(:messages, [])
        |> assign(:current_agent_template, nil)
      end

    {:noreply, socket}
  end

  defp get_template_info(nil), do: nil

  defp get_template_info(template_id) do
    case Orchid.Object.get(template_id) do
      {:ok, template} ->
        %{
          id: template.id,
          name: template.name,
          model: template.metadata[:model],
          provider: template.metadata[:provider]
        }

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("create_agent", _params, socket) do
    # Start with defaults or template values
    config =
      case socket.assigns.selected_template do
        nil ->
          %{
            model: socket.assigns.model,
            provider: socket.assigns.provider
          }

        template_id ->
          case Orchid.Object.get(template_id) do
            {:ok, template} ->
              %{
                model: template.metadata[:model] || socket.assigns.model,
                provider: template.metadata[:provider] || socket.assigns.provider,
                system_prompt: template.content,
                template_id: template_id
              }

            _ ->
              %{model: socket.assigns.model, provider: socket.assigns.provider}
          end
      end

    config =
      if socket.assigns.current_project do
        Map.put(config, :project_id, socket.assigns.current_project)
      else
        config
      end

    {:ok, agent_id} = Orchid.Agent.create(config)
    {:noreply, push_patch(socket, to: "/agent/#{agent_id}")}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/agent/#{id}")}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, push_patch(socket, to: "/")}
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    Orchid.Agent.stop(id)
    # Small delay to ensure Registry is updated after process terminates
    Process.sleep(50)

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
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

  def handle_event("update_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :provider, String.to_existing_atom(provider))}
  end

  # Template events
  def handle_event("select_template", %{"id" => ""}, socket) do
    {:noreply, assign(socket, :selected_template, nil)}
  end

  def handle_event("select_template", %{"id" => id}, socket) do
    socket =
      case Orchid.Object.get(id) do
        {:ok, template} ->
          socket
          |> assign(:selected_template, id)
          |> assign(:model, template.metadata[:model] || :opus)
          |> assign(:provider, template.metadata[:provider] || :cli)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("show_create_template", _params, socket) do
    # If a template is selected, use its values as starting point
    {model, provider, prompt} =
      case socket.assigns.selected_template do
        nil ->
          {socket.assigns.model, socket.assigns.provider, ""}

        template_id ->
          case Orchid.Object.get(template_id) do
            {:ok, template} ->
              {
                template.metadata[:model] || :opus,
                template.metadata[:provider] || :cli,
                template.content || ""
              }

            _ ->
              {socket.assigns.model, socket.assigns.provider, ""}
          end
      end

    {:noreply,
     assign(socket,
       creating_template: true,
       template_name: "",
       template_model: model,
       template_provider: provider,
       template_system_prompt: prompt
     )}
  end

  def handle_event("cancel_create_template", _params, socket) do
    {:noreply, assign(socket, creating_template: false)}
  end

  def handle_event("update_template_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :template_name, name)}
  end

  def handle_event("update_template_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, :template_model, String.to_existing_atom(model))}
  end

  def handle_event("update_template_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :template_provider, String.to_existing_atom(provider))}
  end

  def handle_event("update_template_system_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :template_system_prompt, prompt)}
  end

  def handle_event("create_template", _params, socket) do
    name = String.trim(socket.assigns.template_name)
    prompt = socket.assigns.template_system_prompt

    if name != "" do
      {:ok, _template} =
        Orchid.Object.create(:agent_template, name, prompt,
          metadata: %{
            model: socket.assigns.template_model,
            provider: socket.assigns.template_provider
          }
        )

      {:noreply,
       assign(socket,
         templates: Orchid.Object.list_agent_templates(),
         creating_template: false,
         template_name: "",
         template_system_prompt: ""
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_template", %{"id" => id}, socket) do
    Orchid.Object.delete(id)

    socket =
      socket
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> then(fn s ->
        if s.assigns.selected_template == id do
          assign(s, :selected_template, nil)
        else
          s
        end
      end)

    {:noreply, socket}
  end

  def handle_event("search_projects", %{"query" => query}, socket) do
    {:noreply, assign(socket, :project_query, query)}
  end

  def handle_event("select_project", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:current_project, id)
     |> assign(:goals, Orchid.Object.list_goals_for_project(id))}
  end

  def handle_event("clear_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_project, nil)
     |> assign(:goals, [])}
  end

  def handle_event("show_new_project", _params, socket) do
    {:noreply, assign(socket, creating_project: true, new_project_name: "")}
  end

  def handle_event("cancel_new_project", _params, socket) do
    {:noreply, assign(socket, creating_project: false)}
  end

  def handle_event("update_new_project_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_project_name, name)}
  end

  def handle_event("create_project", _params, socket) do
    name = String.trim(socket.assigns.new_project_name)

    if name != "" do
      {:ok, project} = Orchid.Object.create(:project, name, "")

      {:noreply,
       assign(socket,
         projects: Orchid.Object.list_projects(),
         creating_project: false,
         new_project_name: "",
         current_project: project.id
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    Orchid.Object.delete(id)

    socket =
      socket
      |> assign(:projects, Orchid.Object.list_projects())
      |> then(fn s ->
        if s.assigns.current_project == id do
          assign(s, :current_project, nil)
        else
          s
        end
      end)

    {:noreply, socket}
  end

  # Goal events
  def handle_event("show_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: true, new_goal_name: "")}
  end

  def handle_event("cancel_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: false, new_goal_name: "")}
  end

  def handle_event("update_new_goal_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_goal_name, name)}
  end

  def handle_event("create_goal", _params, socket) do
    name = String.trim(socket.assigns.new_goal_name)
    project_id = socket.assigns.current_project

    if name != "" and project_id do
      {:ok, _goal} =
        Orchid.Object.create(:goal, name, "", metadata: %{
          project_id: project_id,
          status: :pending,
          depends_on: []
        })

      {:noreply,
       assign(socket,
         goals: Orchid.Object.list_goals_for_project(project_id),
         creating_goal: false,
         new_goal_name: ""
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_goal_status", %{"id" => id, "status" => status}, socket) do
    status_atom = String.to_existing_atom(status)
    {:ok, _} = Orchid.Object.update_metadata(id, %{status: status_atom})

    {:noreply,
     assign(socket, :goals, Orchid.Object.list_goals_for_project(socket.assigns.current_project))}
  end

  def handle_event("toggle_goal_status", %{"id" => id}, socket) do
    case Orchid.Object.get(id) do
      {:ok, goal} ->
        new_status =
          case goal.metadata[:status] do
            :completed -> :pending
            _ -> :completed
          end

        {:ok, _} = Orchid.Object.update_metadata(id, %{status: new_status})

        {:noreply,
         assign(socket, :goals, Orchid.Object.list_goals_for_project(socket.assigns.current_project))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    # Remove this goal from any depends_on lists
    goals = socket.assigns.goals

    for goal <- goals do
      depends_on = goal.metadata[:depends_on] || []

      if id in depends_on do
        Orchid.Object.update_metadata(goal.id, %{depends_on: List.delete(depends_on, id)})
      end
    end

    Orchid.Object.delete(id)

    {:noreply,
     assign(socket, :goals, Orchid.Object.list_goals_for_project(socket.assigns.current_project))}
  end

  def handle_event("start_add_dependency", %{"id" => id}, socket) do
    {:noreply, assign(socket, :adding_dependency_to, id)}
  end

  def handle_event("cancel_add_dependency", _params, socket) do
    {:noreply, assign(socket, :adding_dependency_to, nil)}
  end

  def handle_event("add_dependency", %{"goal-id" => goal_id, "depends-on" => depends_on_id}, socket) do
    case Orchid.Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []

        if depends_on_id not in current_deps do
          {:ok, _} = Orchid.Object.update_metadata(goal_id, %{depends_on: [depends_on_id | current_deps]})
        end

        {:noreply,
         socket
         |> assign(:goals, Orchid.Object.list_goals_for_project(socket.assigns.current_project))
         |> assign(:adding_dependency_to, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_dependency", %{"goal-id" => goal_id, "depends-on" => depends_on_id}, socket) do
    case Orchid.Object.get(goal_id) do
      {:ok, goal} ->
        current_deps = goal.metadata[:depends_on] || []
        {:ok, _} = Orchid.Object.update_metadata(goal_id, %{depends_on: List.delete(current_deps, depends_on_id)})

        {:noreply,
         assign(socket, :goals, Orchid.Object.list_goals_for_project(socket.assigns.current_project))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("send_message", _params, socket) do
    input = String.trim(socket.assigns.input)

    if input == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      agent_id = socket.assigns.current_agent
      messages = socket.assigns.messages ++ [%{role: :user, content: input, tool_calls: nil}]

      socket =
        socket
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

  defp start_stream(_socket, agent_id, input) do
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
    messages =
      socket.assigns.messages ++
        [%{role: :assistant, content: socket.assigns.stream_content, tool_calls: nil}]

    socket =
      socket
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

      messages =
        socket.assigns.messages ++
          [
            %{
              role: :error,
              content: "#{error_msg} - Retrying in 10s (#{retry_count + 1}/3)...",
              tool_calls: nil
            }
          ]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:retry_count, retry_count + 1)
        |> assign(:stream_content, "")

      # Schedule retry
      Process.send_after(self(), :retry_stream, 10_000)
      {:noreply, socket}
    else
      # Max retries reached
      error_msg = format_error(reason)

      messages =
        socket.assigns.messages ++
          [%{role: :error, content: "#{error_msg} - Max retries reached.", tool_calls: nil}]

      socket =
        socket
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
    <div class="app-layout">
      <div class="sidebar">
        <div class="sidebar-header">
          <h2>Projects</h2>
          <form phx-change="search_projects">
            <input
              type="text"
              name="query"
              class="sidebar-search"
              placeholder="Search projects..."
              value={@project_query}
              phx-debounce="150"
            />
          </form>
        </div>
        <div class="sidebar-content">
          <%= if @creating_project do %>
            <form phx-submit="create_project" phx-change="update_new_project_name" style="padding: 0.5rem;">
              <input
                type="text"
                name="name"
                value={@new_project_name}
                placeholder="Project name"
                class="sidebar-search"
                style="margin-bottom: 0.5rem;"
                autofocus
              />
              <div style="display: flex; gap: 0.25rem;">
                <button type="submit" class="btn btn-sm">Create</button>
                <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_project">Cancel</button>
              </div>
            </form>
          <% else %>
            <%= if @current_project do %>
              <div class="project-item active" style="margin-bottom: 0.5rem;">
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= get_project_name(@projects, @current_project) %></span>
                <button
                  class="btn btn-secondary btn-sm"
                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                  phx-click="clear_project"
                >×</button>
              </div>
            <% end %>
            <%= for project <- filter_projects(@projects, @project_query, @current_project) do %>
              <div
                class="project-item"
                phx-click="select_project"
                phx-value-id={project.id}
              >
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= project.name %></span>
                <button
                  class="btn btn-danger btn-sm"
                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem; opacity: 0.7;"
                  phx-click="delete_project"
                  phx-value-id={project.id}
                >×</button>
              </div>
            <% end %>
            <%= if @projects == [] and not @creating_project do %>
              <div class="no-projects">No projects yet</div>
            <% end %>
          <% end %>
        </div>
        <div class="sidebar-footer">
          <button class="btn btn-secondary" phx-click="show_new_project">+ New Project</button>
        </div>
      </div>

      <div class="main-content">
        <div class="container">
          <div class="header">
            <div style="display: flex; align-items: center; gap: 1rem;">
              <%= if @current_agent do %>
                <button class="btn btn-secondary" style="padding: 0.4rem 0.6rem;" phx-click="go_home">&larr;</button>
              <% end %>
              <h1>Orchid</h1>
            </div>
            <div style="display: flex; gap: 0.5rem; align-items: center;">
              <select class="model-select" phx-change="select_template" name="id" title="Template">
                <option value="" selected={@selected_template == nil}>No Template</option>
                <%= for template <- @templates do %>
                  <option value={template.id} selected={@selected_template == template.id}>
                    <%= template.name %>
                  </option>
                <% end %>
              </select>
              <button class="btn btn-secondary" phx-click="show_create_template" title="New Template" style="padding: 0.4rem 0.6rem;">+T</button>
              <button class="btn" phx-click="create_agent">New Agent</button>
            </div>
          </div>

          <%= if @creating_template do %>
            <div class="template-form" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
              <h3 style="color: #c9d1d9; margin: 0 0 1rem 0;">Create Agent Template</h3>
              <form phx-submit="create_template">
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Name</label>
                  <input
                    type="text"
                    name="name"
                    value={@template_name}
                    phx-change="update_template_name"
                    placeholder="Template name"
                    class="sidebar-search"
                    style="width: 100%;"
                    autofocus
                  />
                </div>
                <div style="display: flex; gap: 0.75rem; margin-bottom: 0.75rem;">
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Provider</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_provider" name="provider">
                      <option value="cli" selected={@template_provider == :cli}>CLI</option>
                      <option value="oauth" selected={@template_provider == :oauth}>API</option>
                    </select>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Model</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_model" name="model">
                      <option value="opus" selected={@template_model == :opus}>Opus</option>
                      <option value="sonnet" selected={@template_model == :sonnet}>Sonnet</option>
                      <option value="haiku" selected={@template_model == :haiku}>Haiku</option>
                    </select>
                  </div>
                </div>
                <div style="margin-bottom: 0.75rem;">
                  <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">System Prompt</label>
                  <textarea
                    name="prompt"
                    phx-change="update_template_system_prompt"
                    placeholder="System prompt for this template..."
                    class="sidebar-search"
                    style="width: 100%; min-height: 150px; resize: vertical;"
                  ><%= @template_system_prompt %></textarea>
                </div>
                <div style="display: flex; gap: 0.5rem;">
                  <button type="submit" class="btn">Create Template</button>
                  <button type="button" class="btn btn-secondary" phx-click="cancel_create_template">Cancel</button>
                </div>
              </form>
            </div>
          <% end %>

          <%= if @current_agent do %>
            <div class="chat-container">
              <%= if @current_agent_template do %>
                <div class="template-header" style="background: #21262d; border-bottom: 1px solid #30363d; padding: 0.5rem 1rem; display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem;">
                  <span style="color: #8b949e;">Template:</span>
                  <span style="color: #58a6ff; font-weight: 500;"><%= @current_agent_template.name %></span>
                  <span style="color: #6e7681;">•</span>
                  <span style="color: #8b949e;"><%= @current_agent_template.provider %> / <%= @current_agent_template.model %></span>
                </div>
              <% end %>
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
            <%= if @current_project do %>
              <div class="project-detail" style="margin-bottom: 1.5rem;">
                <h2 style="color: #c9d1d9; margin-bottom: 1rem;">
                  Project: <%= get_project_name(@projects, @current_project) %>
                </h2>

                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <h3 style="color: #c9d1d9; margin: 0 0 1rem 0; font-size: 1rem;">Goals</h3>

                  <%= if @creating_goal do %>
                    <form phx-submit="create_goal" phx-change="update_new_goal_name" style="margin-bottom: 1rem;">
                      <div style="display: flex; gap: 0.5rem;">
                        <input
                          type="text"
                          name="name"
                          value={@new_goal_name}
                          placeholder="Goal name"
                          class="sidebar-search"
                          style="flex: 1;"
                          autofocus
                        />
                        <button type="submit" class="btn btn-sm">Add</button>
                        <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_goal">Cancel</button>
                      </div>
                    </form>
                  <% end %>

                  <%= if @goals == [] and not @creating_goal do %>
                    <p style="color: #8b949e; margin: 0 0 1rem 0;">No goals yet.</p>
                  <% else %>
                    <div class="goals-list" style="display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 1rem;">
                      <%= for goal <- @goals do %>
                        <div class="goal-item" style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                          <div style="display: flex; align-items: center; gap: 0.5rem;">
                            <button
                              phx-click="toggle_goal_status"
                              phx-value-id={goal.id}
                              style={"width: 1.25rem; height: 1.25rem; border-radius: 3px; border: 1px solid #30363d; background: #{if goal.metadata[:status] == :completed, do: "#238636", else: "transparent"}; cursor: pointer; display: flex; align-items: center; justify-content: center; color: white; font-size: 0.7rem;"}
                            >
                              <%= if goal.metadata[:status] == :completed, do: "✓", else: "" %>
                            </button>
                            <span style={"flex: 1; color: #{if goal.metadata[:status] == :completed, do: "#8b949e", else: "#c9d1d9"}; #{if goal.metadata[:status] == :completed, do: "text-decoration: line-through;", else: ""}"}><%= goal.name %></span>
                            <button
                              class="btn btn-secondary btn-sm"
                              style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                              phx-click="start_add_dependency"
                              phx-value-id={goal.id}
                            >+ dep</button>
                            <button
                              class="btn btn-danger btn-sm"
                              style="padding: 0.15rem 0.4rem; font-size: 0.7rem; opacity: 0.7;"
                              phx-click="delete_goal"
                              phx-value-id={goal.id}
                            >×</button>
                          </div>
                          <%= if (goal.metadata[:depends_on] || []) != [] do %>
                            <div style="margin-top: 0.5rem; margin-left: 1.75rem; font-size: 0.85rem; color: #8b949e;">
                              depends on:
                              <%= for dep_id <- goal.metadata[:depends_on] || [] do %>
                                <span style="display: inline-flex; align-items: center; gap: 0.25rem; background: #21262d; padding: 0.1rem 0.4rem; border-radius: 3px; margin-right: 0.25rem;">
                                  <%= get_goal_name(@goals, dep_id) %>
                                  <button
                                    phx-click="remove_dependency"
                                    phx-value-goal-id={goal.id}
                                    phx-value-depends-on={dep_id}
                                    style="background: none; border: none; color: #f85149; cursor: pointer; padding: 0; font-size: 0.7rem;"
                                  >×</button>
                                </span>
                              <% end %>
                            </div>
                          <% end %>
                          <%= if @adding_dependency_to == goal.id do %>
                            <div style="margin-top: 0.5rem; margin-left: 1.75rem;">
                              <div style="display: flex; flex-wrap: wrap; gap: 0.25rem;">
                                <%= for other_goal <- Enum.filter(@goals, fn g -> g.id != goal.id and g.id not in (goal.metadata[:depends_on] || []) end) do %>
                                  <button
                                    class="btn btn-secondary btn-sm"
                                    style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                    phx-click="add_dependency"
                                    phx-value-goal-id={goal.id}
                                    phx-value-depends-on={other_goal.id}
                                  ><%= other_goal.name %></button>
                                <% end %>
                                <button
                                  class="btn btn-secondary btn-sm"
                                  style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                  phx-click="cancel_add_dependency"
                                >Cancel</button>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <%= if not @creating_goal do %>
                    <button class="btn btn-secondary" phx-click="show_new_goal">+ Add Goal</button>
                  <% end %>
                </div>

                <h3 style="color: #c9d1d9; margin-bottom: 0.5rem;">Agents</h3>
              </div>
            <% end %>

            <p style="color: #8b949e; margin-bottom: 1rem;">
              <%= if @current_project do %>
                Agents for this project:
              <% else %>
                Select an agent or create a new one to start chatting.
              <% end %>
            </p>
            <div class="agent-list">
              <%= for agent <- filter_agents(@agents, @current_project) do %>
                <div class="agent-card">
                  <h3><%= agent.id %></h3>
                  <div class="status">Active</div>
                  <%= if agent.project_id do %>
                    <div class="agent-project">
                      <span class="project-badge"><%= get_project_name(@projects, agent.project_id) %></span>
                    </div>
                  <% end %>
                  <div class="actions">
                    <button class="btn btn-secondary" phx-click="select_agent" phx-value-id={agent.id}>Open</button>
                    <button class="btn btn-danger" phx-click="stop_agent" phx-value-id={agent.id}>Stop</button>
                  </div>
                </div>
              <% end %>
              <%= if filter_agents(@agents, @current_project) == [] do %>
                <p style="color: #8b949e;">No active agents. Create one to get started.</p>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp filter_projects(projects, query, current_project) do
    projects
    |> Enum.reject(fn p -> p.id == current_project end)
    |> Enum.filter(fn p ->
      query == "" or String.contains?(String.downcase(p.name), String.downcase(query))
    end)
  end

  defp get_project_name(projects, id) do
    case Enum.find(projects, fn p -> p.id == id end) do
      nil -> "Unknown"
      project -> project.name
    end
  end

  defp get_goal_name(goals, id) do
    case Enum.find(goals, fn g -> g.id == id end) do
      nil -> "Unknown"
      goal -> goal.name
    end
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

  defp list_agents_with_info do
    Orchid.Agent.list()
    |> Enum.map(fn agent_id ->
      case Orchid.Agent.get_state(agent_id) do
        {:ok, state} -> %{id: agent_id, project_id: state.project_id}
        _ -> %{id: agent_id, project_id: nil}
      end
    end)
  end

  defp filter_agents(agents, nil), do: agents

  defp filter_agents(agents, current_project) do
    Enum.filter(agents, fn agent ->
      agent.project_id == current_project
    end)
  end
end
