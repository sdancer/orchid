defmodule Orchid.Facts do
  @moduledoc """
  Loads local, untracked facts from disk into Orchid's fact objects.

  Default source file: `.orchid/facts.local.json`
  """

  alias Orchid.Object

  @default_file ".orchid/facts.local.json"

  @spec seed_from_local_file() :: {:ok, map()}
  def seed_from_local_file do
    path = source_file()

    case File.read(path) do
      {:ok, raw} ->
        with {:ok, decoded} <- Jason.decode(raw),
             {:ok, entries} <- normalize_entries(decoded) do
          stats =
            Enum.reduce(entries, %{created: 0, updated: 0, skipped: 0}, fn {name, value, metadata},
                                                                           acc ->
              upsert_fact(name, value, metadata, acc)
            end)

          {:ok, Map.put(stats, :path, path)}
        else
          {:error, reason} -> {:ok, %{created: 0, updated: 0, skipped: 0, path: path, error: reason}}
        end

      {:error, :enoent} ->
        {:ok, %{created: 0, updated: 0, skipped: 0, path: path, missing: true}}

      {:error, reason} ->
        {:ok, %{created: 0, updated: 0, skipped: 0, path: path, error: inspect(reason)}}
    end
  end

  def source_file do
    Application.get_env(:orchid, :facts_source_file, @default_file)
    |> Path.expand()
  end

  defp normalize_entries(map) when is_map(map) do
    entries =
      map
      |> Enum.flat_map(fn
        {name, value} when is_binary(name) and is_binary(value) ->
          [{name, value, default_metadata(name)}]

        {name, %{"value" => value} = cfg} when is_binary(name) and is_binary(value) ->
          metadata =
            default_metadata(name)
            |> Map.merge(%{
              category: cfg["category"] || "API Keys",
              sensitive: Map.get(cfg, "sensitive", true),
              description: cfg["description"] || ""
            })

          [{name, value, metadata}]

        _ ->
          []
      end)

    {:ok, entries}
  end

  defp normalize_entries(_), do: {:error, "expected JSON object at top-level"}

  defp upsert_fact(name, value, metadata, acc) when is_binary(name) and is_binary(value) do
    case Object.get_fact_by_name(name) do
      nil ->
        case Object.create(:fact, name, value, metadata: metadata) do
          {:ok, _} -> %{acc | created: acc.created + 1}
          _ -> %{acc | skipped: acc.skipped + 1}
        end

      fact ->
        content_changed = fact.content != value
        desired_metadata = Map.merge(fact.metadata || %{}, metadata)
        metadata_changed = desired_metadata != (fact.metadata || %{})

        cond do
          content_changed and metadata_changed ->
            case Object.update(fact.id, value) do
              {:ok, _} ->
                case Object.update_metadata(fact.id, desired_metadata) do
                  {:ok, _} -> %{acc | updated: acc.updated + 1}
                  _ -> %{acc | skipped: acc.skipped + 1}
                end

              _ ->
                %{acc | skipped: acc.skipped + 1}
            end

          content_changed ->
            case Object.update(fact.id, value) do
              {:ok, _} -> %{acc | updated: acc.updated + 1}
              _ -> %{acc | skipped: acc.skipped + 1}
            end

          metadata_changed ->
            case Object.update_metadata(fact.id, desired_metadata) do
              {:ok, _} -> %{acc | updated: acc.updated + 1}
              _ -> %{acc | skipped: acc.skipped + 1}
            end

          true ->
            %{acc | skipped: acc.skipped + 1}
        end
    end
  end

  defp default_metadata(name) do
    %{
      category: "API Keys",
      sensitive: true,
      description: "Loaded from local facts source file",
      source: "local_facts_file",
      source_name: name
    }
  end
end
