defmodule Orchid.Tools.FileRead do
  @moduledoc "Read file contents"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "read"

  @impl true
  def description, do: "Read the contents of a file"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to read"
        },
        offset: %{
          type: "integer",
          description: "Line number to start from (1-indexed, default: 1)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of lines to read (default: all)"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def execute(%{"path" => path} = args, _context) do
    offset = (args["offset"] || 1) - 1
    limit = args["limit"]

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        lines =
          lines
          |> Enum.drop(offset)
          |> then(fn l -> if limit, do: Enum.take(l, limit), else: l end)
          |> Enum.with_index(offset + 1)
          |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
          |> Enum.join("\n")

        {:ok, lines}

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{reason}"}
    end
  end

  def execute(_args, _context) do
    {:error, "path is required"}
  end
end
