defmodule TestLens.Phase do
  @moduledoc """
  The closed enum of test phases TestLens refracts a test through: input →
  action → result, named `:setup` / `:action` / `:verify`.

  Each test's captures and db-events are filed under one of these phases, and
  the viewers render them as three refraction channels. The phase name crossed
  several module boundaries as a bare string — produced by `TestLens.stage/1`
  and the `setup`/`action`/`verify` block macros (`TestLens.__phase__/3`),
  defaulted as the literal `"setup"` in `TestLens.Recorder`, and redeclared as a
  positional 4-tuple `[name, label, cssClass, romanIdx]` in the shared JS
  (`TestLens.Assets.buildStages`) and again as `{setup, action, verify}` in
  `TestLens.Viewer.shape/1`. This module is the single Elixir authority for the
  closed set and the atom ↔ string conversion, so those sites share one source
  instead of re-deriving it.

  The on-disk JSON wire format stays the bare string the recorder always wrote;
  `to_string/1` emits exactly that. It accepts the typed atom or the canonical
  string so the producer (`stage/1`) and the recorder's literal default share one
  authority. To preserve the recorder's existing tolerance for a stage outside
  the closed set — which `TestLens.stage/1` accepts (`is_atom/1` or
  `is_binary/1`) and the shared JS renders as a fallback channel — `to_string/1`
  passes any non-canonical value through `Kernel.to_string/1` rather than
  raising. The closed set is still named and queryable via `t()`, `strings/0`
  and the fail-closed `from_string/1`; only the *boundary* stays lenient, so the
  named type is internal and observable behavior is unchanged.

  The shared JS mirrors this enum as a single `PHASES` table keyed by name →
  `{label, cssClass, index}` (named fields, not positional tuples), so
  `buildStages` and `shape` share one source on the client side too.
  """

  @type t :: :setup | :action | :verify

  @known ~w(setup action verify)a

  @doc """
  The canonical on-disk JSON strings, in enum order. Exposed so callers that
  need the closed set (e.g. the shared JS `PHASES` table) do not re-derive it.
  """
  @spec strings() :: [String.t()]
  def strings, do: @known |> Enum.map(&Atom.to_string/1)

  @doc """
  Lift an on-disk JSON phase string to `t()`. Returns `{:ok, t()}` for a member
  of the closed set, else `:error` (fail-closed to the enum) so a future value
  cannot pass through as a bare primitive. The recorder does not force this on
  its read path — it keeps the lenient string — but a typed reader that wants
  the closed set uses this instead of re-deriving the membership check.
  """
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string("setup"), do: {:ok, :setup}
  def from_string("action"), do: {:ok, :action}
  def from_string("verify"), do: {:ok, :verify}
  def from_string(_), do: :error

  @doc """
  The canonical JSON string for a phase — the single source for the on-disk
  value. Accepts the typed atom or the canonical string (the on-disk form) so
  the producer (`TestLens.stage/1`, the block macros) and the recorder's
  literal default share one authority.

  A value outside the closed set is passed through `Kernel.to_string/1` rather
  than raising, preserving `TestLens.stage/1`'s documented acceptance of any
  atom/binary and the shared JS's fallback channel for an unknown stage. The
  known three are canonicalized identically to `Kernel.to_string/1`, so
  routing the producers through this authority changes nothing observable.
  """
  @spec to_string(t() | String.t() | atom()) :: String.t()
  def to_string(:setup), do: "setup"
  def to_string(:action), do: "action"
  def to_string(:verify), do: "verify"
  def to_string("setup"), do: "setup"
  def to_string("action"), do: "action"
  def to_string("verify"), do: "verify"
  def to_string(other), do: Kernel.to_string(other)
end
