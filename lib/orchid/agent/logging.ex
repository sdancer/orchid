defmodule Orchid.Agent.Logging do
  @moduledoc false
  require Logger

  @chunk_size 1800

  def log_full(label, text) when is_binary(label) and is_binary(text) do
    chunks = chunk_text(text, @chunk_size)
    total = length(chunks)

    Enum.with_index(chunks, 1)
    |> Enum.each(fn {chunk, idx} ->
      Logger.info("[#{label}] Raw LLM response (part #{idx}/#{total}):\n#{chunk}")
    end)
  end

  defp chunk_text("", _size), do: [""]

  defp chunk_text(text, size) when is_binary(text) and size > 0 do
    do_chunk(text, size, [])
    |> Enum.reverse()
  end

  defp do_chunk("", _size, acc), do: acc

  defp do_chunk(text, size, acc) do
    if String.length(text) <= size do
      [text | acc]
    else
      head = String.slice(text, 0, size)
      tail = String.slice(text, size, String.length(text) - size)
      do_chunk(tail, size, [head | acc])
    end
  end
end
