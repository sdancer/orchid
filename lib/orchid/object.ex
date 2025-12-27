defmodule Orchid.Object do
  @moduledoc """
  Core editable unit in Orchid.

  Object types:
  - :file - source code files with filesystem path
  - :artifact - generated content (code, data, configs)
  - :markdown - documentation, notes, plans
  - :function - executable code blocks for REPL eval
  """

  alias Orchid.Store

  @type object_type :: :file | :artifact | :markdown | :function
  @type t :: %__MODULE__{
    id: String.t(),
    type: object_type(),
    name: String.t(),
    path: String.t() | nil,
    content: String.t(),
    language: String.t() | nil,
    metadata: map(),
    versions: [map()],
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  defstruct [
    :id,
    :type,
    :name,
    :path,
    :content,
    :language,
    metadata: %{},
    versions: [],
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Create a new object.

  ## Options
  - `:path` - filesystem path (for :file type)
  - `:language` - programming language (for syntax/eval)
  - `:metadata` - additional metadata map
  """
  def create(type, name, content, opts \\ []) when type in [:file, :artifact, :markdown, :function] do
    now = DateTime.utc_now()

    object = %__MODULE__{
      id: generate_id(),
      type: type,
      name: name,
      path: Keyword.get(opts, :path),
      content: content,
      language: Keyword.get(opts, :language, detect_language(name, type)),
      metadata: Keyword.get(opts, :metadata, %{}),
      versions: [],
      created_at: now,
      updated_at: now
    }

    :ok = Store.put_object(object)
    {:ok, object}
  end

  @doc """
  Get an object by ID.
  """
  def get(id) do
    Store.get_object(id)
  end

  @doc """
  Update an object's content, preserving history.
  """
  def update(id, new_content) do
    with {:ok, object} <- get(id) do
      now = DateTime.utc_now()

      version = %{
        content: object.content,
        timestamp: object.updated_at
      }

      updated = %{object |
        content: new_content,
        versions: [version | object.versions] |> Enum.take(50),
        updated_at: now
      }

      :ok = Store.put_object(updated)
      {:ok, updated}
    end
  end

  @doc """
  Delete an object.
  """
  def delete(id) do
    Store.delete_object(id)
  end

  @doc """
  List all objects.
  """
  def list do
    Store.list_objects()
  end

  @doc """
  Evaluate a function object (REPL).
  Only works for :function type objects with Elixir code.
  """
  def eval(id) do
    with {:ok, object} <- get(id) do
      if object.type != :function do
        {:error, :not_a_function}
      else
        try do
          {result, _binding} = Code.eval_string(object.content)
          {:ok, result}
        rescue
          e -> {:error, {:eval_error, Exception.message(e)}}
        end
      end
    end
  end

  @doc """
  Undo the last change to an object.
  """
  def undo(id) do
    with {:ok, object} <- get(id) do
      case object.versions do
        [] ->
          {:error, :no_history}
        [prev | rest] ->
          restored = %{object |
            content: prev.content,
            versions: rest,
            updated_at: DateTime.utc_now()
          }
          :ok = Store.put_object(restored)
          {:ok, restored}
      end
    end
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp detect_language(name, type) do
    cond do
      type == :markdown -> "markdown"
      type == :function -> "elixir"
      true -> detect_from_extension(name)
    end
  end

  defp detect_from_extension(name) do
    case Path.extname(name) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".py" -> "python"
      ".rb" -> "ruby"
      ".rs" -> "rust"
      ".go" -> "go"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".md" -> "markdown"
      ".html" -> "html"
      ".css" -> "css"
      _ -> nil
    end
  end
end
