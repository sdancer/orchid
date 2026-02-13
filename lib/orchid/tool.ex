defmodule Orchid.Tool do
  @moduledoc """
  Tool behaviour and execution for agent tools.
  Tools allow agents to interact with objects, run code, and execute commands.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}

  @tools [
    Orchid.Tools.FileList,
    Orchid.Tools.FileRead,
    Orchid.Tools.FileEdit,
    Orchid.Tools.FileGrep,
    Orchid.Tools.Shell,
    Orchid.Tools.Eval,
    Orchid.Tools.PromptList,
    Orchid.Tools.PromptRead,
    Orchid.Tools.PromptCreate,
    Orchid.Tools.PromptUpdate,
    Orchid.Tools.GoalList,
    Orchid.Tools.GoalRead,
    Orchid.Tools.GoalCreate,
    Orchid.Tools.GoalUpdate,
    Orchid.Tools.SandboxReset,
    Orchid.Tools.AgentSpawn
  ]

  @sandboxed_tools ~w(shell read edit list grep)

  @doc """
  List all available tools with their schemas.
  """
  def list_tools do
    Enum.map(@tools, fn mod ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters: mod.parameters()
      }
    end)
  end

  @doc """
  Execute a tool by name.
  Routes sandboxed tools through the sandbox when active.
  """
  def execute(name, args, context) do
    case find_tool(name) do
      nil ->
        {:error, {:unknown_tool, name}}

      mod ->
        if name in @sandboxed_tools and sandbox_active?(context) do
          execute_in_sandbox(name, args, context)
        else
          mod.execute(args, context)
        end
    end
  end

  defp find_tool(name) do
    Enum.find(@tools, fn mod -> mod.name() == name end)
  end

  defp sandbox_active?(%{agent_state: %{sandbox: s}}) when not is_nil(s) and s != false, do: true
  defp sandbox_active?(_), do: false

  defp execute_in_sandbox(name, args, ctx) do
    pid = ctx.agent_state.project_id

    case name do
      "shell" ->
        Orchid.Sandbox.exec(pid, args["command"], timeout: args["timeout"] || 30_000)

      "read" ->
        Orchid.Sandbox.read_file(pid, args["path"])

      "edit" ->
        Orchid.Sandbox.edit_file(pid, args["path"], args["old_string"], args["new_string"])

      "list" ->
        Orchid.Sandbox.list_files(pid, args["path"] || "/workspace")

      "grep" ->
        Orchid.Sandbox.grep_files(pid, args["pattern"], args["path"] || "/workspace", glob: args["glob"])
    end
  end
end
