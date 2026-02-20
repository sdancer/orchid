defmodule Orchid.Tools.ObjectWrite do
  @moduledoc "Update an object's content"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "object_write"

  @impl true
  def description, do: "Update the content of an existing object"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        id: %{
          type: "string",
          description: "The ID of the object to update"
        },
        content: %{
          type: "string",
          description: "The new content for the object"
        }
      },
      required: ["id", "content"]
    }
  end

  @impl true
  def execute(%{"id" => id, "content" => content}, _context) do
    with {:ok, obj} <- Object.get(id),
         :ok <- validate_content(obj, content),
         {:ok, updated} <- Object.update(id, content) do
      {:ok, "Updated object #{updated.name} (#{updated.id})"}
    else
      {:error, :not_found} ->
        {:error, "Object not found: #{id}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  def execute(_args, _context), do: {:error, "Missing required parameters: id, content"}

  defp validate_content(obj, content) do
    if String.starts_with?(obj.name, "candidate_plan_") do
      validate_candidate_plan(content)
    else
      :ok
    end
  end

  defp validate_candidate_plan(content) when is_binary(content) do
    with {:ok, parsed} <- Jason.decode(content),
         :ok <- validate_required_string(parsed, "goal"),
         :ok <- validate_required_string(parsed, "strategy"),
         :ok <- validate_required_string_list(parsed, "steps"),
         :ok <- validate_required_string_list(parsed, "checks"),
         :ok <- validate_optional_string_list(parsed, "risks") do
      :ok
    else
      {:error, %Jason.DecodeError{}} ->
        {:error,
         "candidate_plan_* content must be valid JSON with keys: goal, strategy, steps[], checks[], risks[] (optional)."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) != "" do
          :ok
        else
          {:error, "candidate_plan_* field `#{key}` must be a non-empty string."}
        end

      _ ->
        {:error, "candidate_plan_* field `#{key}` must be a non-empty string."}
    end
  end

  defp validate_required_string_list(map, key) do
    case Map.get(map, key) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          :ok
        else
          {:error, "candidate_plan_* field `#{key}` must be a non-empty list of non-empty strings."}
        end

      _ ->
        {:error, "candidate_plan_* field `#{key}` must be a non-empty list of non-empty strings."}
    end
  end

  defp validate_optional_string_list(map, key) do
    case Map.get(map, key) do
      nil ->
        :ok

      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          :ok
        else
          {:error, "candidate_plan_* field `#{key}` must be a list of non-empty strings when present."}
        end

      _ ->
        {:error, "candidate_plan_* field `#{key}` must be a list of non-empty strings when present."}
    end
  end
end
