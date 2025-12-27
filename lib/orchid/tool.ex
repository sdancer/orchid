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
    Orchid.Tools.Eval
  ]

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
  """
  def execute(name, args, context) do
    case find_tool(name) do
      nil -> {:error, {:unknown_tool, name}}
      mod -> mod.execute(args, context)
    end
  end

  defp find_tool(name) do
    Enum.find(@tools, fn mod -> mod.name() == name end)
  end
end
