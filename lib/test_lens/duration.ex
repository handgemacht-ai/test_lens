defmodule TestLens.Duration do
  @moduledoc """
  The single authority for the microseconds → milliseconds display conversion.

  Durations cross the Elixir/JS boundary as a raw `duration_us` integer (the
  on-disk JSON wire format, owned by `TestLens.Recorder`), and are re-converted
  to a `"X.Xms"` display string independently at several render sites. The
  us-vs-ms unit is implicit everywhere; this module names it once so the Elixir
  render path (`TestLens.Charts`) routes through one conversion instead of
  re-deriving `us / 1000` at each call site.

  The on-disk `duration_us` integer is unchanged; this module only owns the
  *display* conversion. It accepts the raw microseconds integer (or a number
  already read back from JSON) and exposes:

    * `to_ms/1` — microseconds → float milliseconds (the numeric value the JS
      renderers precompute into `c._dur`);
    * `to_string/1` — microseconds → the canonical `"X.Xms"` display string
      (one decimal place, matching `:erlang.float_to_binary(_, decimals: 1)`).

  A non-number collapses to `nil` so a case with no timing data degrades to a
  blank rather than a `NaNms` string, preserving the previous render behaviour.
  """

  @doc """
  Microseconds → float milliseconds. Returns `nil` for a non-number so a
  timing-less case stays blank at the render boundary.
  """
  @spec to_ms(number() | nil) :: float() | nil
  def to_ms(us) when is_number(us), do: us / 1000
  def to_ms(_), do: nil

  @doc """
  Microseconds → the canonical `"X.Xms"` display string (one decimal place),
  the single source for the Elixir render path. Returns `nil` for a non-number
  so the caller can omit the field entirely instead of emitting `NaNms`.
  """
  @spec to_string(number() | nil) :: String.t() | nil
  def to_string(us) when is_number(us) do
    :erlang.float_to_binary(us / 1000, decimals: 1) <> "ms"
  end

  def to_string(_), do: nil
end
