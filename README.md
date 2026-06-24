# TestLens

Turn ExUnit tests into something you can *look at*.

A test already does three things — sets up an input, performs an action, and
checks a result — and then throws all of that away after the green checkmark.
TestLens captures that input → action → result and writes each test out as a
structured "case". A single viewer renders every case as a before/after,
without rewriting the test.

It works across very different test styles from **one** library:

- **function-call tests** — a call that returns `{:ok, _}` / `{:error, _}`
- **request/response tests** — an HTTP request that returns a response and
  writes rows to the database (the row changes are captured automatically)

## Install

Add it as a test-only dependency:

```elixir
def deps do
  [
    {:test_lens, github: "handgemacht-ai/test_lens", only: :test, runtime: false}
  ]
end
```

## Quick start

**1. Wire it up once** in `test/test_helper.exs`:

```elixir
TestLens.start(project: "my_app", dir: "test_lens_out")
ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])
```

**2. Capture in a test** — add `use TestLens.Case` and a few `capture` calls:

```elixir
defmodule MyApp.CreateBranchTest do
  use ExUnit.Case
  use TestLens.Case

  test "creates a branch" do
    TestLens.stage(:setup)
    TestLens.capture("candidate name", "feature_login")

    result = TestLens.action("create_branch/1", MyApp.create_branch("feature_login"))

    TestLens.output("returns", result)
    assert {:ok, %{created: true}} = result
  end
end
```

**3. Build the viewer** after the suite runs:

```elixir
TestLens.Viewer.build(dir: "test_lens_out")
# => writes test_lens_out/index.html — a single self-contained page
```

Open `test_lens_out/index.html`. Each test is one card: input → action →
result, with database changes shown inline on the stage that caused them.

## Annotate what matters

A capture records the *whole* value — the entire response body, the full result
map. That is deliberate: record broadly so nothing is lost. But a reader should
not have to hunt through a forty-field response to find the one field the test
is really about. So the author **annotates** the path(s) that matter, and the
viewer floats them as a gold `path = value` readout above the value and
highlights the matched key inside the expanded JSON.

```elixir
TestLens.capture("response", response.body,
  annotate: [["data", "creator"], ["meta", "version"]]
)
```

- Record everything; annotate only the field(s) under test.
- Each path is a list of keys (atoms or strings) and/or integer list indices,
  resolved against the captured value.
- If a path matches nothing — the shape drifted, or a key was renamed — the
  viewer shows a visible **"annotation matched no value"** marker instead of
  rendering nothing. A failed annotation is a signal, not a no-op.

Annotation is purely descriptive: it never changes what is recorded or whether
the test passes. It only changes what the viewer draws your eye to.

## Capturing database changes (optional)

For projects on a clean Ecto repo, attach the database-delta layer once in
`test/test_helper.exs`:

```elixir
TestLens.Ecto.attach([:my_app, :repo])
```

It listens to the repo's query telemetry and records mutations
(INSERT/UPDATE/DELETE) onto whichever test is running — no manual snapshots,
no per-test code. Reads are ignored to keep the signal clean.

## What a capture looks like

Each test becomes one JSON file (`test_lens_out/cases/*.json`) in a small,
stable format (`schema: "test_lens/v1.1"`): the test's identity and status, an
ordered list of `captures` (each with a stage, label, render `kind`, value, and
an optional `paths` list of annotations), and any `db_events`. Older
`test_lens/v1` files that carry no `paths` field still render. The viewer only knows this format — it knows
nothing about any specific project, so the same viewer renders every project.

## Writing a capture adapter (collect → transform → render)

Any external source — a message queue, a cache layer, a version-control
system, a billing event — can be surfaced in the viewer without touching the
TestLens core. The contract has three steps:

### 1. Collect

Call `TestLens.capture/3` with a `kind:` option set to your source's kind
string. The recorder accepts any kind string — no core change required:

```elixir
TestLens.capture("dolt commit", op_map, kind: :dolt_op)
```

Or call `TestLens.Recorder.add_capture/5` directly when you have the pid but
not the public helper (e.g. from a telemetry handler):

```elixir
TestLens.Recorder.add_capture(pid, label, "dolt_op", sanitized_value, nil)
```

### 2. Transform

Your `value` is whatever map or scalar makes the capture meaningful. Run it
through `TestLens.JSON.sanitize/1` to make all Elixir types JSON-encodable.
The capture is stored in `captures` (not `db_events`), so the DB-writes
counter in the viewer is unaffected.

### 3. Render

The viewer ships a `kindRenderers` JS registry (a plain object in `viewer.ex`)
that maps `kind -> fn(value) -> html`. If your kind is not registered, the
viewer falls back to a formatted JSON block — **so a new source needs zero
core edit** for basic visibility.

To add a styled renderer, add one entry to `kindRenderers`:

```js
my_kind: v => `<div class="my-widget">${esc(v.label)}</div>`
```

That one entry is the only change required for a bespoke visual.

### Example: `TestLens.Dolt`

`TestLens.Dolt` is the reference implementation of this contract. It captures
Dolt version-control operations (commit, branch, merge, diff) and renders them
as styled VC blocks — an action badge, the branch name, the short commit hash,
and the commit message. See `lib/test_lens/dolt.ex` for the full source and
step-by-step commentary.

```elixir
test "commits a schema migration" do
  TestLens.stage(:action)

  TestLens.Dolt.capture(self(), %{
    action: "commit",
    branch: "feature/add-index",
    commit_hash: "abc1234",
    message: "Add index on annotations.org_id"
  })
end
```

## Why

Code tests answer *"did it pass?"*. A rendered case answers *"is this the
behaviour I actually want?"* — and lets you eyeball dozens of cases in a
minute. If a test can't be drawn as input → action → result, that's usually a
sign it's asserting on implementation detail rather than behaviour.

## License

MIT — see [LICENSE](LICENSE).
