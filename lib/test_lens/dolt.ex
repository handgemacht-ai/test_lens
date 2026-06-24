defmodule TestLens.Dolt do
  @moduledoc """
  Capture adapter for [Dolt](https://github.com/dolthub/dolt) version-control
  operations inside ExUnit tests.

  Call `capture/2` from a test to record a Dolt operation — a commit, branch
  creation, merge, or diff — as a `"dolt_op"` capture. The viewer renders it
  as a styled version-control delta: an action badge, the branch name, the
  short commit hash, and the commit message.

  Because the entry goes into the generic `captures` list (not `db_events`),
  the *DB writes* counter in the viewer stays tied to row mutations only.
  A test whose only captures are `dolt_op` entries will show `db_writes = 0`.

  ## Usage

      test "commits a schema migration" do
        TestLens.stage(:action)

        TestLens.Dolt.capture(self(), %{
          action: "commit",
          branch: "feature/add-index",
          commit_hash: "abc1234",
          message: "Add index on annotations.org_id"
        })
      end

  ## Writing a capture adapter (collect → transform → render)

  `TestLens.Dolt` is the reference implementation of the adapter contract.
  Any external source — a message queue, a cache layer, a version-control
  system, an S3 upload, a billing event — can be surfaced in the viewer
  without touching the TestLens core:

  ### 1. Collect

  Call the existing `TestLens.capture/3` seam (or `TestLens.Recorder.add_capture/5`
  directly if the pid is available) with a `kind:` option set to your
  source's kind string:

      TestLens.capture("dolt commit", op_map, kind: :dolt_op)

  That's it for collection. The recorder accepts any kind string; no
  core change is required.

  ### 2. Transform

  Your `value` is whatever map or scalar makes the capture meaningful. Pass
  through `TestLens.JSON.sanitize/1` for safety (all non-JSON-encodable types
  become strings). Recommended shape for structured adapters:

      %{
        action: "commit" | "branch" | "merge" | "diff",
        branch: String.t() | nil,
        commit_hash: String.t() | nil,
        message:  String.t() | nil,
        result:   term()         # optional; any sanitizable value
      }

  ### 3. Render

  The viewer's `kindRenderers` JS object maps `kind -> fn(value) -> html`.
  If your kind is not registered, the viewer falls back to a formatted JSON
  block — meaning **a new source needs zero core edit** for basic visibility.

  To add a bespoke renderer, add one entry to `kindRenderers` in `viewer.ex`:

      dolt_op: v => ... // returns an HTML string

  This is the only file that ever needs to change, and only when you want
  richer styling than the generic JSON fallback.

  ### Summary

  | Step    | What you do                                  | Core change? |
  |---------|----------------------------------------------|--------------|
  | Collect | Call `TestLens.capture/3` with `kind:`       | None         |
  | Transform | Shape your value map; sanitize it          | None         |
  | Render  | Optional: add one entry to `kindRenderers`   | One entry    |
  """

  alias TestLens.{JSON, Recorder}

  @doc """
  Record a Dolt version-control operation as a capture on the running test.

  `pid` is the test process (`self()` from the test body).

  `op_map` should contain:

  - `:action` — `"commit"`, `"branch"`, `"merge"`, or `"diff"` (required)
  - `:branch` — branch name (optional)
  - `:commit_hash` — the short or full hash (optional)
  - `:message` — commit message or description (optional)
  - `:result` — any additional result value (optional)

  The entry is stored under kind `"dolt_op"` in the `captures` list
  (not in `db_events`), so the DB-writes counter is unaffected.
  """
  @spec capture(pid(), map()) :: :ok
  def capture(pid, op_map) when is_map(op_map) do
    label = label_for(op_map)
    sanitized = JSON.sanitize(op_map)
    Recorder.add_capture(pid, label, "dolt_op", sanitized, nil)
  end

  defp label_for(%{action: action, branch: branch}) when not is_nil(branch),
    do: "dolt #{action} on #{branch}"

  defp label_for(%{action: action}), do: "dolt #{action}"
  defp label_for(_), do: "dolt op"
end
