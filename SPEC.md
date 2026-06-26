# Test Lens run format — on-disk contract

This is the stable contract two downstream workstreams build against: a
**run-vs-merge-base diff viewer**, and a **Go admin panel** that discovers runs
across repos and worktrees. Treat the schema strings and field names here as
stable. New fields may be *added* within a schema version; existing fields will
not be renamed or removed without a version bump.

## 1. Directory layout

A single output root (the `dir:` passed to `TestLens.start/1`, default
`test_lens_out`) holds many runs, each in its own directory. A run never
overwrites a previous one.

```
<dir>/
  runs/
    latest                      # pointer file: contents = the newest run_id (best-effort)
    <run_id>/
      meta.json                 # run-level summary (schema test_lens_run/v1)
      cases/
        <slug>.json             # one file per test (schema test_lens/v1.1)
      index.html                # built viewer for this run (written by Viewer.build)
  index.html                    # built viewer for the latest run (workspace-root build)
```

* `<run_id>` is filesystem-safe and unique (see §3).
* `runs/latest` is a plain text file containing the most recent `run_id`. It is a
  best-effort convenience for humans and tools; the canonical ordering key is
  `run_at` in each `meta.json`. Discovery tools should scan `runs/*/meta.json`
  and may ignore the `latest` file (it is not a directory).
* A legacy flat `<dir>/cases/` directory (the pre-run layout) is still honored by
  the viewer for backward compatibility but is no longer written.

## 2. `meta.json` — schema `test_lens_run/v1`

Written when the run finalizes (the formatter's `:suite_finished`, with a
process-terminate backstop).

| field | type | notes |
|---|---|---|
| `schema` | string | always `"test_lens_run/v1"` |
| `run_id` | string | the run's stable id; matches the directory name |
| `run_at` | string | ISO-8601 UTC, e.g. `"2026-06-26T14:15:30.123456Z"` |
| `project` | string | the `project:` passed to `TestLens.start/1` |
| `git` | object | `{ "branch", "commit", "base_ref", "merge_base" }`; any field may be `null` |
| `case_count` | integer | number of case files written this run |
| `status_counts` | object | map of ExUnit status string → count, e.g. `{ "passed": 11, "failed": 1 }` |

Example:

```json
{
  "schema": "test_lens_run/v1",
  "run_id": "20260626T141530Z-7",
  "run_at": "2026-06-26T14:15:30.123456Z",
  "project": "havi",
  "git": {
    "branch": "feat/widget",
    "commit": "9f1c2d3e4b5a6978a0b1c2d3e4f5061728394a5b",
    "base_ref": "origin/main",
    "merge_base": "a1b2c3d4e5f6071829304a5b6c7d8e9f00112233"
  },
  "case_count": 12,
  "status_counts": { "passed": 11, "failed": 1 }
}
```

## 3. `run_id` and `run_at`

Captured once per run in `TestLens.Recorder.init/1`:

* `run_at = DateTime.utc_now() |> DateTime.to_iso8601()` — full-precision ISO-8601 UTC.
* `run_id = "<YYYYMMDDThhmmssZ>-<n>"` where the timestamp is `run_at` truncated to
  the second with `-`/`:` stripped (filesystem-safe), and `<n>` is a positive,
  strictly-increasing `System.unique_integer([:positive, :monotonic])` that
  guarantees uniqueness even for two runs in the same second.

`run_id` is roughly time-sortable, but **`run_at` is the canonical ordering key**
(two runs in the same second may not sort by `run_id` lexicographically).

## 4. Git context

Best-effort, captured once per run by shelling `git` in the project working dir
(`File.cwd!()` by default; override with the `git_dir:` option to
`TestLens.start/1`). Every probe is wrapped — a missing repo or `git` binary
yields `null` for that field and never breaks the suite.

| field | git command |
|---|---|
| `branch` | `git rev-parse --abbrev-ref HEAD` |
| `commit` | `git rev-parse HEAD` |
| `base_ref` | first of `origin/main`, `origin/master`, then `@{upstream}` that resolves locally; the **name** is recorded |
| `merge_base` | `git merge-base HEAD <base_ref>` |

**No network is performed during a run.** `merge_base` reflects only what the
local repo already knows; a caller wanting a fresh merge-base against the remote
should `git fetch` *before* the run.

## 5. Case files — schema `test_lens/v1.1`

One file per finished test at `<dir>/runs/<run_id>/cases/<slug>.json`. The schema
string is unchanged at `test_lens/v1.1`; the run-identity fields below are
**additive** within v1.1 (older readers ignore them).

New, self-describing fields on every case:

| field | type | notes |
|---|---|---|
| `run_id` | string | same value as the run's `meta.json` |
| `run_at` | string | same value as the run's `meta.json` |
| `git` | object | same shape as `meta.json`'s `git` |

Pre-existing fields are unchanged: `schema`, `project`, `module`, `name`, `file`,
`line`, `status`, `tags`, `duration_us`, `captures`, `db_events`. (`duration_us`
is elapsed test time, not wall-clock — wall-clock is `run_at`.)

## 6. Building the viewer

`TestLens.Viewer.build(opts)` returns `{:ok, out_path, case_count}` and resolves
`:dir` as:

* a **run directory** (directly contains `cases/`) → built as-is → `<dir>/index.html`;
* a **workspace root** (contains `runs/`) → builds its latest run (a legacy flat
  `<dir>/cases/` is merged in) → `<dir>/index.html`;
* `run: "<run_id>"` → builds that specific run under a workspace root.

`TestLens.Viewer.latest_run(dir)` returns the newest run directory (or `nil`),
preferring the `runs/latest` pointer and falling back to newest mtime.

## 7. Normalized run command

```
mix test_lens.run [--dir <out>] [extra `mix test` args...]
```

Runs the ExUnit suite (your `test/test_helper.exs` wiring — `TestLens.start/1` +
`TestLens.Formatter`), then builds the viewer for the run that was produced and
prints the `index.html` and `meta.json` paths. `--dir` defaults to
`test_lens_out` and must match the `dir:` given to `TestLens.start/1`; all other
arguments forward to `mix test`.
```

## 8. Run-vs-run diff command

```
mix test_lens.diff --base <run_dir> --head <run_dir> [--out <file.html>]
```

Compares two runs and writes a self-contained HTML diff plus a machine-readable
`diff.json`. Each `<run_dir>` is a `runs/<run_id>/` directory (the one holding
`meta.json` + `cases/`). The HTML is written to `--out` (default
`<head_run_dir>/diff.html`); a `diff.json` summary is always written next to it.
The absolute HTML path is printed on stdout and the command exits 0 on success.

Tests are matched across runs by identity (`module::name`, §5) and grouped:

| group | meaning |
|---|---|
| `added` | identity present in HEAD, absent from BASE |
| `removed` | identity present in BASE, absent from HEAD |
| `flipped` | present in both, **status changed** (e.g. `passed → failed`) |
| `changed` | present in both, **same status**, but the captured `captures` + `db_events` differ |
| `unchanged` | present in both, same status, same captured content (count only) |

A status flip takes precedence over a content change: a test whose status moved
is reported as a flip even if its captures also moved. Comparison ignores the
per-run `seq` ordering key and `duration_us` (both move every run); only the
captured input/action/result content is compared. Missing `meta.json` (rebuilt
from the cases), empty runs, identical runs, and a base with no `merge_base` are
all handled gracefully.

See `docs/diff-format.md` for the full `diff.json` schema (`test_lens_diff/v1`).
