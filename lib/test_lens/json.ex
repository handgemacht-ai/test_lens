defmodule TestLens.JSON do
  @moduledoc """
  Make arbitrary test values JSON-encodable without the caller caring. Structs
  become maps (tagged with their module), tuples become lists, and anything
  exotic (pids, refs, functions, non-UTF-8 binaries) falls back to inspect/1.
  """

  @max_depth 12

  @doc "Recursively coerce a value into JSON-safe data."
  def sanitize(value), do: do_sanitize(value, 0)

  defp do_sanitize(_value, depth) when depth > @max_depth, do: "…"

  defp do_sanitize(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: value

  defp do_sanitize(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp do_sanitize(value, _depth) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  defp do_sanitize(%_{} = struct, depth) do
    map =
      struct
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> do_sanitize(depth)

    Map.put(map, "__struct__", inspect(struct.__struct__))
  end

  defp do_sanitize(value, depth) when is_map(value) do
    Map.new(value, fn {k, v} -> {key(k), do_sanitize(v, depth + 1)} end)
  end

  defp do_sanitize(value, depth) when is_list(value) do
    Enum.map(value, &do_sanitize(&1, depth + 1))
  end

  defp do_sanitize(value, depth) when is_tuple(value) do
    value |> Tuple.to_list() |> do_sanitize(depth)
  end

  defp do_sanitize(value, _depth), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
