defmodule Orchid.Tools.Eval do
  @moduledoc "Evaluate Elixir code (REPL)"
  @behaviour Orchid.Tool

  alias Orchid.Object

  @impl true
  def name, do: "eval"

  @impl true
  def description, do: "Evaluate Elixir code directly or evaluate a function object by ID"

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        code: %{
          type: "string",
          description: "Elixir code to evaluate (optional if object_id provided)"
        },
        object_id: %{
          type: "string",
          description: "ID of a function object to evaluate (optional if code provided)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(%{"object_id" => id}, _context) when is_binary(id) do
    case Object.eval(id) do
      {:ok, result} -> {:ok, inspect(result, pretty: true)}
      {:error, :not_found} -> {:error, "Object not found: #{id}"}
      {:error, :not_a_function} -> {:error, "Object is not a function type"}
      {:error, {:eval_error, msg}} -> {:error, "Evaluation error: #{msg}"}
    end
  end

  def execute(%{"code" => code}, _context) when is_binary(code) do
    try do
      {result, _binding} = Code.eval_string(code)
      {:ok, inspect(result, pretty: true)}
    rescue
      e -> {:error, "Evaluation error: #{Exception.message(e)}"}
    end
  end

  def execute(_args, _context) do
    {:error, "Either 'code' or 'object_id' must be provided"}
  end
end
