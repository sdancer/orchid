# Reset all project data, create fresh project + goal
# Usage: elixir --name reset@127.0.0.1 --cookie "$(cat ~/.erlang.cookie)" priv/scripts/reset_project.exs

node = :"orchid@127.0.0.1"

unless Node.connect(node) do
  IO.puts("ERROR: Cannot connect to #{node}. Is the server running?")
  System.halt(1)
end

rpc = fn mod, fun, args ->
  case :rpc.call(node, mod, fun, args) do
    {:badrpc, reason} ->
      IO.puts("RPC ERROR: #{inspect(reason)}")
      nil
    result -> result
  end
end

IO.puts("=== Stopping all agents ===")
for id <- rpc.(Orchid.Agent, :list, []) do
  IO.puts("  stopping agent #{id}")
  rpc.(Orchid.Agent, :stop, [id])
end

IO.puts("=== Stopping all sandboxes ===")
for project <- rpc.(Orchid.Object, :list_projects, []) do
  IO.puts("  stopping sandbox for #{project.name}")
  rpc.(Orchid.Sandbox, :stop, [project.id])
end

# Kill any leftover containers
{out, _} = System.cmd("podman", ["ps", "-a", "--format", "{{.Names}}"], stderr_to_stdout: true)
for name <- String.split(out, "\n", trim: true), String.starts_with?(name, "orchid-") do
  IO.puts("  removing container #{name}")
  System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
end

IO.puts("=== Deleting all goals ===")
for goal <- rpc.(Orchid.Object, :list_goals, []) do
  IO.puts("  deleting goal: #{goal.name}")
  rpc.(Orchid.Object, :delete, [goal.id])
end

IO.puts("=== Deleting all projects ===")
for project <- rpc.(Orchid.Object, :list_projects, []) do
  IO.puts("  deleting project: #{project.name}")
  rpc.(Orchid.Object, :delete, [project.id])
end

IO.puts("")
IO.puts("=== Creating project: Diablo 2 ===")
{:ok, project} = rpc.(Orchid.Object, :create, [:project, "Diablo 2", "", [metadata: %{status: :active}]])
IO.puts("  project ID: #{project.id}")

IO.puts("=== Creating goal ===")
{:ok, goal} = rpc.(Orchid.Goals, :create, [
  "manually decompile diablo 2 demo and compile to wasm",
  "the installer is here: https://archive.org/download/DiabloIiDemo/DiabloIIDemo.exe",
  project.id
])
IO.puts("  goal ID: #{goal.id}")
IO.puts("  goal: #{goal.name}")

IO.puts("")
IO.puts("Done. GoalWatcher will pick up the project and spawn a planner within 10s.")
