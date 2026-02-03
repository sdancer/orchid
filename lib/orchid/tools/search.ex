defmodule Orchid.Tools.Search do
  @moduledoc "Search across objects"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "search"

  @impl true
  def description, do: "Search for a pattern across all objects"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "Text pattern or regex to search for"
        },
        type: %{
          type: "string",
          enum: ["file", "artifact", "markdown", "function"],
          description: "Filter by object type (optional)"
        },
        regex: %{
          type: "boolean",
          description: "Treat pattern as regex (default: false)"
        }
      },
      required: ["pattern"]
    }
  end

  @impl true
  def execute(%{"pattern" => pattern} = args, _context) do
    objects = Object.list()

    # Filter by type if specified
    objects =
      if args["type"] do
        type = String.to_existing_atom(args["type"])
        Enum.filter(objects, fn obj -> obj.type == type end)
      else
        objects
      end

    # Search for pattern
    use_regex = args["regex"] == true
    matches = search_objects(objects, pattern, use_regex)

    if matches == [] do
      {:ok, "No matches found for: #{pattern}"}
    else
      result =
        matches
        |> Enum.map(fn {obj, line_matches} ->
          header = "=== #{obj.name} (#{obj.id}) ==="

          lines =
            Enum.map(line_matches, fn {line_num, line} ->
              "  #{line_num}: #{String.trim(line)}"
            end)

          [header | lines] |> Enum.join("\n")
        end)
        |> Enum.join("\n\n")

      {:ok, result}
    end
  end

  defp search_objects(objects, pattern, use_regex) do
    regex =
      if use_regex do
        case Regex.compile(pattern) do
          {:ok, r} -> r
          _ -> nil
        end
      else
        nil
      end

    objects
    |> Enum.map(fn obj -> {obj, find_matches(obj.content, pattern, regex)} end)
    |> Enum.filter(fn {_obj, matches} -> matches != [] end)
  end

  defp find_matches(content, pattern, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _num} ->
      if regex do
        Regex.match?(regex, line)
      else
        String.contains?(line, pattern)
      end
    end)
    |> Enum.map(fn {line, num} -> {num, line} end)
  end
end
