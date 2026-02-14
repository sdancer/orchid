# Reset all project data, create fresh project + goal
# Usage: ./orchid stop && elixir --name reset@127.0.0.1 --cookie "$(cat ~/.erlang.cookie)" priv/scripts/reset_project.exs && ./orchid start
# Or just: ./orchid reset

script_dir = Path.dirname(__ENV__.file) |> Path.expand()
orchid_dir = Path.join(script_dir, "../..") |> Path.expand()
orchid_bin = Path.join(orchid_dir, "orchid")

# --- Stop the running instance ---
IO.puts("=== Stopping Orchid ===")
case System.cmd(orchid_bin, ["stop"], cd: orchid_dir, stderr_to_stdout: true) do
  {output, _} -> IO.puts(String.trim(output))
end

# Give it a moment to fully shut down
Process.sleep(2000)

# --- Kill any leftover containers ---
IO.puts("=== Cleaning containers ===")
{out, _} = System.cmd("podman", ["ps", "-a", "--format", "{{.Names}}"], stderr_to_stdout: true)
for name <- String.split(out, "\n", trim: true), String.starts_with?(name, "orchid-") do
  IO.puts("  removing container #{name}")
  System.cmd("podman", ["rm", "-f", name], stderr_to_stdout: true)
end

# --- Clean sandbox data ---
data_dir = Path.join(orchid_dir, "priv/data")
sandbox_dir = Path.join(data_dir, "sandboxes")
if File.exists?(sandbox_dir) do
  IO.puts("=== Cleaning sandbox data ===")
  case File.rm_rf(sandbox_dir) do
    {:ok, _} -> :ok
    {:error, _, _} ->
      IO.puts("  regular rm failed, using sudo...")
      System.cmd("sudo", ["rm", "-rf", sandbox_dir], stderr_to_stdout: true)
  end
end

# --- Clean logs ---
log_file = Path.join(data_dir, "server.log")
if File.exists?(log_file), do: File.write!(log_file, "")

# --- Start Orchid fresh ---
IO.puts("\n=== Starting Orchid ===")
case System.cmd(orchid_bin, ["start"], cd: orchid_dir, stderr_to_stdout: true) do
  {output, _} -> IO.puts(String.trim(output))
end

# Wait for startup
Process.sleep(3000)

# --- Connect and create project ---
node = :"orchid@127.0.0.1"

unless Node.connect(node) do
  IO.puts("ERROR: Cannot connect to #{node}. Did it start?")
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

# Delete any existing data (in case store persisted)
IO.puts("\n=== Cleaning existing data ===")
for goal <- rpc.(Orchid.Object, :list_goals, []) || [] do
  IO.puts("  deleting goal: #{goal.name}")
  rpc.(Orchid.Object, :delete, [goal.id])
end

for project <- rpc.(Orchid.Object, :list_projects, []) || [] do
  IO.puts("  deleting project: #{project.name}")
  rpc.(Orchid.Object, :delete, [project.id])
end

# Delete and reseed templates (ensures latest seed config)
IO.puts("\n=== Reseeding templates ===")
for t <- rpc.(Orchid.Object, :list_agent_templates, []) || [] do
  IO.puts("  deleting template: #{t.name}")
  rpc.(Orchid.Object, :delete, [t.id])
end
result = rpc.(Orchid.Seeds, :seed_templates, [])
IO.puts("  #{result}")

IO.puts("\n=== Creating project: Diablo 2 ===")
{:ok, project} = rpc.(Orchid.Object, :create, [:project, "Diablo 2", "", [metadata: %{status: :active}]])
IO.puts("  project ID: #{project.id}")

IO.puts("=== Creating goal ===")
{:ok, goal} = rpc.(Orchid.Goals, :create, [
  "fully reimplement diablo 2 demo from recovered behavior",
  "Target a full reimplementation of the Diablo II demo (no WASM porting yet). Use this installer as source material: https://archive.org/download/DiabloIiDemo/DiabloIIDemo.exe. ASM-to-C translation must be performed manually by Coder/Reverse Engineer agents; do not use automated decompiler tools to generate C from assembly.",
  project.id
])
IO.puts("  goal ID: #{goal.id}")
IO.puts("  goal: #{goal.name}")

IO.puts("\nDone. GoalWatcher will pick up the project and spawn a planner within 10s.")
