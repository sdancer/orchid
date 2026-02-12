defmodule Orchid.Sandbox do
  @moduledoc """
  Sandbox GenServer — one per agent.
  Manages a Podman container with OverlayFS for isolated file access.
  Registered in Orchid.Registry as {:sandbox, agent_id}.
  """
  use GenServer
  require Logger

  alias Orchid.{Project, Sandbox.Overlay}

  defstruct [
    :agent_id,
    :project_id,
    :container_name,
    :lower_path,
    :upper_path,
    :work_path,
    :merged_path,
    :overlay_method,
    :image,
    :status
  ]

  # Client API

  def start_link({agent_id, project_id}) do
    GenServer.start_link(__MODULE__, {agent_id, project_id},
      name: {:via, Registry, {Orchid.Registry, {:sandbox, agent_id}}}
    )
  end

  def child_spec({agent_id, project_id}) do
    %{
      id: {__MODULE__, agent_id},
      start: {__MODULE__, :start_link, [{agent_id, project_id}]},
      restart: :temporary
    }
  end

  def exec(agent_id, command, opts \\ []) do
    call(agent_id, {:exec, command, opts})
  end

  def read_file(agent_id, path) do
    call(agent_id, {:read_file, path})
  end

  def write_file(agent_id, path, content) do
    call(agent_id, {:write_file, path, content})
  end

  def edit_file(agent_id, path, old_string, new_string) do
    call(agent_id, {:edit_file, path, old_string, new_string})
  end

  def list_files(agent_id, path \\ "/workspace") do
    call(agent_id, {:list_files, path})
  end

  def grep_files(agent_id, pattern, path \\ "/workspace", opts \\ []) do
    call(agent_id, {:grep_files, pattern, path, opts})
  end

  def reset(agent_id) do
    call(agent_id, :reset)
  end

  def stop(agent_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, agent_id}) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  end

  def status(agent_id) do
    case Registry.lookup(Orchid.Registry, {:sandbox, agent_id}) do
      [{pid, _}] -> GenServer.call(pid, :status)
      [] -> nil
    end
  end

  # GenServer callbacks

  @impl true
  def init({agent_id, project_id}) do
    data_dir = Project.data_dir() |> Path.expand()
    lower = Project.files_path(project_id) |> Path.expand()
    base = Path.join([data_dir, "sandboxes", agent_id])
    upper = Path.join(base, "upper")
    work = Path.join(base, "work")
    merged = Path.join(base, "merged")

    File.mkdir_p!(upper)
    File.mkdir_p!(work)
    File.mkdir_p!(merged)
    Project.ensure_dir(project_id)

    image = get_image()
    container_name = "orchid-#{agent_id}"

    state = %__MODULE__{
      agent_id: agent_id,
      project_id: project_id,
      container_name: container_name,
      lower_path: lower,
      upper_path: upper,
      work_path: work,
      merged_path: merged,
      image: image,
      overlay_method: nil,
      status: :starting
    }

    state = start_container(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, container_name: state.container_name, overlay_method: state.overlay_method}, state}
  end

  def handle_call({:exec, command, opts}, _from, state) do
    timeout = opts[:timeout] || 30_000
    result = podman_exec(state, command, timeout)
    {:reply, result, state}
  end

  def handle_call({:read_file, path}, _from, state) do
    result =
      case state.overlay_method do
        :overlay ->
          podman_exec(state, "cat #{escape(path)}")

        :union ->
          rel = workspace_relative(path)
          case Overlay.union_read(rel, state.upper_path, state.lower_path) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
          end
      end

    {:reply, result, state}
  end

  def handle_call({:write_file, path, content}, _from, state) do
    result =
      case state.overlay_method do
        :overlay ->
          podman_exec_stdin(state, "mkdir -p $(dirname #{escape(path)}) && cat > #{escape(path)}", content)

        :union ->
          rel = workspace_relative(path)
          case Overlay.union_write(rel, content, state.upper_path) do
            :ok -> {:ok, "Written to #{path}"}
            {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
          end
      end

    {:reply, result, state}
  end

  def handle_call({:edit_file, path, old_string, new_string}, _from, state) do
    # Read, replace, write back
    read_result =
      case state.overlay_method do
        :overlay -> podman_exec(state, "cat #{escape(path)}")
        :union ->
          rel = workspace_relative(path)
          case Overlay.union_read(rel, state.upper_path, state.lower_path) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, "Failed to read #{path}: #{reason}"}
          end
      end

    result =
      case read_result do
        {:ok, content} ->
          if String.contains?(content, old_string) do
            count = length(String.split(content, old_string)) - 1

            if count > 1 do
              {:error, "old_string appears #{count} times - must be unique. Add more context."}
            else
              new_content = String.replace(content, old_string, new_string, global: false)

              write_result =
                case state.overlay_method do
                  :overlay ->
                    podman_exec_stdin(state, "cat > #{escape(path)}", new_content)

                  :union ->
                    rel = workspace_relative(path)
                    case Overlay.union_write(rel, new_content, state.upper_path) do
                      :ok -> {:ok, "ok"}
                      {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
                    end
                end

              case write_result do
                {:ok, _} -> {:ok, "Successfully edited #{path}"}
                error -> error
              end
            end
          else
            {:error, "old_string not found in #{path}"}
          end

        error ->
          error
      end

    {:reply, result, state}
  end

  def handle_call({:list_files, path}, _from, state) do
    result =
      case state.overlay_method do
        :overlay ->
          podman_exec(state, "ls -la #{escape(path)}")

        :union ->
          rel = workspace_relative(path)
          Overlay.union_list(rel, state.upper_path, state.lower_path)
      end

    {:reply, result, state}
  end

  def handle_call({:grep_files, pattern, path, opts}, _from, state) do
    result =
      case state.overlay_method do
        :overlay ->
          glob = opts[:glob]
          cmd = "rg -n --no-heading #{escape(pattern)} #{escape(path)}"
          cmd = if glob, do: cmd <> " --glob #{escape(glob)}", else: cmd
          podman_exec(state, cmd)

        :union ->
          rel = workspace_relative(path)
          Overlay.union_grep(pattern, rel, state.upper_path, state.lower_path, opts)
      end

    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    destroy_container(state)
    new_state = start_container(%{state | status: :starting})
    {:reply, {:ok, %{status: new_state.status}}, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    destroy_container(state)
    :ok
  end

  # Private

  defp call(agent_id, msg) do
    case Registry.lookup(Orchid.Registry, {:sandbox, agent_id}) do
      [{pid, _}] -> GenServer.call(pid, msg, 60_000)
      [] -> {:error, :sandbox_not_found}
    end
  end

  defp get_image do
    Orchid.Object.get_fact_value("sandbox_image") || "alpine:latest"
  end

  defp start_container(state) do
    # Try primary approach: podman with in-container overlay mount
    case try_overlay_container(state) do
      {:ok, new_state} ->
        Logger.info("Sandbox #{state.agent_id}: overlay container started")
        new_state

      {:error, reason} ->
        Logger.warning("Sandbox #{state.agent_id}: overlay failed (#{reason}), trying fallback")
        case try_fallback_container(state) do
          {:ok, new_state} ->
            Logger.info("Sandbox #{state.agent_id}: fallback container started (union mode)")
            new_state

          {:error, reason2} ->
            Logger.error("Sandbox #{state.agent_id}: all container methods failed: #{reason2}")
            %{state | status: :error, overlay_method: :union}
        end
    end
  end

  defp try_overlay_container(state) do
    # First ensure any old container is removed
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)

    args = [
      "run", "-d",
      "--name", state.container_name,
      "--cap-add=SYS_ADMIN",
      "-v", "#{state.lower_path}:/workspace_lower:ro",
      "-v", "#{state.upper_path}:/workspace_upper",
      "-v", "#{state.work_path}:/workspace_work",
      state.image,
      "sh", "-c",
      "mkdir -p /workspace && mount -t overlay overlay -o lowerdir=/workspace_lower,upperdir=/workspace_upper,workdir=/workspace_work /workspace && exec sleep infinity"
    ]

    case System.cmd("podman", args, stderr_to_stdout: true) do
      {_output, 0} ->
        # Verify the container is actually running
        Process.sleep(500)
        case System.cmd("podman", ["inspect", "--format", "{{.State.Running}}", state.container_name], stderr_to_stdout: true) do
          {"true\n", 0} ->
            {:ok, %{state | status: :ready, overlay_method: :overlay}}

          _ ->
            # Container started but overlay mount failed, it exited
            System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)
            {:error, "container exited (overlay mount likely failed)"}
        end

      {output, _code} ->
        {:error, "podman run failed: #{String.trim(output)}"}
    end
  end

  defp try_fallback_container(state) do
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)

    args = [
      "run", "-d",
      "--name", state.container_name,
      "-v", "#{state.lower_path}:/workspace_lower:ro",
      "-v", "#{state.upper_path}:/workspace:rw",
      state.image,
      "sleep", "infinity"
    ]

    case System.cmd("podman", args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, %{state | status: :ready, overlay_method: :union}}

      {output, _code} ->
        {:error, "podman fallback failed: #{String.trim(output)}"}
    end
  end

  defp destroy_container(state) do
    System.cmd("podman", ["rm", "-f", state.container_name], stderr_to_stdout: true)
  end

  defp podman_exec(state, command, timeout \\ 30_000) do
    if state.status == :error do
      {:error, "Sandbox is in error state"}
    else
      task =
        Task.async(fn ->
          System.cmd("podman", [
            "exec", "-w", "/workspace",
            state.container_name,
            "sh", "-c", command
          ], stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, code}} -> {:ok, "Exit code #{code}:\n#{output}"}
        nil -> {:error, "Command timed out after #{timeout}ms"}
      end
    end
  end

  defp podman_exec_stdin(state, command, stdin_data) do
    if state.status == :error do
      {:error, "Sandbox is in error state"}
    else
      port =
        Port.open(
          {:spawn_executable, System.find_executable("podman")},
          [
            :binary,
            :exit_status,
            args: ["exec", "-i", "-w", "/workspace", state.container_name, "sh", "-c", command]
          ]
        )

      Port.command(port, stdin_data)
      Port.command(port, "")
      # Close stdin by sending EOF — Port doesn't have close_stdin, so we close the port
      # Actually we need to wait for exit. Send data then collect output.
      # The trick: close stdin by closing the port's input
      send(port, {self(), :close})

      collect_port_output(port, "")
    end
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:ok, "Exit code #{code}:\n#{acc}"}
    after
      30_000 ->
        Port.close(port)
        {:error, "Timed out waiting for command"}
    end
  end

  defp workspace_relative(path) do
    path
    |> String.replace_prefix("/workspace/", "")
    |> String.replace_prefix("/workspace", "")
    |> then(fn
      "" -> "."
      p -> p
    end)
  end

  defp escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
