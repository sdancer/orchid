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
      |> assign(:pending_message, nil)
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
      |> assign(:new_goal_description, "")
      |> assign(:new_goal_parent, nil)
      |> assign(:editing_goal, nil)
      |> assign(:expanded_goal, nil)
      |> assign(:adding_dependency_to, nil)
      |> assign(:assigning_goal, nil)
      |> assign(:goals_view_mode, :list)
      |> assign(:templates, Orchid.Object.list_agent_templates())
      |> then(fn s ->
        templates = s.assigns.templates
        first_template = List.first(templates)
        assign(s, :selected_template, first_template && first_template.id)
      end)
      |> assign(:current_agent_template, nil)
      |> assign(:creating_template, false)
      |> assign(:template_name, "")
      |> assign(:template_model, :opus)
      |> assign(:template_provider, :cli)
      |> assign(:template_system_prompt, "")
      |> assign(:template_category, "General")
      |> assign(:sandbox_statuses, %{})
      |> assign(:agent_status, :idle)
      |> assign(:system_prompt, nil)
      |> assign(:show_system_prompt, false)

    socket =
      if agent_id do
        case Orchid.Agent.get_state(agent_id, 2000) do
          {:ok, state} ->
            socket
            |> assign(:messages, format_messages(state.messages))
            |> assign(:agent_status, state.status)
            |> assign(:system_prompt, state.config[:system_prompt])

          _ ->
            socket
        end
      else
        socket
      end

    if connected?(socket) do
      Process.send_after(self(), :poll_agent_status, 2000)
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
        case Orchid.Agent.get_state(agent_id, 2000) do
          {:ok, state} ->
            template_info = get_template_info(state.config[:template_id])

            socket
            |> assign(:messages, format_messages(state.messages))
            |> assign(:current_agent_template, template_info)
            |> assign(:system_prompt, state.config[:system_prompt])
            |> assign(:show_system_prompt, false)

          _ ->
            socket
            |> assign(:messages, [])
            |> assign(:current_agent_template, nil)
            |> assign(:system_prompt, nil)
            |> assign(:show_system_prompt, false)
        end
      else
        socket
        |> assign(:messages, [])
        |> assign(:current_agent_template, nil)
        |> assign(:system_prompt, nil)
        |> assign(:show_system_prompt, false)
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
          provider: template.metadata[:provider],
          category: template.metadata[:category] || "General"
        }

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("create_agent", _params, socket) do
    template_id = socket.assigns.selected_template

    # Template is required
    config =
      case Orchid.Object.get(template_id) do
        {:ok, template} ->
          config = %{
            provider: template.metadata[:provider] || :cli,
            system_prompt: template.content,
            template_id: template_id
          }
          if template.metadata[:model],
            do: Map.put(config, :model, template.metadata[:model]),
            else: config

        _ ->
          # Fallback (shouldn't happen with UI validation)
          %{model: :opus, provider: :cli}
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
    # Refresh after a short delay to let Registry update
    Process.send_after(self(), {:refresh_after_stop, id}, 100)
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
  def handle_event("select_template", %{"id" => id}, socket) do
    socket =
      case Orchid.Object.get(id) do
        {:ok, template} ->
          socket
          |> assign(:selected_template, id)
          |> assign(:model, template.metadata[:model])
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
                template.metadata[:model],
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
       template_system_prompt: prompt,
       template_category: "General"
     )}
  end

  def handle_event("cancel_create_template", _params, socket) do
    {:noreply, assign(socket, creating_template: false)}
  end

  def handle_event("update_template_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :template_name, name)}
  end

  def handle_event("update_template_model", %{"model" => ""}, socket) do
    {:noreply, assign(socket, :template_model, nil)}
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

  def handle_event("update_template_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :template_category, category)}
  end

  def handle_event("create_template", _params, socket) do
    name = String.trim(socket.assigns.template_name)
    prompt = socket.assigns.template_system_prompt

    if name != "" do
      {:ok, template} =
        Orchid.Object.create(:agent_template, name, prompt,
          metadata: %{
            model: socket.assigns.template_model,
            provider: socket.assigns.template_provider,
            category: socket.assigns.template_category
          }
        )

      {:noreply,
       assign(socket,
         templates: Orchid.Object.list_agent_templates(),
         selected_template: template.id,
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
     |> assign(:goals, Orchid.Goals.list_for_project(id))
     |> refresh_sandbox_statuses()}
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
      {:ok, project} = Orchid.Projects.create(name)

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
    Orchid.Projects.delete(id)

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

  # Project status events
  def handle_event("pause_project", %{"id" => id}, socket) do
    Orchid.Projects.pause(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("resume_project", %{"id" => id}, socket) do
    Orchid.Projects.resume(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("archive_project", %{"id" => id}, socket) do
    Orchid.Projects.archive(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  def handle_event("restore_project", %{"id" => id}, socket) do
    Orchid.Projects.restore(id)
    {:noreply, assign(socket, :projects, Orchid.Object.list_projects())}
  end

  # Goal events
  def handle_event("show_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: true, new_goal_name: "", new_goal_description: "", new_goal_parent: nil)}
  end

  def handle_event("cancel_new_goal", _params, socket) do
    {:noreply, assign(socket, creating_goal: false, new_goal_name: "", new_goal_description: "", new_goal_parent: nil)}
  end

  def handle_event("update_new_goal_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_goal_name, name)}
  end

  def handle_event("update_new_goal_description", %{"description" => desc}, socket) do
    {:noreply, assign(socket, :new_goal_description, desc)}
  end

  def handle_event("update_new_goal_parent", %{"parent" => ""}, socket) do
    {:noreply, assign(socket, :new_goal_parent, nil)}
  end

  def handle_event("update_new_goal_parent", %{"parent" => parent_id}, socket) do
    {:noreply, assign(socket, :new_goal_parent, parent_id)}
  end

  def handle_event("create_goal", _params, socket) do
    name = String.trim(socket.assigns.new_goal_name)
    project_id = socket.assigns.current_project

    if name != "" and project_id do
      description = String.trim(socket.assigns.new_goal_description)
      Orchid.Goals.create(name, description, project_id, parent_goal_id: socket.assigns.new_goal_parent)

      {:noreply,
       socket
       |> refresh_goals()
       |> assign(creating_goal: false, new_goal_name: "", new_goal_description: "", new_goal_parent: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_goal_status", %{"id" => id, "status" => status}, socket) do
    Orchid.Goals.set_status(id, String.to_existing_atom(status))
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goal_status", %{"id" => id}, socket) do
    Orchid.Goals.toggle_status(id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goal_details", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_goal == id, do: nil, else: id
    {:noreply, assign(socket, :expanded_goal, expanded)}
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    Orchid.Goals.delete(id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("clear_all_goals", _params, socket) do
    if socket.assigns.current_project do
      Orchid.Goals.clear_project(socket.assigns.current_project)
    end

    {:noreply, refresh_goals(socket)}
  end

  def handle_event("start_add_dependency", %{"id" => id}, socket) do
    {:noreply, assign(socket, :adding_dependency_to, id)}
  end

  def handle_event("cancel_add_dependency", _params, socket) do
    {:noreply, assign(socket, :adding_dependency_to, nil)}
  end

  def handle_event("add_dependency", %{"goal-id" => goal_id, "depends-on" => depends_on_id}, socket) do
    Orchid.Goals.add_dependency(goal_id, depends_on_id)

    {:noreply,
     socket
     |> refresh_goals()
     |> assign(:adding_dependency_to, nil)}
  end

  def handle_event("remove_dependency", %{"goal-id" => goal_id, "depends-on" => depends_on_id}, socket) do
    Orchid.Goals.remove_dependency(goal_id, depends_on_id)
    {:noreply, refresh_goals(socket)}
  end

  def handle_event("toggle_goals_view", _params, socket) do
    mode = if socket.assigns.goals_view_mode == :list, do: :graph, else: :list
    {:noreply, assign(socket, :goals_view_mode, mode)}
  end

  def handle_event("start_assign_goal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :assigning_goal, id)}
  end

  def handle_event("cancel_assign_goal", _params, socket) do
    {:noreply, assign(socket, :assigning_goal, nil)}
  end

  def handle_event("assign_goal_to_agent", %{"goal-id" => goal_id, "agent-id" => agent_id}, socket) do
    Orchid.Goals.assign_to_agent(goal_id, agent_id)

    {:noreply,
     socket
     |> refresh_goals()
     |> assign(:assigning_goal, nil)}
  end

  def handle_event("toggle_system_prompt", _params, socket) do
    {:noreply, assign(socket, :show_system_prompt, !socket.assigns.show_system_prompt)}
  end

  def handle_event("start_sandbox", %{"id" => project_id}, socket) do
    Orchid.Projects.ensure_sandbox(project_id)
    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("stop_sandbox", %{"id" => project_id}, socket) do
    Orchid.Projects.stop_sandbox(project_id)
    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("reset_sandbox", %{"id" => project_id}, socket) do
    case Orchid.Sandbox.reset(project_id) do
      {:ok, _status} -> :ok
      {:error, _reason} -> :ok
    end

    {:noreply, refresh_sandbox_statuses(socket)}
  end

  def handle_event("reset_sandbox", _params, socket) do
    # Legacy: reset sandbox from agent chat view using current project
    case socket.assigns.current_project do
      nil -> {:noreply, socket}
      project_id ->
        Orchid.Sandbox.reset(project_id)
        {:noreply, refresh_sandbox_statuses(socket)}
    end
  end

  def handle_event("send_message", _params, socket) do
    input = String.trim(socket.assigns.input)

    if input == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      agent_id = socket.assigns.current_agent

      # Add user message to list immediately so it shows in chat
      messages = socket.assigns.messages ++ [%{role: :user, content: input, tool_calls: nil}]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:pending_message, input)
        |> assign(:input, "")
        |> assign(:streaming, true)
        |> assign(:stream_content, "")
        |> assign(:retry_count, 0)

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
    # Add assistant response (user message was already added when sent)
    assistant_msg = %{role: :assistant, content: socket.assigns.stream_content, tool_calls: nil}
    messages = socket.assigns.messages ++ [assistant_msg]

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:pending_message, nil)

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
      # Max retries reached - restore pending message to input for editing
      error_msg = format_error(reason)
      pending = socket.assigns[:pending_message] || ""

      messages =
        socket.assigns.messages ++
          [%{role: :error, content: "#{error_msg} - Max retries reached.", tool_calls: nil}]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming, false)
        |> assign(:stream_content, "")
        |> assign(:input, pending)
        |> assign(:pending_message, nil)

      {:noreply, socket}
    end
  end

  def handle_info(:retry_stream, socket) do
    agent_id = socket.assigns.current_agent
    input = socket.assigns[:pending_message] || ""
    start_stream(socket, agent_id, input)
    {:noreply, socket}
  end

  def handle_info({:refresh_after_stop, id}, socket) do
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

  def handle_info(:poll_agent_status, socket) do
    socket =
      case socket.assigns.current_agent do
        nil ->
          socket

        agent_id ->
          case Orchid.Agent.get_state(agent_id, 2000) do
            {:ok, state} ->
              socket
              |> assign(:agent_status, state.status)
              |> assign(:messages, format_messages(state.messages))

            _ ->
              socket
          end
      end

    socket =
      socket
      |> assign(:agents, list_agents_with_info())
      |> refresh_sandbox_statuses()
      |> refresh_goals()

    Process.send_after(self(), :poll_agent_status, 2000)
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
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem;">
            <h2 style="margin: 0;">Projects</h2>
            <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_project">+ New</button>
          </div>
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
              <% p_status = project.metadata[:status] %>
              <div
                class="project-item"
                phx-click="select_project"
                phx-value-id={project.id}
                style={if p_status in [:paused, :archived], do: "opacity: 0.5;", else: ""}
              >
                <span class="project-icon"></span>
                <span style="flex: 1;"><%= project.name %></span>
                <%= if p_status == :paused do %>
                  <span style="font-size: 0.65rem; color: #d29922; background: #2d2000; padding: 0.05rem 0.3rem; border-radius: 3px;">paused</span>
                <% end %>
                <%= if p_status == :archived do %>
                  <span style="font-size: 0.65rem; color: #8b949e; background: #21262d; padding: 0.05rem 0.3rem; border-radius: 3px;">archived</span>
                <% end %>
              </div>
            <% end %>
            <%= if @projects == [] and not @creating_project do %>
              <div class="no-projects">No projects yet</div>
            <% end %>
          <% end %>
        </div>
        <div class="sidebar-footer">
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
              <%= if @templates != [] do %>
                <form phx-change="select_template" style="display: inline;">
                  <select class="model-select" name="id" title="Template">
                    <%= for {category, templates} <- group_templates_by_category(@templates) do %>
                      <optgroup label={category}>
                        <%= for template <- templates do %>
                          <option value={template.id} selected={@selected_template == template.id}>
                            <%= template.name %>
                          </option>
                        <% end %>
                      </optgroup>
                    <% end %>
                  </select>
                </form>
              <% end %>
              <a href="/prompts" class="btn btn-secondary" style="padding: 0.4rem 0.6rem;">Prompts</a>
              <a href="/settings" class="btn btn-secondary" style="padding: 0.4rem 0.6rem;">Settings</a>
              <button class="btn btn-secondary" phx-click="show_create_template" title="New Template" style="padding: 0.4rem 0.6rem;">+T</button>
              <%= if @selected_template do %>
                <button class="btn" phx-click="create_agent">New Agent</button>
              <% else %>
                <span style="color: #8b949e; font-size: 0.85rem;">Create a template first</span>
              <% end %>
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
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Category</label>
                    <input
                      type="text"
                      name="category"
                      value={@template_category}
                      phx-change="update_template_category"
                      placeholder="Category"
                      class="sidebar-search"
                      style="width: 100%;"
                      list="category-suggestions"
                    />
                    <datalist id="category-suggestions">
                      <option value="General" />
                      <option value="Coding" />
                      <option value="Writing" />
                      <option value="Analysis" />
                      <option value="Research" />
                    </datalist>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Provider</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_provider" name="provider">
                      <option value="cli" selected={@template_provider == :cli}>CLI</option>
                      <option value="codex" selected={@template_provider == :codex}>Codex</option>
                      <option value="oauth" selected={@template_provider == :oauth}>API</option>
                      <option value="gemini" selected={@template_provider == :gemini}>Gemini</option>
                      <option value="cerebras" selected={@template_provider == :cerebras}>Cerebras</option>
                      <option value="openrouter" selected={@template_provider == :openrouter}>OpenRouter</option>
                    </select>
                  </div>
                  <div style="flex: 1;">
                    <label style="display: block; color: #8b949e; margin-bottom: 0.25rem; font-size: 0.85rem;">Model</label>
                    <select class="sidebar-search" style="width: 100%;" phx-change="update_template_model" name="model">
                      <option value="" selected={@template_model == nil}>Default</option>
                      <option value="opus" selected={@template_model == :opus}>Opus</option>
                      <option value="sonnet" selected={@template_model == :sonnet}>Sonnet</option>
                      <option value="haiku" selected={@template_model == :haiku}>Haiku</option>
                      <option value="gpt53" selected={@template_model == :gpt53}>GPT 5.3</option>
                      <option value="gemini_pro" selected={@template_model == :gemini_pro}>Gemini Pro</option>
                      <option value="gemini_flash" selected={@template_model == :gemini_flash}>Gemini Flash</option>
                      <option value="gemini_flash_image" selected={@template_model == :gemini_flash_image}>Gemini Flash Image</option>
                      <option value="gemini_3_flash" selected={@template_model == :gemini_3_flash}>Gemini 3 Flash</option>
                      <option value="llama_3_1_8b" selected={@template_model == :llama_3_1_8b}>Llama 3.1 8B</option>
                      <option value="llama_3_3_70b" selected={@template_model == :llama_3_3_70b}>Llama 3.3 70B</option>
                      <option value="gpt_oss_120b" selected={@template_model == :gpt_oss_120b}>GPT OSS 120B</option>
                      <option value="qwen_3_32b" selected={@template_model == :qwen_3_32b}>Qwen 3 32B</option>
                      <option value="qwen_3_235b" selected={@template_model == :qwen_3_235b}>Qwen 3 235B</option>
                      <option value="zai_glm_4_7" selected={@template_model == :zai_glm_4_7}>Z.ai GLM 4.7</option>
                      <option value="minimax_m2_5" selected={@template_model == :minimax_m2_5}>MiniMax M2.5</option>
                      <option value="glm_5" selected={@template_model == :glm_5}>GLM-5</option>
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
              <% sb = @sandbox_statuses[@current_project] %>
              <%= if sb do %>
                <div style="background: #1a2332; border-bottom: 1px solid #30363d; padding: 0.4rem 1rem; font-size: 0.8rem; display: flex; align-items: center; justify-content: space-between;">
                  <span style="color: #7ee787;">Sandbox: <%= sb[:status] %></span>
                  <button class="btn btn-secondary btn-sm" style="padding: 0.15rem 0.5rem; font-size: 0.75rem;" phx-click="reset_sandbox">Reset</button>
                </div>
              <% end %>
              <%= if @current_agent_template do %>
                <div class="template-header" style="background: #21262d; border-bottom: 1px solid #30363d; padding: 0.5rem 1rem; display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem;">
                  <span style="color: #8b949e;">Template:</span>
                  <span style="color: #58a6ff; font-weight: 500;"><%= @current_agent_template.name %></span>
                  <span style="color: #6e7681;">•</span>
                  <span style="color: #7ee787;"><%= @current_agent_template.category %></span>
                  <span style="color: #6e7681;">•</span>
                  <span style="color: #8b949e;"><%= @current_agent_template.provider %><%= if @current_agent_template.model, do: " / #{@current_agent_template.model}" %></span>
                  <%= if @system_prompt do %>
                    <button
                      class="btn btn-secondary btn-sm"
                      style="padding: 0.1rem 0.4rem; font-size: 0.7rem; margin-left: auto;"
                      phx-click="toggle_system_prompt"
                    ><%= if @show_system_prompt, do: "Hide Prompt", else: "System Prompt" %></button>
                  <% end %>
                </div>
              <% end %>
              <%= if @show_system_prompt and @system_prompt do %>
                <div style="background: #0d1117; border-bottom: 1px solid #30363d; padding: 0.75rem 1rem; max-height: 300px; overflow-y: auto; font-size: 0.8rem; color: #8b949e; white-space: pre-wrap; font-family: monospace; line-height: 1.5;"><%= @system_prompt %></div>
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
                <%= if @agent_status != :idle do %>
                  <div class="message" style="background: #1a2332; border: 1px solid #30363d; color: #58a6ff; font-size: 0.85rem; padding: 0.5rem 1rem; display: flex; align-items: center; gap: 0.5rem;">
                    <span class="streaming-cursor"></span>
                    <%= case @agent_status do %>
                      <% :thinking -> %>
                        Thinking...
                      <% {:executing_tool, tool_names} -> %>
                        Executing <%= tool_names %>...
                      <% :executing_tool -> %>
                        Executing tool...
                      <% {:retrying, attempt, max, status_code} -> %>
                        API error (<%= status_code %>), retrying <%= attempt %>/<%= max %>...
                      <% status -> %>
                        <%= inspect(status) %>
                    <% end %>
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
                ><%= @input %></textarea>
                <button class="btn" type="submit" disabled={@streaming}>
                  <%= if @streaming, do: "...", else: "Send" %>
                </button>
              </form>
            </div>
          <% else %>
            <%= if @current_project do %>
              <div class="project-detail" style="margin-bottom: 1.5rem;">
                <h2 style="color: #c9d1d9; margin-bottom: 0.5rem;">
                  Project: <%= get_project_name(@projects, @current_project) %>
                </h2>
                <div style="color: #8b949e; font-size: 0.85rem; margin-bottom: 0.5rem;">
                  Folder: <%= Orchid.Project.files_path(@current_project) %>
                </div>

                <% project_status = get_project_status(@projects, @current_project) %>
                <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 1rem;">
                  <span style={"font-size: 0.8rem; padding: 0.15rem 0.5rem; border-radius: 3px; #{project_status_style(project_status)}"}>
                    <%= project_status_label(project_status) %>
                  </span>
                  <%= if project_status in [nil, :active] do %>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="pause_project" phx-value-id={@current_project}>Pause</button>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="archive_project" phx-value-id={@current_project}>Archive</button>
                  <% end %>
                  <%= if project_status == :paused do %>
                    <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="resume_project" phx-value-id={@current_project}>Resume</button>
                    <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="archive_project" phx-value-id={@current_project}>Archive</button>
                  <% end %>
                  <%= if project_status == :archived do %>
                    <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="restore_project" phx-value-id={@current_project}>Restore</button>
                  <% end %>
                </div>

                <div class="sandbox-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between;">
                    <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Sandbox</h3>
                    <% sb = @sandbox_statuses[@current_project] %>
                    <div style="display: flex; gap: 0.5rem; align-items: center;">
                      <%= if sb do %>
                        <span style={"font-size: 0.8rem; padding: 0.15rem 0.5rem; border-radius: 3px; #{sandbox_status_style(sb[:status])}"}>
                          <%= sb[:status] %>
                        </span>
                        <span style="color: #6e7681; font-size: 0.75rem;"><%= sb[:container_name] %></span>
                        <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="reset_sandbox" phx-value-id={@current_project}>Reset</button>
                        <button class="btn btn-danger btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="stop_sandbox" phx-value-id={@current_project}>Stop</button>
                      <% else %>
                        <span style="font-size: 0.8rem; color: #8b949e;">Not running</span>
                        <button class="btn btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="start_sandbox" phx-value-id={@current_project}>Start</button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <div class="goals-section" style="background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; margin-bottom: 1rem;">
                  <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 1rem;">
                    <h3 style="color: #c9d1d9; margin: 0; font-size: 1rem;">Goals</h3>
                    <div style="display: flex; gap: 0.5rem;">
                      <%= if @goals != [] do %>
                        <button
                          class="btn btn-secondary btn-sm"
                          style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                          phx-click="toggle_goals_view"
                        ><%= if @goals_view_mode == :list, do: "Graph", else: "List" %></button>
                      <% end %>
                      <%= if @goals != [] do %>
                        <button
                          class="btn btn-danger btn-sm"
                          style="padding: 0.2rem 0.5rem; font-size: 0.75rem; opacity: 0.7;"
                          phx-click="clear_all_goals"
                          data-confirm="Delete all goals for this project?"
                        >Clear All</button>
                      <% end %>
                      <%= if not @creating_goal do %>
                        <button class="btn btn-secondary btn-sm" style="padding: 0.2rem 0.5rem; font-size: 0.75rem;" phx-click="show_new_goal">+ Add Goal</button>
                      <% end %>
                    </div>
                  </div>

                  <%= if @creating_goal do %>
                    <form phx-submit="create_goal" style="margin-bottom: 1rem;">
                      <input
                        type="text"
                        name="name"
                        value={@new_goal_name}
                        phx-change="update_new_goal_name"
                        placeholder="Goal name"
                        class="sidebar-search"
                        style="width: 100%; margin-bottom: 0.5rem;"
                        autofocus
                      />
                      <textarea
                        name="description"
                        phx-change="update_new_goal_description"
                        placeholder="Description (optional)"
                        class="sidebar-search"
                        style="width: 100%; margin-bottom: 0.5rem; min-height: 3rem; resize: vertical;"
                      ><%= @new_goal_description %></textarea>
                      <%= if @goals != [] do %>
                        <select
                          name="parent"
                          class="sidebar-search"
                          style="width: 100%; margin-bottom: 0.5rem;"
                          phx-change="update_new_goal_parent"
                        >
                          <option value="">No parent</option>
                          <%= for goal <- @goals do %>
                            <option value={goal.id} selected={@new_goal_parent == goal.id}><%= goal.name %></option>
                          <% end %>
                        </select>
                      <% end %>
                      <div style="display: flex; gap: 0.5rem;">
                        <button type="submit" class="btn btn-sm">Add</button>
                        <button type="button" class="btn btn-secondary btn-sm" phx-click="cancel_new_goal">Cancel</button>
                      </div>
                    </form>
                  <% end %>

                  <%= if @goals == [] and not @creating_goal do %>
                    <p style="color: #8b949e; margin: 0;">No goals yet.</p>
                  <% else %>
                    <%= if @goals_view_mode == :graph do %>
                      <% graph = compute_goal_graph(@goals) %>
                      <div style="overflow-x: auto; margin-bottom: 1rem;">
                        <svg
                          width={graph.width}
                          height={graph.height}
                          viewBox={"0 0 #{graph.width} #{graph.height}"}
                          style="display: block;"
                        >
                          <defs>
                            <marker id="arrowhead" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                              <polygon points="0 0, 8 3, 0 6" fill="#8b949e" />
                            </marker>
                          </defs>
                          <%= for edge <- graph.edges do %>
                            <line
                              x1={edge.x1} y1={edge.y1}
                              x2={edge.x2} y2={edge.y2}
                              stroke="#8b949e" stroke-width="1.5"
                              marker-end="url(#arrowhead)"
                              opacity="0.6"
                            />
                          <% end %>
                          <%= for node <- graph.nodes do %>
                            <rect
                              x={node.x} y={node.y}
                              width={node.w} height={node.h}
                              rx="6" ry="6"
                              fill={goal_node_fill(node.status)}
                              stroke={goal_node_stroke(node.status)}
                              stroke-width="1.5"
                            />
                            <text
                              x={node.x + node.w / 2}
                              y={node.y + node.h / 2 + 1}
                              text-anchor="middle"
                              dominant-baseline="middle"
                              fill={goal_node_text(node.status)}
                              font-size="12"
                              font-family="-apple-system, BlinkMacSystemFont, sans-serif"
                            >
                              <%= truncate_name(node.name, 30) %>
                            </text>
                            <%= if node.agent_id do %>
                              <text
                                x={node.x + node.w - 6}
                                y={node.y + 12}
                                text-anchor="end"
                                fill="#58a6ff"
                                font-size="9"
                                font-family="monospace"
                              >
                                <%= short_agent_id(node.agent_id) %>
                              </text>
                            <% end %>
                          <% end %>
                        </svg>
                      </div>
                    <% else %>
                      <div class="goals-list" style="display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 1rem;">
                        <%= for goal <- topo_sort_goals(@goals) do %>
                          <div class="goal-item" style="background: #0d1117; border: 1px solid #30363d; border-radius: 4px; padding: 0.75rem;">
                            <div style="display: flex; align-items: center; gap: 0.5rem;">
                              <button
                                phx-click="toggle_goal_status"
                                phx-value-id={goal.id}
                                style={"width: 1.25rem; height: 1.25rem; border-radius: 3px; border: 1px solid #30363d; background: #{if goal.metadata[:status] == :completed, do: "#238636", else: "transparent"}; cursor: pointer; display: flex; align-items: center; justify-content: center; color: white; font-size: 0.7rem;"}
                              >
                                <%= if goal.metadata[:status] == :completed, do: "✓", else: "" %>
                              </button>
                              <span
                                style={"flex: 1; cursor: pointer; color: #{if goal.metadata[:status] == :completed, do: "#8b949e", else: "#c9d1d9"}; #{if goal.metadata[:status] == :completed, do: "text-decoration: line-through;", else: ""}"}
                                phx-click="toggle_goal_details"
                                phx-value-id={goal.id}
                              >
                                <%= goal.name %>
                                <%= if is_nil(goal.metadata[:parent_goal_id]) do %>
                                  <span style="font-size: 0.65rem; color: #bc8cff; background: #1e1530; padding: 0.05rem 0.3rem; border-radius: 3px; margin-left: 0.25rem;">root</span>
                                <% else %>
                                  <span style="font-size: 0.75rem; color: #8b949e;"> (sub of: <%= get_goal_name(@goals, goal.metadata[:parent_goal_id]) %>)</span>
                                <% end %>
                              </span>
                              <%= if goal.metadata[:agent_id] do %>
                                <span style="background: #1a2332; color: #58a6ff; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.7rem;">
                                  <%= short_agent_id(goal.metadata[:agent_id]) %>
                                </span>
                              <% end %>
                              <%= if filter_agents(@agents, @current_project) != [] do %>
                                <button
                                  class="btn btn-secondary btn-sm"
                                  style="padding: 0.15rem 0.4rem; font-size: 0.7rem;"
                                  phx-click="start_assign_goal"
                                  phx-value-id={goal.id}
                                >Assign</button>
                              <% end %>
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
                            <%= if @expanded_goal == goal.id do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem; padding: 0.5rem; background: #161b22; border: 1px solid #21262d; border-radius: 4px; font-size: 0.8rem;">
                                <%= if goal.content != "" do %>
                                  <div style="color: #c9d1d9; margin-bottom: 0.5rem; white-space: pre-wrap;"><%= goal.content %></div>
                                <% else %>
                                  <div style="color: #6e7681; margin-bottom: 0.5rem; font-style: italic;">No description</div>
                                <% end %>
                                <div style="color: #6e7681; font-size: 0.7rem; display: flex; flex-wrap: wrap; gap: 0.75rem;">
                                  <span>ID: <span style="color: #8b949e; font-family: monospace;"><%= goal.id %></span></span>
                                  <span>Status: <span style="color: #8b949e;"><%= goal.metadata[:status] %></span></span>
                                  <%= if goal.metadata[:parent_goal_id] do %>
                                    <span>Parent: <span style="color: #8b949e;"><%= get_goal_name(@goals, goal.metadata[:parent_goal_id]) %></span></span>
                                  <% end %>
                                  <%= if goal.metadata[:agent_id] do %>
                                    <span>Agent: <span style="color: #58a6ff; font-family: monospace;"><%= short_agent_id(goal.metadata[:agent_id]) %></span></span>
                                  <% end %>
                                  <span>Created: <span style="color: #8b949e;"><%= Calendar.strftime(goal.created_at, "%Y-%m-%d %H:%M") %></span></span>
                                </div>
                              </div>
                            <% end %>
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
                            <%= if @assigning_goal == goal.id do %>
                              <div style="margin-top: 0.5rem; margin-left: 1.75rem;">
                                <div style="display: flex; flex-wrap: wrap; gap: 0.25rem;">
                                  <%= for agent <- filter_agents(@agents, @current_project) do %>
                                    <button
                                      class="btn btn-secondary btn-sm"
                                      style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                      phx-click="assign_goal_to_agent"
                                      phx-value-goal-id={goal.id}
                                      phx-value-agent-id={agent.id}
                                    ><%= short_agent_id(agent.id) %></button>
                                  <% end %>
                                  <button
                                    class="btn btn-secondary btn-sm"
                                    style="padding: 0.2rem 0.5rem; font-size: 0.75rem;"
                                    phx-click="cancel_assign_goal"
                                  >Cancel</button>
                                </div>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
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
                  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.25rem;">
                    <h3 style="margin: 0;"><%= agent.id %></h3>
                    <div style={"padding: 0.15rem 0.5rem; border-radius: 12px; font-size: 0.75rem; #{agent_status_style(agent.status)}"}><%= agent_status_label(agent.status) %></div>
                  </div>
                  <%= if agent.template do %>
                    <div style="color: #8b949e; font-size: 0.85rem;"><%= agent.template %></div>
                  <% end %>
                  <%= if agent.goal do %>
                    <div style="color: #c9d1d9; font-size: 0.85rem; margin-top: 0.25rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title={agent.goal}><%= agent.goal %></div>
                  <% end %>
                  <%= if agent.project_id && !@current_project do %>
                    <div class="agent-project" style="margin-top: 0.25rem;">
                      <span class="project-badge"><%= get_project_name(@projects, agent.project_id) %></span>
                    </div>
                  <% end %>
                  <div class="actions" style="margin-top: 0.5rem;">
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

  defp get_project_status(projects, id) do
    case Enum.find(projects, fn p -> p.id == id end) do
      nil -> nil
      project -> project.metadata[:status]
    end
  end

  defp project_status_label(nil), do: "Active"
  defp project_status_label(:active), do: "Active"
  defp project_status_label(:paused), do: "Paused"
  defp project_status_label(:archived), do: "Archived"

  defp project_status_style(nil), do: "background: #0e2a15; color: #7ee787;"
  defp project_status_style(:active), do: "background: #0e2a15; color: #7ee787;"
  defp project_status_style(:paused), do: "background: #2d2000; color: #d29922;"
  defp project_status_style(:archived), do: "background: #21262d; color: #8b949e;"

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
        {:ok, state} ->
          template_name =
            case state.config[:template_id] do
              nil -> nil
              tid ->
                case Orchid.Object.get(tid) do
                  {:ok, obj} -> obj.name
                  _ -> nil
                end
            end

          goal_name =
            case state.project_id do
              nil -> nil
              pid ->
                Orchid.Object.list_goals_for_project(pid)
                |> Enum.find(fn g -> g.metadata[:agent_id] == agent_id end)
                |> case do
                  nil -> nil
                  g -> g.name
                end
            end

          status = state.status

          %{id: agent_id, project_id: state.project_id, template: template_name, goal: goal_name, status: status}
        _ ->
          %{id: agent_id, project_id: nil, template: nil, goal: nil, status: :unknown}
      end
    end)
  end

  defp refresh_sandbox_statuses(socket) do
    case socket.assigns.current_project do
      nil ->
        assign(socket, :sandbox_statuses, %{})

      project_id ->
        statuses =
          case Orchid.Projects.sandbox_status(project_id) do
            nil -> %{}
            status -> %{project_id => status}
          end

        assign(socket, :sandbox_statuses, statuses)
    end
  end

  defp agent_status_label(:idle), do: "Idle"
  defp agent_status_label({:executing_tool, names}), do: "Tool: #{names}"
  defp agent_status_label(:thinking), do: "Thinking..."
  defp agent_status_label(:streaming), do: "Streaming..."
  defp agent_status_label(status) when is_atom(status), do: status |> Atom.to_string() |> String.capitalize()
  defp agent_status_label(_), do: "Active"

  defp agent_status_style(:idle), do: "background: #21262d; color: #8b949e;"
  defp agent_status_style({:executing_tool, _}), do: "background: #2d2000; color: #d29922;"
  defp agent_status_style(:thinking), do: "background: #0c2d6b; color: #58a6ff;"
  defp agent_status_style(:streaming), do: "background: #0c2d6b; color: #58a6ff;"
  defp agent_status_style(_), do: "background: #0e2a15; color: #7ee787;"

  defp sandbox_status_style(:ready), do: "background: #0e2a15; color: #7ee787;"
  defp sandbox_status_style(:starting), do: "background: #2d2000; color: #d29922;"
  defp sandbox_status_style(:error), do: "background: #3d1114; color: #f85149;"
  defp sandbox_status_style(_), do: "background: #21262d; color: #8b949e;"

  defp refresh_goals(socket) do
    case socket.assigns.current_project do
      nil -> assign(socket, :goals, [])
      project_id -> assign(socket, :goals, Orchid.Goals.list_for_project(project_id))
    end
  end

  defp filter_agents(agents, nil), do: agents

  defp filter_agents(agents, current_project) do
    Enum.filter(agents, fn agent ->
      agent.project_id == current_project
    end)
  end

  defp short_agent_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  defp short_agent_id(id), do: inspect(id)

  defp compute_goal_graph(goals) do
    id_set = MapSet.new(goals, & &1.id)

    # Assign each goal a layer (depth) based on longest path from roots
    depths = compute_depths(goals, id_set)

    # Group by layer
    layers =
      goals
      |> Enum.group_by(&Map.get(depths, &1.id, 0))
      |> Enum.sort_by(fn {layer, _} -> layer end)

    node_w = 220
    node_h = 36
    h_gap = 30
    v_gap = 60
    pad = 20

    max_layer_count = layers |> Enum.map(fn {_, gs} -> length(gs) end) |> Enum.max(fn -> 1 end)
    svg_width = max(max_layer_count * (node_w + h_gap) - h_gap + pad * 2, 400)

    # Build node positions
    {nodes, pos_map} =
      Enum.reduce(layers, {[], %{}}, fn {layer, layer_goals}, {nodes_acc, pos_acc} ->
        count = length(layer_goals)
        total_w = count * node_w + (count - 1) * h_gap
        start_x = (svg_width - total_w) / 2

        layer_goals
        |> Enum.sort_by(& &1.name)
        |> Enum.with_index()
        |> Enum.reduce({nodes_acc, pos_acc}, fn {goal, idx}, {n_acc, p_acc} ->
          x = start_x + idx * (node_w + h_gap)
          y = pad + layer * (node_h + v_gap)

          node = %{
            id: goal.id,
            name: goal.name,
            status: goal.metadata[:status],
            agent_id: goal.metadata[:agent_id],
            x: x, y: y, w: node_w, h: node_h
          }

          {n_acc ++ [node], Map.put(p_acc, goal.id, {x, y})}
        end)
      end)

    # Build edges: from dependency -> dependent (arrow points to the goal that depends)
    edges =
      Enum.flat_map(goals, fn goal ->
        deps = (goal.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))

        Enum.map(deps, fn dep_id ->
          {dep_x, dep_y} = pos_map[dep_id]
          {goal_x, goal_y} = pos_map[goal.id]

          %{
            x1: dep_x + node_w / 2,
            y1: dep_y + node_h,
            x2: goal_x + node_w / 2,
            y2: goal_y
          }
        end)
      end)

    layer_count = length(layers)
    svg_height = pad * 2 + layer_count * node_h + max((layer_count - 1) * v_gap, 0)

    %{nodes: nodes, edges: edges, width: svg_width, height: svg_height}
  end

  defp compute_depths(goals, id_set) do
    # BFS from roots, tracking max depth
    initial = Map.new(goals, fn g ->
      deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))
      {g.id, deps}
    end)

    roots = for g <- goals, (initial[g.id] || []) == [], do: g.id
    do_compute_depths(roots, initial, %{}, 0)
  end

  defp do_compute_depths([], _deps_map, depths, _layer), do: depths

  defp do_compute_depths(current, deps_map, depths, layer) do
    depths = Enum.reduce(current, depths, fn id, acc ->
      # Use max depth if already visited at a shallower layer
      Map.update(acc, id, layer, &max(&1, layer))
    end)

    # Find all goals whose deps are now fully resolved
    all_ids = Map.keys(deps_map)
    resolved = MapSet.new(Map.keys(depths))

    next =
      all_ids
      |> Enum.filter(fn id -> not Map.has_key?(depths, id) end)
      |> Enum.filter(fn id ->
        deps = deps_map[id] || []
        deps != [] and Enum.all?(deps, &MapSet.member?(resolved, &1))
      end)

    if next == [] do
      # Handle any remaining unresolved (cycles) — put them at layer + 1
      remaining = Enum.filter(all_ids, fn id -> not Map.has_key?(depths, id) end)
      Enum.reduce(remaining, depths, fn id, acc -> Map.put(acc, id, layer + 1) end)
    else
      do_compute_depths(next, deps_map, depths, layer + 1)
    end
  end

  defp goal_node_fill(:completed), do: "#0e2a15"
  defp goal_node_fill(_), do: "#0d1117"

  defp goal_node_stroke(:completed), do: "#238636"
  defp goal_node_stroke(_), do: "#30363d"

  defp goal_node_text(:completed), do: "#8b949e"
  defp goal_node_text(_), do: "#c9d1d9"

  defp truncate_name(name, max) do
    if String.length(name) > max do
      String.slice(name, 0, max - 1) <> "..."
    else
      name
    end
  end

  defp topo_sort_goals(goals) do
    id_set = MapSet.new(goals, & &1.id)

    # Kahn's algorithm
    # Build in-degree map (only count deps that exist in our goal list)
    in_deg =
      Map.new(goals, fn g ->
        deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))
        {g.id, length(deps)}
      end)

    # Build reverse adjacency: dep_id -> list of goals that depend on it
    rev =
      Enum.reduce(goals, %{}, fn g, acc ->
        deps = (g.metadata[:depends_on] || []) |> Enum.filter(&(&1 in id_set))

        Enum.reduce(deps, acc, fn dep_id, acc2 ->
          Map.update(acc2, dep_id, [g.id], &[g.id | &1])
        end)
      end)

    by_id = Map.new(goals, &{&1.id, &1})
    queue = for g <- goals, in_deg[g.id] == 0, do: g.id

    do_topo(queue, rev, in_deg, by_id, [])
  end

  defp do_topo([], _rev, in_deg, by_id, sorted) do
    # Append any remaining (cycles) at the end
    remaining =
      in_deg
      |> Enum.filter(fn {id, deg} -> deg > 0 and Map.has_key?(by_id, id) end)
      |> Enum.map(fn {id, _} -> by_id[id] end)

    Enum.reverse(sorted) ++ remaining
  end

  defp do_topo([id | rest], rev, in_deg, by_id, sorted) do
    sorted = [by_id[id] | sorted]
    dependents = Map.get(rev, id, [])

    {queue_adds, in_deg} =
      Enum.reduce(dependents, {[], in_deg}, fn dep_id, {adds, deg} ->
        new_deg = deg[dep_id] - 1
        deg = Map.put(deg, dep_id, new_deg)

        if new_deg == 0 do
          {[dep_id | adds], deg}
        else
          {adds, deg}
        end
      end)

    do_topo(rest ++ queue_adds, rev, in_deg, by_id, sorted)
  end

  defp group_templates_by_category(templates) do
    templates
    |> Enum.group_by(fn t -> t.metadata[:category] || "General" end)
    |> Enum.sort_by(fn {category, _} ->
      # "General" first, then alphabetical
      if category == "General", do: {0, category}, else: {1, category}
    end)
  end
end
