defmodule TestLens.CaseId do
  @moduledoc """
  The stable cross-run identity of a test case: `module <> "::" <> name`.

  A case is matched across runs (and de-duplicated within a build) by this
  identity. It is a pure derivation from two case fields — the on-disk JSON
  never stores it — so it is re-derived at every read. This module is the single
  authority for that derivation: the `<> "::" <>` concatenation that was inlined
  in `TestLens.Diff.identity/1` (and re-used by `TestLens.Viewer.dedupe/1`) now
  lives in `to_string/1`, and `parse/1` round-trips the same wire string.

  The on-disk and embedded JSON wire format is unchanged — `to_string/1` emits
  exactly `module <> "::" <> name`, the `::` delimiter the shared JS
  (`TestLens.Assets.js/0`) also re-derives on its side. The named type is
  internal: case maps keep their string `module`/`name` fields, and
  `TestLens.Diff.identity/1` still returns the canonical string so the diff's
  public surface (and its tests) are untouched.
  """

  @enforce_keys [:module, :name]
  defstruct [:module, :name]

  @type t :: %__MODULE__{module: String.t(), name: String.t()}

  # The delimiter is never parsed off the wire by Elixir — it is only re-derived
  # — but `parse/1` pins it 1:1 to `to_string/1` so the round-trip is symmetric.
  @delimiter "::"

  @doc """
  Build a `t()` from a decoded case's `module`/`name` fields.

  Mirrors the former `TestLens.Diff.identity/1` input handling exactly: each
  field is coerced with `to_string/1` so a missing key (`nil`) reads as `""`
  rather than raising, matching the lenient reader that already skips half- or
  non-conforming case files.
  """
  @spec from_case(map()) :: t()
  def from_case(c) when is_map(c) do
    %__MODULE__{
      module: Kernel.to_string(Map.get(c, "module")),
      name: Kernel.to_string(Map.get(c, "name"))
    }
  end

  @doc """
  The canonical wire string `module::name` — the single source for the
  on-disk/embedded identity. Emits exactly `module <> "::" <> name`, preserving
  the format the recorder writes, both viewers' HTML embeds, and the shared JS
  re-derives.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{module: module, name: name}), do: module <> @delimiter <> name

  @doc """
  Parse a wire `module::name` string back into a `t()`, splitting on the first
  `::` so a `name` that itself contains `::` round-trips. Returns `{:ok, t()}`
  for a non-empty `module::name`, else `:error` (fail-closed rather than
  yielding a half-empty identity).
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(s) when is_binary(s) do
    case String.split(s, @delimiter, parts: 2) do
      [module, name] when module != "" and name != "" ->
        {:ok, %__MODULE__{module: module, name: name}}

      _ ->
        :error
    end
  end

  def parse(_), do: :error
end
