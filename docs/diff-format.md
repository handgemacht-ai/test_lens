# Test Lens diff — command + `diff.json` schema

`mix test_lens.diff` compares two Test Lens runs and emits two artifacts: a
self-contained `diff.html` (for humans) and a `diff.json` (for tools). This
documents both, and the `diff.json` schema downstream code reads. The on-disk
run/case format it consumes is in [`SPEC.md`](../SPEC.md).

## Command

```
mix test_lens.diff --base <run_dir> --head <run_dir> [--out <file.html>]
```

| flag | required | meaning |
|---|---|---|
| `--base` | yes | BASE run directory — a `runs/<run_id>/` folder (has `meta.json` + `cases/`) |
| `--head` | yes | HEAD run directory, same shape |
| `--out` | no | HTML output path; defaults to `<head_run_dir>/diff.html` |

Behaviour:

* Writes the self-contained HTML to `--out`.
* Always writes `diff.json` **next to the HTML** (same directory).
* Prints the absolute HTML path on stdout (last line) and exits `0` on success.
* Fails fast only on a genuine misconfiguration: a missing `--base`/`--head`, or
  a path that is not a directory. Missing `meta.json`, empty runs, identical
  runs, and a base with no `merge_base` are all handled gracefully.

The same computation is available as a library: `TestLens.Diff.compute/2`,
`TestLens.Diff.summary/1`, and `TestLens.Diff.build/1`.

## Matching & classification

Tests are matched across runs by their stable **identity**: `module + "::" +
name` (see `SPEC.md` §5). Each matched/unmatched test lands in exactly one group:

* **added** — identity in HEAD only.
* **removed** — identity in BASE only.
* **flipped** — identity in both, **status changed** (any status string change,
  e.g. `passed → failed`, `failed → passed`, `passed → skipped`).
* **changed** — identity in both, **same status**, but the captured content
  (`captures` + `db_events`) differs.
* **unchanged** — identity in both, same status, same captured content.

A status flip wins over a content change: if both the status and the captures
moved, the test is a **flip**, not a **changed**.

Content comparison drops the volatile per-run fields before comparing: the
global `seq` ordering key (so a test that merely shifted position compares equal)
and `duration_us` (which moves every run). Only the captured input → action →
result is compared.

## `diff.json` schema — `test_lens_diff/v1`

Top level:

| field | type | notes |
|---|---|---|
| `schema` | string | always `"test_lens_diff/v1"` |
| `generated_at` | string | ISO-8601 UTC, when the diff was computed |
| `base` | object | BASE run summary (below) |
| `head` | object | HEAD run summary (below) |
| `counts` | object | the headline numbers (below) |
| `added` | array | case refs present in HEAD only |
| `removed` | array | case refs present in BASE only |
| `flipped` | array | flip refs (base/head status) |
| `changed` | array | changed refs (with a content summary) |

`unchanged` tests are intentionally a **count only** (in `counts`); they are not
listed, since they did not change.

### Run summary (`base` / `head`)

Mirrors the run's `meta.json` (`SPEC.md` §2) plus the absolute run directory:

```json
{
  "run_id": "20260626T141530Z-7",
  "run_at": "2026-06-26T14:15:30.123456Z",
  "project": "havi",
  "case_count": 12,
  "status_counts": { "passed": 11, "failed": 1 },
  "git": { "branch": "...", "commit": "...", "base_ref": "...", "merge_base": "..." },
  "dir": "/abs/path/to/runs/20260626T141530Z-7"
}
```

Any field may be `null` (e.g. `git.merge_base` for a base with no merge-base, or
all of `git` outside a repo). When the run had no `meta.json`, these fields are
reconstructed from the cases (each case carries `run_id`/`run_at`/`git`/`project`).

### `counts`

```json
{
  "added": 1, "removed": 1, "flipped": 1, "changed": 0, "unchanged": 9,
  "base_total": 11, "head_total": 11
}
```

`base_total` / `head_total` are the number of distinct test identities in each
run.

### `added` / `removed` entries (case ref)

```json
{ "id": "MyApp.WidgetTest::renders a widget",
  "module": "MyApp.WidgetTest", "name": "renders a widget",
  "status": "passed", "file": "test/widget_test.exs", "line": 12 }
```

### `flipped` entries

```json
{ "id": "MyApp.AuthTest::rejects a bad token",
  "module": "MyApp.AuthTest", "name": "rejects a bad token",
  "base_status": "passed", "head_status": "failed",
  "file": "test/auth_test.exs", "line": 40 }
```

### `changed` entries

```json
{ "id": "MyApp.ApiTest::returns the user",
  "module": "MyApp.ApiTest", "name": "returns the user",
  "status": "passed",
  "summary": {
    "captures":  { "base": 3, "head": 4 },
    "db_events": { "base": 1, "head": 1 },
    "capture_changes": ["- action/response", "+ action/response", "+ verify/audit"]
  } }
```

`summary.capture_changes` is the multiset symmetric difference of the two
captures lists, each item described as `"<sign> <stage>/<label>"` — `-` for a
capture only in BASE, `+` for one only in HEAD. A value change for the same
capture shows up as a removed + added pair for the same `<stage>/<label>`. The
`captures`/`db_events` sub-objects give the per-side counts.

## Stability

`diff.json`'s `schema` string and field names are a stable contract for
downstream tooling (e.g. the Go admin panel that surfaces a diff summary without
parsing HTML). New fields may be added within `test_lens_diff/v1`; existing
fields are not renamed or removed without a version bump.
