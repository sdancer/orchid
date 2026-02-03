defmodule Orchid.Tools.FileEdit do
  @moduledoc "Edit file contents"
  @behaviour Orchid.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description, do: "Edit a file by replacing old_string with new_string"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to edit"
        },
        old_string: %{
          type: "string",
          description: "The exact string to find and replace"
        },
        new_string: %{
          type: "string",
          description: "The string to replace it with"
        }
      },
      required: ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new}, _context) do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, old) do
          count = length(String.split(content, old)) - 1

          if count > 1 do
            {:error, "old_string appears #{count} times - must be unique. Add more context."}
          else
            new_content = String.replace(content, old, new, global: false)

            case File.write(path, new_content) do
              :ok -> {:ok, "Successfully edited #{path}"}
              {:error, reason} -> {:error, "Failed to write #{path}: #{reason}"}
            end
          end
        else
          {:error, "old_string not found in #{path}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{reason}"}
    end
  end

  def execute(_args, _context) do
    {:error, "path, old_string, and new_string are required"}
  end
end
