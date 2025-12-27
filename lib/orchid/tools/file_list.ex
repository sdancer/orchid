defmodule Orchid.Tools.FileList do
  @moduledoc "List directory contents"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "list"

  @impl true
  def description, do: "List files and directories in a path"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Directory path to list (default: current directory)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(args, _context) do
    path = args["path"] || "."

    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn entry ->
          full_path = Path.join(path, entry)
          type = if File.dir?(full_path), do: "dir", else: "file"
          "#{type}\t#{entry}"
        end)
        |> Enum.join("\n")
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, "Failed to list #{path}: #{reason}"}
    end
  end
end
