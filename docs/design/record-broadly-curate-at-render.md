> ## Revision 3 — Author direction (2026-06-25): show the action; annotate only a real subject
>
> Two corrections after seeing the first real renders:
>
> 1. **The action was invisible.** A pure-data test (akg) carries no telemetry, so its ACTION channel rendered empty — "nothing captured here." Fix: a test is wrapped in three **block macros** — `TestLens.setup do … end`, `TestLens.action "desc" do … end`, `TestLens.verify do … end`. Each macro **copies its block's source text verbatim** into the matching channel (so the viewer shows *what the test does*) and then runs the block unchanged. Because the block is spliced inline, variables it binds stay in scope for later phases — no new scope, same compile behaviour the Rev-2 macro section already required. This supersedes both the binding-capture `phase` macro (§2b) and the zero-annotation float-up heuristic (§3/§4) as the way the channels get populated: the **copied source is the always-present signal**, captures/annotations are the refinement on top. `action` takes an optional one-line description rendered as a caption.
> 2. **A highlight is a claim — don't make a false one.** The first akg example annotated `predicate = requires`, but that test only verifies data round-trips from Dolt; no single field is "the answer." Rule: **annotate only the subject under test, and only when one genuinely exists.** Round-trip / "it persists" / pure-read tests annotate nothing and rely on the three source lanes. havi's endpoint test keeps its `data.workspace_id` pill because that value *is* what it asserts.
>
> Net: `setup`/`action`/`verify` source-copy blocks render the lanes for every test; `capture(..., annotate:)` spotlights the subject under test where there is one. Nothing is auto-decided.
>
> ---
>
> ## Revision 2 — Author direction (2026-06-24): agents write the tests
>
> The product critique assumed human authors who won't annotate, and pushed a zero-annotation auto-surface heuristic. The author corrected this: **tests are authored by agents**, so annotation effort and code volume are not constraints, and migration is incremental. Consequences:
>
> 1. **Explicit annotation is THE model. The zero-annotation float-up heuristic is removed.** Do not auto-decide what matters; a card's highlighted signal comes only from the agent's explicit `annotate`. Auto-*capture* (record everything per stage) stays; auto-*annotation* is dropped.
> 2. **The headline deliverable is documentation for agent usage.** The Test Lens library guide + a testing skill teaching `stage -> capture broadly -> annotate what matters` (with worked examples) is the primary artifact. The binding macro and telemetry auto-staging become optional conveniences, since code volume is not a concern.
>
> **Secrets — answer to "what do local tests expose anyway?": for these suites as actually run, essentially nothing real.** akg uses fake keys (`test-key-<n>`), stubs HTTP via `Req.Test`, and excludes live-API tests by default (`exclude: [:live_jina]`); the only env credentials are dev DB passwords (`doltpass`/`ash_kg_dev`). havi auth headers are test-session tokens for sandboxed users. **Redaction is a minor hygiene guard, not a blocker** — relevant only if a live-external-API test is instrumented AND its render is published. Removed from the critical path; keep simple header/struct redaction as a cheap safety net only.
>
> **Revised first slice:** annotation API + highlight rendering + the agent testing skill/docs, proven by migrating one akg and one havi test as worked examples. Broad auto-capture (macro/telemetry) follows.
>
> ---
>
# Test Lens: Record Broadly, Curate at Render

A unified design for "auto-capture everything per stage, annotate what matters, highlight on render" — covering both `havi` (Ecto/Phoenix endpoint tests) and `ash_knowledge_graph` (pure-data tests). Revised to fold in engineering and product critique.

---

## 1. The Core Inversion: Curate at Render, Not at Capture

Test Lens today asks the author to do the curation **at capture time**: every meaningful value is a hand-written `TestLens.capture(...)` call. The cost of that discipline is exactly why 509/515 akg cases and every HAVI case render as near-blank shells — nobody writes the calls.

The library's stated philosophy ("avoid full DB snapshots, too heavy/noisy") fuses two beliefs:

1. **Don't drown the signal in noise.** (Correct, keep it.)
2. **Therefore capture narrowly.** (This is the part to invert.)

The vision splits these apart:

> **Capture broadly. Curate narrowly. Move the curation from capture time to render time.**

The recorder records as much as each stage can cheaply yield. The **viewer** is where noise is suppressed: broad captures render **collapsed by default**, and the one or two things that matter are **floated to the top and highlighted**. "Not noisy" becomes a property of the *render*, not of the *recording*.

### The critique that reshaped this design

Two independent reviews agreed the inversion is the right strategy but flagged that the first draft re-bet on the exact author discipline that already failed, and shipped correctness bugs load-bearing for its own examples. The four changes that matter most:

1. **A zero-annotation card must already be useful.** The draft's payoff ("float up the one thing that matters") required a hand-written `annotate`. Realistically authors won't write it — same bet, same 509 blanks, now noisier. **The default render must auto-surface a useful line with zero curation** (the asserted value / response status / last binding). Annotation becomes polish on an already-readable card, never the thing that rescues a useless one.
2. **The akg `phase` macro must not introduce scope.** The draft wrapped the body in `if started?() do … else … end`; bindings made in `phase :setup` would be invisible to `phase :action`, so the flagship example would not compile. **Emit `stage` + body statements inline; gate nothing in a conditional** — rip-out-ability already comes free from the recorder's `alive?` guard.
3. **Broadening capture to headers/bodies/structs silently leaks secrets** with the current `do_redact`. Fix redaction *before* widening capture, not as an open question.
4. **One annotation idiom for v1.1.** Four idioms (`annotate:`, `annotate/2` by-label, `from:/to:`, `peek/2`) fragment usage and two of them produce confidently-wrong before/after readouts. Ship `capture(..., annotate:)` only; defer the rest.

### Why this still respects the additive / rip-out-able contract

- **Additive** — a test reads normally; TestLens lines only *add* information.
- **Rip-out-able** — delete the TestLens wiring and the test still compiles and asserts identically. Critically, the strip must be **mechanical** (a codemod), and a CI test proves it (see §5, Slice 0).
- **Opt-in** — an un-instrumented suite still produces a status-only catalog.

The design holds all three because broad auto-capture is telemetry/macro-driven (zero per-test code for HAVI; the akg macro degrades to a plain inline block via the recorder's existing `alive?` guard), annotation is a strictly optional extra arg, and render-time curation needs no schema authority (old viewers ignore the new optional `paths` field).

---

## 2. Chosen Auto-Capture Mechanisms — and Who Handles What

There is **no single broad-capture mechanism** that fits both targets, because the two carry their data in fundamentally different places:

| Target | Where the stage's data lives | Mechanism | Per-test code |
|---|---|---|---|
| **HAVI** (Ecto/Phoenix) | DB writes + the conn (HTTP req/resp) — observable via telemetry | **Stage-attributed telemetry** (Mechanism B) | **None** |
| **akg** (pure data) | Local variable bindings in the test pid — observable nowhere | **Compile-time binding-capture macro** (Mechanism A) | `phase do … end` wrap (opt-in) |

Two mechanisms were **rejected**: `:erlang.trace` (async-unsafe single global tracer mailbox; sees function boundaries not named bindings; heavy) and `:telemetry.execute` from akg's *production* modules (breaks rip-out by pushing capture into shipped code).

Both chosen mechanisms reuse the **exact same recorder plumbing**: the pid→key→acc bridge (`recorder.ex:160`), the per-test mutable `stage` string, the `{:capture, …}`/`{:db_event, …}` casts, and `JSON.sanitize`. The plumbing changes required are small and listed in §5; the capture *paths* themselves need no recorder rewrite.

### 2a. HAVI: Stage-Attributed Telemetry (Mechanism B)

The plumbing is already async-safe — the **only** gap is that `acc.stage` never advances (no HAVI test calls `TestLens.stage`), so every DB write inherits `"setup"` and is phase-blind. The fix makes the stage advance **automatically off the Phoenix lifecycle**, with no per-test code:

- Attach `[:phoenix, :endpoint, :start]` → `Recorder.put_stage(self(), :action)`. Writes **before** render as seed/`setup` (the `sign_in_user` / scenario INSERTs → **INPUT**); writes during/after are the action's own mutation.
- Keep `[:phoenix, :endpoint, :stop]` forcing the response to `:verify`.
- **Widen the conn read** in `do_record`: add `conn.req_headers` and `conn.body_params` — **but only after the redaction fix in §2c**, which the draft got wrong.

**Correctness assumptions made explicit (per critique):**

- *Single-test-pid ordering.* `put_stage` is a fire-and-forget cast and so are the Ecto query casts, but both originate from the **same test pid** under synchronous `ConnTest` dispatch, so mailbox order is preserved and the stage flip lands before the action's writes. This assumption is stated, not assumed silently.
- *Multiple requests per test.* A test that issues a login request *and then* the action request would flip to `:action` on the login `:start`, mis-tagging. **Resolution:** the `:start` handler flips to `:action` **only on the first start per test** (track a per-key `stage_locked?` flag), so subsequent requests don't re-flip backward. A test asserting two HTTP calls in one body is part of Slice 1's test set.
- *Off-pid Ecto under async sandbox.* See §2d — this is no longer waved off as "safe, lossy."

Ecto stays deliberately narrow (INSERT/UPDATE/DELETE SQL + params, no row snapshots). Correct *phase attribution* is what makes those events legible.

### 2b. akg: Compile-Time Binding-Capture Macro (Mechanism A) — opt-in, no new scope

For pure functions the only carrier of "data generated in this stage" is the **local bindings**. The macro:

1. Calls `TestLens.stage(name)` at block entry.
2. Walks the block's **top-level statements**; for each binding `pat = expr`, emits the original assignment unchanged, then appends a `TestLens.capture("<var>", var)` for each variable the pattern introduces.

**Two corrections from the draft:**

- **No `if/else` wrapper.** The draft introduced a new scope that hid bindings across phases — the §3 example would not compile. The macro now emits the stage call and the (possibly capture-interleaved) statements **inline**. Rip-out-ability comes for free: `TestLens.stage/1` and `TestLens.capture/3` both route through `cast/1`, which is already a no-op when the recorder is down (`recorder.ex:41-42`). No conditional needed.
- **Hygiene gate fixed.** `pattern_vars` must accept variables whose context is a non-nil/non-atom hygiene marker (vars introduced by upstream macros). The gate keys off "is this a var node with an atom name that isn't pinned/underscored," not off the context shape.

```elixir
defmacro phase(name, do: block) do
  rewritten =
    block
    |> unwrap_block()
    |> Enum.flat_map(fn
      {:=, _, [pat, _rhs]} = assign ->
        captures =
          for {vname, vctx} <- pattern_vars(pat) do
            var = {vname, [], vctx}
            quote do: TestLens.capture(unquote(to_string(vname)), unquote(var))
          end
        [assign | captures]
      other ->
        [other]
    end)

  # NO if/else, NO new scope: emit stage + body inline.
  # `stage/1` and `capture/3` are already no-ops when the recorder is down.
  {:__block__, [], [quote(do: TestLens.stage(unquote(name))) | rewritten]}
end

defp pattern_vars(pat) do
  {_, acc} =
    Macro.prewalk(pat, [], fn
      {:^, _, _} = pin, acc -> {pin, acc}                  # skip pinned matches
      {name, _, ctx} = node, acc
          when is_atom(name) and name != :_ and not underscored?(name) ->
        {node, [{name, ctx} | acc]}                        # keep ctx as-is (hygiene-correct)
      node, acc -> {node, acc}
    end)
  acc |> Enum.uniq() |> Enum.reverse()
end
```

**Scope of capture:** every top-level named binding — `x = …`, `{:ok, y} = …`, `%S{f: z} = …`. **Not captured:** intermediate/anonymous values and bindings nested inside `if/case/for/with/fn`. The critique's open question — *what about `with`/`case`-bound results?* — is **decided before rollout, not deferred**: top-level only for v1, and the macro is only worth shipping where it captures something useful. The macro is therefore validated against a **corpus of real akg test bodies** (compile + run + assert the capture set) before any rollout; if a suite's meaningful binds are all inside `with`, authors lift the binding out or keep explicit `capture` calls there. `phase` is **opt-in and never the documented default** (see §1 / product critique).

**Do not roll the macro out to HAVI** — telemetry covers that path and HAVI tests have no meaningful local bindings. Nothing enforces this except docs, so the "which mechanism do I use?" decision rule (§5, Slice 0) ships before the macro.

### 2c. Redaction must be fixed before capture widens (was an open question; now a blocker)

The draft said headers go "through the existing `@redact` regex." They don't. Verified against `phoenix.ex`:

- `conn.req_headers` is `[{"authorization", "Bearer …"}, …]`. `do_redact/1` only special-cases maps and non-struct lists; a `{"authorization", …}` **tuple falls through `do_redact(other) -> other` untouched**, then `JSON.sanitize` turns it into a 2-element list **with the bearer token in cleartext**. The exact token the design calls "the biggest blind spot" would be written to disk unredacted.
- `do_redact(map) when is_map(map) and not is_struct(map)` **does not descend into structs**. Once we capture bodies/bindings (which are often structs — `%Conn{}` assigns, Ecto schemas with an `api_key` column), a struct field holding a secret is passed through untouched and then sanitized to a cleartext map.

**Fix (Slice 1 prerequisite):**

- Convert `req_headers` to a map (`Map.new/1`) before redaction, and add an explicit tuple clause to `do_redact`.
- Make redaction **run after `JSON.sanitize`** (which already turns every struct into a plain map and every tuple into a list), so the regex sees every key including struct fields — closing both holes at once.
- Tests assert the written JSON contains `"[redacted]"` (not the token) for: an `authorization` **header**, a struct field named `:api_key`, and a `secret`-keyed body field.
- **Body PII ownership is named, not deferred:** `@redact` covers credentials but not workspace IDs / arbitrary PII. The redaction allowlist is owned by the HAVI rig's test-support module (it knows its own PII shape); the library ships the credential regex as the floor and exposes a hook to extend it. This is a precondition of widening to bodies, not Slice 5 polish.

### 2d. Off-pid capture must be observable, not silently dropped

`update_acc` (`recorder.ex:160-167`) drops any cast whose pid isn't a registered test key. Under "capture everything," authors will reasonably expect captures from `Task.async`, spawned helpers, or Ecto sandbox allowances (DB work under `$callers` in a non-test pid) to appear; they'll silently vanish, producing cards that **look** instrumented but aren't — the exact "auto-captured-but-wrong" failure, worse than an honest blank.

**Resolution (ships with broad capture, not after):** make the drop **visible**. `update_acc` increments a per-test `dropped_off_pid` counter when it can't resolve a pid; the viewer renders an "N captures dropped (off-pid)" badge on the card. Optionally (stretch) resolve the pid via the `$callers` chain the way `Ecto.Sandbox.allow` does. Broad capture does **not** ship while losses are silent.

---

## 3. Author-Facing API

All additive. All optional. Omit every token and the tests read and assert exactly as today.

### Stage / phase

- `TestLens.stage(:action)` — existing, unchanged.
- `phase :action do … end` — **new, opt-in** (Mechanism A); flips stage and auto-captures top-level bindings; emits inline (no new scope), no-ops when TestLens is off.
- HAVI authors write **neither** — telemetry drives stages.

### Annotation — ONE idiom for v1.1 (the curation signal)

Cut from four idioms to one, per critique. Only `capture(..., annotate:)` ships in v1.1:

```elixir
TestLens.capture("ranks", ranks_high, annotate: [["B", :score]])
```

`annotate:` takes a list of paths; each path is a list of keys/indices resolved against the **sanitized** tree (atoms→strings, tuples→lists, `__struct__`-tagged, depth-capped). `capture/3` gains only `opts[:annotate]`; `Recorder`'s `{:capture, …}` cast grows a `paths` field threaded onto the entry. Schema bumps to `test_lens/v1.1`; entry becomes `{stage, label, kind, value, seq, paths?}`. The hardcoded `schema: "test_lens/v1"` in `write_case` is updated, and the **new viewer also tolerates old v1 files with no `paths`** (forward- *and* backward-compatible).

**Deferred to a later version, with their blocking reason:**

- `TestLens.annotate/2` by-label and before/after-by-label pairing — deferred until **label collisions** are resolved (two same-named captures, or a fixed `"response"` label hit twice, silently mis-attach). When it does ship, it targets by **seq or an explicit handle**, not a fuzzy label, and **fails loud in test** when its target isn't found in the same test.
- `peek/2` inline sugar — deferred until the **real-term vs sanitized-tree path divergence** is reconciled (a `peek` path walks the live term; an `annotate` path walks the sanitized tree; they can resolve differently for the same struct).

### The zero-annotation card is the primary UX (new, from product critique)

A capture with **no** `annotate` must still surface signal automatically, so authors get value with zero curation. Heuristic float-up, in priority order:

1. The asserted value when the stage is `verify` (the last bound scalar in a `verify` phase, e.g. akg's `b_high`).
2. For HAVI, the **response status line** (`201 Created`) plus the top-level keys of the response body.
3. Otherwise, the last top-level binding of the latest stage.

Author annotation only *refines* which line floats — it never decides whether the card is useful.

### BEFORE / AFTER — akg pure-data test

`graph_importance_test.exs:523` — "raising A→B weight strictly increases B's PageRank score".

**Before (renders blank — no DB, no telemetry, no captures):**
```elixir
test "raising A->B weight strictly increases B's PageRank score" do
  low  = weight_bump_projection(0.1)
  high = weight_bump_projection(10.0)
  {:ok, ranks_low}  = GraphImportance.rank(low, :pagerank)
  {:ok, ranks_high} = GraphImportance.rank(high, :pagerank)
  b_low  = Enum.find(ranks_low, &(&1.id == "B")).score
  b_high = Enum.find(ranks_high, &(&1.id == "B")).score
  assert b_high > b_low
end
```

**After (auto-captures both projections, both ranked lists, both scalars; `b_high` floats up with zero annotation):**
```elixir
test "raising A->B weight strictly increases B's PageRank score" do
  phase :setup do
    low  = weight_bump_projection(0.1)
    high = weight_bump_projection(10.0)
  end

  phase :action do
    {:ok, ranks_low}  = GraphImportance.rank(low, :pagerank)
    {:ok, ranks_high} = GraphImportance.rank(high, :pagerank)
  end

  phase :verify do
    b_low  = Enum.find(ranks_low, &(&1.id == "B")).score
    b_high = Enum.find(ranks_high, &(&1.id == "B")).score
    assert b_high > b_low
  end
end
```

`low`/`high`/`ranks_low`/`ranks_high`/`b_low`/`b_high` are **shared across phases** — this compiles precisely because the macro introduces **no new scope** (the draft's `if/else` would have broken it). The assertion is byte-for-byte unchanged. With the zero-annotation heuristic, `b_high` (last `verify` scalar) floats up automatically; no `annotate` line is required.

### BEFORE / AFTER — HAVI endpoint test

`HaviWeb.AnnotationControllerTest` — "POST /api/annotations". **No body changes at all** — telemetry does the work:

```elixir
test "POST /api/annotations creates an annotation", %{conn: conn} do
  conn = sign_in_user(conn)                       # seed INSERTs -> now correctly tagged setup/INPUT
  body = %{annotation: w3c_annotation_fixture()}
  conn = post(conn, ~p"/api/annotations", body)   # request -> action, response -> verify
  assert %{"data" => %{"creator" => creator}} = json_response(conn, 201)
  assert creator == "alice"
end
```

The author adds **nothing**. After Slice 1 the `sign_in_user` INSERTs render as INPUT/seed, the annotation INSERT renders as the ACTION mutation, redacted headers (bearer token, `x-havi-workspace-id`) appear alongside the body, and the zero-annotation heuristic floats up `201 Created` + the response body's top-level keys.

---

## 4. The Rendering Model

The viewer keeps rendering **100% of what was captured** — curation is purely visual. Stages remain three channels: `setup`→INPUT (cyan), `action`→ACTION (violet), `verify`→RESULT (pink); unknown stages append as generic channels.

### Default view (collapsed) + zero-annotation float-up

- Every capture's full sanitized JSON tree renders **collapsed behind a disclosure** — `jsonHtml` (`viewer.ex:451`) gains a `collapsed` mode; `itemHtml` (`viewer.ex:528`) gains a disclosure wrapper. Collapsing-by-default *reduces* initial DOM versus today's fully-expanded JSON.
- The **zero-annotation heuristic** (§3) floats one useful line to the top of each channel even with no author input. This is the change that prevents "a wall of collapsed disclosures with no signal," the steady state the product critique warned about.

### Annotations float up and highlight (when present)

For each capture carrying `paths`, the annotated path is **extracted and floated** above the heuristic line as a compact glowing readout using the existing `--gold` accent — e.g. `data.creator = "alice"` — with the raw capture collapsed one click below. A shared `highlightPaths(value, paths)` helper wraps matched keys in a `.hl` span inside `jsonHtml` when expanded. A path that matches nothing renders a visible "annotation matched no value" marker rather than silently disappearing (answers open Q1).

### Changed fields and DB deltas

`deltaHtml` (`viewer.ex:511`) keeps `+`/`~`/`-` (green/amber/red); an annotated column inside an UPDATE/INSERT gets the gold highlight. Row-level before/after for a column the params don't carry stays out of scope (the deliberate no-heavy-snapshot boundary). Explicit `from:/to:` change readouts are deferred with `annotate/2` (§3).

### Scale affordances (from product critique)

- A **tray-level "instrumented vs status-only" affordance** so a collapsed-broad-capture card cannot masquerade as signal at a glance — you can still tell which tests carry data.
- A per-card **"annotated" badge** so highlighted-signal tests are findable in a ~515-card tray.
- The off-pid **"N captures dropped" badge** (§2d).
- All curation is **client-side, computed only for the selected specimen**, so thousands of cards stay fast. This is **load-tested against the real ~515-case akg output (expanded and collapsed)** before Slice 3 is called done — the draft asserted scale without demonstrating it.

---

## 5. Risks & Mitigations

| # | Risk | Sev | Mitigation | Lands in |
|---|------|-----|------------|----------|
| R1 | `phase` `if/else` wrapper introduces scope → shared bindings across phases don't compile (breaks the flagship example) | High | Emit `stage` + body **inline**, no conditional; rely on recorder `alive?` no-op for rip-out. Prove with a compiled test sharing bindings across three phases. | Slice 4 |
| R2 | Header redaction silently fails — `{"authorization", …}` tuple passes through, bearer token written cleartext | High | `Map.new` headers + tuple clause in `do_redact`; **run redaction after `JSON.sanitize`**. Test asserts `[redacted]`. | Slice 1 |
| R3 | `do_redact` doesn't descend into structs → struct fields with secret keys leak once bodies/bindings captured | High | Redact after sanitize (structs already flattened to maps). Test with `:api_key` struct field. | Slice 1 |
| R4 | Off-pid captures silently dropped by `update_acc` → cards look instrumented but aren't | High | Count drops per test; render "N captures dropped (off-pid)" badge. Optional `$callers` resolution. Don't ship broad capture while silent. | Slice 2/3 |
| R5 | Authors won't annotate (same bet that produced 509 blanks) → walls of collapsed disclosures | High | Zero-annotation heuristic float-up is the **primary** UX; annotation is polish only. | Slice 3 |
| R6 | `phase` erodes mechanical rip-out (core adoption promise) | High | `phase` opt-in, never the akg default; CI codemod-strips ALL tokens incl. `phase` and proves suite still compiles + passes. | Slice 0 |
| R7 | Capture/transport/storage blowup at 515 tests (full projections + bodies copied into one Recorder heap) | Med | Breadth/total-size cap in `JSON.sanitize` (truncate large lists/maps with elision, not just depth); per-test budget; sanitize on test pid before cast. Measure heap + file sizes on full suite. | Slice 2 |
| R8 | Stage-from-`endpoint:start` mis-tags multi-request tests (login + action) | Med | Flip to `:action` only on **first** start per test (`stage_locked?`); state single-pid ordering assumption; test with two HTTP calls. | Slice 1 |
| R9 | Macro mis-handles real bodies (macro-introduced var contexts, `with`/`case` binds, map-update syntax) | Med | Fix hygiene gate to keep non-nil ctx; decide top-level-only **before** rollout; corpus golden-test (compile+run) across real akg suites. | Slice 4 |
| R10 | Label-based annotation pairing mis-attaches (repeated/`"response"` labels) | Med | Ship **one** idiom (`annotate:`) for v1.1; defer `annotate/2`/`peek/2` until target-by-seq + fail-loud-on-miss. | Slice 2 |
| R11 | Docs absent — two mechanisms, HAVI/akg split, open questions = harder to teach than today's single `capture/3` | High | Docs are a per-slice deliverable; "which mechanism + one-annotation-is-enough" guide ships **before** the macro. | Slice 0 + every slice |
| R12 | Assumed API seams (`started?/0`) don't exist | Low | Audited: no `started?/0` needed (macro uses inline no-op casts); `schema` string + new `paths` field are the only recorder surface changes. | Slice 0 |

---

## 6. Recommended First Slice

**Ship Slice 1 — HAVI stage-attributed telemetry (with the redaction fix) — as the single PR that proves the approach end to end.**

### Why this one, not the akg macro

The draft floated the akg binding-capture macro as the likely first slice. The critique inverts that call, and the evidence agrees:

- **Highest signal per line of risk.** Slice 1 is **zero per-test code**: it turns *every existing HAVI case* from stage-blind into correct seed-vs-mutation and surfaces the auth/workspace headers that drive most endpoint behavior — the single biggest current blind spot — without touching a single test file or the schema or the viewer.
- **It proves the core inversion immediately.** "Record broadly (DB writes + conn already flow through telemetry), curate at render (correct phase attribution makes them legible)" is demonstrated end to end with the plumbing that already exists. The only new behavior is the stage flip and the conn widening.
- **The macro is the riskiest slice, not the safest.** It carries R1 (scope/compile), R6 (rip-out erosion), R9 (macro robustness across real bodies) and depends on Slices 2–3 (annotation + render-collapse) to be *usable* at all — a large fixture with no collapse is worse than a blank. Leading with it front-loads the design's three highest-uncertainty risks and can't even show value until the render work lands.
- **Slice 1 forces the redaction fix early**, which is a precondition for *everything* that widens capture. Doing it first means R2/R3 are closed before any broad capture exists, rather than retrofitted.

### What the single PR contains

1. `do_record` attaches `[:phoenix, :endpoint, :start]` → `put_stage(self(), :action)`, flipping **only on the first start per test** (`stage_locked?` on the acc).
2. Conn read widened to `req_headers` (as a map) and `body_params`.
3. **Redaction fix shipped in the same PR** (precondition, not follow-up): headers→map + tuple clause, and redaction reordered to run **after `JSON.sanitize`** so struct fields and header tuples are covered.
4. Tests (scenarigo per project convention): a `setup` INSERT renders under INPUT and the action INSERT under ACTION; the `authorization` header value is `[redacted]` in the written JSON; a two-HTTP-call test doesn't re-flip the stage backward.
5. A README section documenting the HAVI mechanism and the "authors write nothing here" rule — docs as a per-slice deliverable (R11).

No schema change, no viewer change, no test-author edits. It is independently shippable, independently valuable, and proves the inversion on the larger of the two suites the day it merges.

### The rest of the plan (unchanged in spirit, resequenced for safety)

- **Slice 0 — Foundations:** the rip-out codemod + CI strip test (R6), and the "which mechanism / one-annotation-is-enough" docs scaffold (R11). Small, gates the macro.
- **Slice 2 — Annotation capture layer:** `opts[:annotate]` → `paths` field; schema → `test_lens/v1.1` (back/forward compatible); `JSON.sanitize` breadth cap (R7); off-pid drop counter (R4).
- **Slice 3 — Render layer:** collapsed-by-default; **zero-annotation float-up (R5, the slice that makes broad capture usable)**; path highlight + "matched nothing" marker; tray instrumented/annotated/dropped badges; load-test at 515 cases.
- **Slice 4 — akg `phase` macro:** inline (no scope), hygiene-correct, top-level-only, corpus golden-tested (R1/R9); opt-in only; rolled out after Slices 0/2/3 so fixtures auto-collapse and the asserted scalar floats up.
- **Slice 5 — Polish:** deferred annotation idioms (`annotate/2` by seq, `peek/2`) once label-collision and path-divergence are resolved; richer extra-stage taxonomy.
