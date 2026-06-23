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
stable format (`schema: "test_lens/v1"`): the test's identity and status, an
ordered list of `captures` (each with a stage, label, render `kind`, and
value), and any `db_events`. The viewer only knows this format — it knows
nothing about any specific project, so the same viewer renders every project.

## Why

Code tests answer *"did it pass?"*. A rendered case answers *"is this the
behaviour I actually want?"* — and lets you eyeball dozens of cases in a
minute. If a test can't be drawn as input → action → result, that's usually a
sign it's asserting on implementation detail rather than behaviour.

## License

MIT — see [LICENSE](LICENSE).
