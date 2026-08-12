defmodule TestLens.Status do
  @moduledoc """
  The closed enum of test outcomes TestLens records and renders.

  Six values, derived from the states ExUnit assigns a finished test:

    * `:passed`   — the test ran and succeeded (ExUnit's `nil` state)
    * `:failed`   — the test ran and failed
    * `:skipped`   — the test was skipped
    * `:excluded` — the test was excluded by a tag filter
    * `:invalid`  — the test was invalid
    * `:unknown`  — anything else ExUnit may introduce in the future

  Three conversions form the atom ↔ string ↔ CSS-class triangle, each with a
  single implementation here so the four Elixir sites and the shared JS that
  re-derived these mappings independently now share one authority:

    * `from_exunit/1` — ExUnit test state → `t()` (replaces the former
      `status/1` in `TestLens.Formatter`);
    * `to_string/1` — `t()` → the on-disk JSON string. The recorder writes it,
      `TestLens.Diff` serializes case refs back to it, and both viewers' JS
      expects exactly these strings. It accepts the typed atom or the canonical
      string so the read and write boundaries share one source;
    * `css_class/1` — `t()` → the `:pass | :skip | :fail` atom the charts and the
      shared JS `kind` collapse to (replaces the former `kind/1` in
      `TestLens.Charts`).

  The on-disk case format keeps its string; `TestLens.Viewer` lifts it to `t()`
  once at its read boundary (`load_cases/1`) so the render path is typed.
  """

  @type t :: :passed | :failed | :skipped | :excluded | :invalid | :unknown

  @known ~w(passed failed skipped excluded invalid unknown)a

  @doc """
  The canonical on-disk JSON strings, in enum order. Exposed so callers that
  need the closed set (e.g. invariant checks) do not re-derive it.
  """
  @spec strings() :: [String.t()]
  def strings, do: @known |> Enum.map(&Atom.to_string/1)

  @doc """
  Map an ExUnit finished-test state to a `t()`. `nil` is the state ExUnit leaves
  on a passing test; the tagged tuples are its named non-passing states; anything
  else collapses to `:unknown` so a future ExUnit state can never silently pass
  through as a bare string.
  """
  @spec from_exunit(term()) :: t()
  def from_exunit(nil), do: :passed
  def from_exunit({:failed, _}), do: :failed
  def from_exunit({:skipped, _}), do: :skipped
  def from_exunit({:excluded, _}), do: :excluded
  def from_exunit({:invalid, _}), do: :invalid
  def from_exunit(_), do: :unknown

  @doc """
  Lift an on-disk JSON status string to `t()`. A string outside the closed set
  collapses to `:unknown` (fail-closed to the enum) rather than passing through
  as a bare primitive.
  """
  @spec from_string(String.t()) :: t()
  def from_string(s) when s in @known, do: String.to_existing_atom(s)
  def from_string(_), do: :unknown

  @doc """
  The canonical JSON string for a status — the single source for the on-disk
  value. Accepts the typed atom or the canonical string (the on-disk form) so
  the recorder's write path and the diff's read/serialize path share one
  authority. A value outside the closed set raises `FunctionClauseError`
  (fail-closed) rather than emitting an untracked string.
  """
  @spec to_string(t() | String.t()) :: String.t()
  def to_string(:passed), do: "passed"
  def to_string(:failed), do: "failed"
  def to_string(:skipped), do: "skipped"
  def to_string(:excluded), do: "excluded"
  def to_string(:invalid), do: "invalid"
  def to_string(:unknown), do: "unknown"
  def to_string("passed"), do: "passed"
  def to_string("failed"), do: "failed"
  def to_string("skipped"), do: "skipped"
  def to_string("excluded"), do: "excluded"
  def to_string("invalid"), do: "invalid"
  def to_string("unknown"), do: "unknown"

  @doc """
  The CSS-class atom a status collapses to for the charts and the shared JS
  renderer: `:pass` for a pass, `:skip` for skipped or excluded, `:fail` for
  everything else. The shared JS `kind` (see `TestLens.Assets.js/0`) is pinned
  1:1 to these outputs.
  """
  @spec css_class(t() | String.t()) :: :pass | :skip | :fail
  def css_class(:passed), do: :pass
  def css_class(:failed), do: :fail
  def css_class(:skipped), do: :skip
  def css_class(:excluded), do: :skip
  def css_class(:invalid), do: :fail
  def css_class(:unknown), do: :fail
  def css_class("passed"), do: :pass
  def css_class("failed"), do: :fail
  def css_class("skipped"), do: :skip
  def css_class("excluded"), do: :skip
  def css_class("invalid"), do: :fail
  def css_class("unknown"), do: :fail
end
