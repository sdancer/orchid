defmodule Orchid.Agent.Tools do
  @moduledoc """
  Executes leaf tasks and returns explicit success/failure tuples.
  """

  alias Orchid.Tool

  @spec execute(map(), map()) :: {:ok, any()} | {:error, String.t(), map()}
  def execute(task, context \\ %{}) when is_map(task) do
    tool = task[:tool] || task["tool"]
    args = task[:args] || task["args"] || %{}

    if is_binary(tool) and is_map(args) do
      normalized_tool = normalize_tool_name(tool)

      case Tool.execute(normalized_tool, args, context) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, "Tool execution failed",
           %{tool: normalized_tool, original_tool: tool, reason: inspect(reason), args: args}}
      end
    else
      {:error, "Invalid tool task", %{task: task}}
    end
  end

  defp normalize_tool_name(tool) when is_binary(tool) do
    canonical =
      tool
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/^default_api[:.\/]/, "")
      |> String.replace(~r/^tools?[:.\/]/, "")
      |> String.replace(~r/^orchid[:.\/]/, "")

    case canonical do
      "list_files" -> "list"
      "file_list" -> "list"
      "read_file" -> "read"
      "file_read" -> "read"
      "edit_file" -> "edit"
      "file_edit" -> "edit"
      "grep_files" -> "grep"
      "file_grep" -> "grep"
      "run_shell" -> "shell"
      "execute_shell" -> "shell"
      other -> other
    end
  end
end
