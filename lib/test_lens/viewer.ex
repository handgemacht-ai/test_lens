defmodule TestLens.Viewer do
  @moduledoc """
  Render captured cases into a single self-contained HTML file: a virtualized
  specimen tray on the left, and per test the input → action → result refraction
  on the right, with database deltas shown inline on the stage that caused them.

  Built to scan thousands of tests at once — only the visible tray rows live in
  the DOM, and the heavy flow renders for the selected specimen alone. Knows
  nothing about any project — only the case format (`schema: "test_lens/v1.1"`,
  and the older `test_lens/v1` files that carry no `paths` field).

      TestLens.Viewer.build(dir: "test_lens_out")
  """

  @doc """
  Build a single run's `index.html` from its `cases/*.json` and return
  `{:ok, out_path, case_count}`.

  `:dir` is resolved as follows (see `SPEC.md`):

    * a **run directory** (one that directly contains `cases/`) is built as-is,
      writing `<dir>/index.html`;
    * a **workspace root** (one that contains a `runs/` directory) builds its
      latest run — a legacy flat `<dir>/cases/` is still merged in for backward
      compatibility — writing `<dir>/index.html`;
    * pass `run: "<run_id>"` to build a specific run under a workspace root.

      TestLens.Viewer.build(dir: "test_lens_out")
      TestLens.Viewer.build(dir: "test_lens_out", run: "20260626T141530Z-7")
      TestLens.Viewer.build(dir: "test_lens_out/runs/20260626T141530Z-7")
  """
  def build(opts \\ []) do
    dir = opts[:dir] || "test_lens_out"
    out = opts[:out] || default_out(dir, opts)

    {cases, skipped} = load_cases(dir, opts)

    json = cases |> Jason.encode!() |> String.replace("</", "<\\/")

    # Substitute every static/scalar placeholder FIRST and inject the recorded
    # JSON payload LAST: once the data is in the document nothing scans back over
    # it, so recorded content that happens to contain a placeholder literal is
    # never corrupted.
    html =
      template()
      |> String.replace("__SHARED_CSS__", TestLens.Assets.css())
      |> String.replace("__SHARED_JS__", TestLens.Assets.js())
      |> String.replace("__HLJS__", TestLens.Assets.hljs())
      |> String.replace("__RUN_SUMMARY__", TestLens.Charts.run_summary(cases))
      |> String.replace("__DURATION_CHART__", TestLens.Charts.durations(cases))
      |> String.replace("__MODULE_CHART__", TestLens.Charts.modules(cases))
      |> String.replace("__SKIPPED__", Integer.to_string(skipped))
      |> String.replace("__CASES_JSON__", json)

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, html)
    {:ok, out, length(cases)}
  end

  @doc """
  Directory of the most recent run under `dir` (`<dir>/runs/<run_id>`), or `nil`
  when there are none. Prefers the `<dir>/runs/latest` pointer, falling back to
  the newest run directory by mtime. Useful for tools that discover runs.
  """
  def latest_run(dir \\ "test_lens_out") do
    runs = Path.join(dir, "runs")
    pointer = Path.join(runs, "latest")

    from_pointer =
      if File.regular?(pointer) do
        candidate = Path.join(runs, pointer |> File.read!() |> String.trim())
        if File.dir?(candidate), do: candidate
      end

    from_pointer || newest_run(runs)
  end

  defp newest_run(runs) do
    runs
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&run_mtime/1, :desc)
    |> List.first()
  end

  defp run_mtime(dir) do
    case File.stat(dir) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  # Read every case file for this build leniently, de-duplicate by stable test
  # identity, and report how many files could not be read. Returns
  # `{cases, skipped_count}`.
  defp load_cases(dir, opts) do
    {run_paths, legacy_paths} = case_sources(dir, opts)

    {run_cases, run_skipped} = read_cases(run_paths)
    {legacy_cases, legacy_skipped} = read_cases(legacy_paths)

    {dedupe(run_cases ++ legacy_cases) |> Enum.map(&lift_status/1), run_skipped + legacy_skipped}
  end

  # Lift the on-disk status string to `TestLens.Status.t()` once at the read
  # boundary, so the render path (charts, the embedded JSON) carries the typed
  # enum instead of re-deriving it downstream. The on-disk JSON itself is
  # unchanged; `Jason` encodes the atom back to the same string.
  defp lift_status(%{"status" => s} = c), do: %{c | "status" => TestLens.Status.from_string(s)}
  defp lift_status(c), do: c

  # The two case sources for this build, as `{run_paths, legacy_paths}` (see
  # `SPEC.md` §6). Legacy flat cases are only merged for a workspace-root build.
  defp case_sources(dir, opts) do
    cond do
      run = opts[:run] ->
        {glob_cases(Path.join([dir, "runs", run])), []}

      File.dir?(Path.join(dir, "runs")) ->
        latest = latest_run(dir)
        run_paths = if latest, do: glob_cases(latest), else: []
        {run_paths, glob_cases(dir)}

      true ->
        {glob_cases(dir), []}
    end
  end

  # Lenient read: a corrupt, half-written, or non-object case file is skipped and
  # counted rather than crashing the whole build. Shares `TestLens.Diff`'s
  # reader so the viewer and the differ tolerate exactly the same files.
  defp read_cases(paths) do
    {cases, skipped} =
      paths
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn path, {acc, skipped} ->
        case TestLens.Diff.read_json(path) do
          c when is_map(c) -> {[c | acc], skipped}
          _ -> {acc, skipped + 1}
        end
      end)

    {Enum.reverse(cases), skipped}
  end

  # De-duplicate by stable test identity, keeping the first occurrence — the run
  # cases precede the legacy flat ones, so the run's copy wins. Sorted by
  # identity so the built page is stable across runs.
  defp dedupe(cases) do
    cases
    |> Enum.reduce({[], MapSet.new()}, fn c, {acc, seen} ->
      id = TestLens.Diff.identity(c)
      if MapSet.member?(seen, id), do: {acc, seen}, else: {[c | acc], MapSet.put(seen, id)}
    end)
    |> elem(0)
    |> Enum.sort_by(&TestLens.Diff.identity/1)
  end

  defp glob_cases(run_or_dir), do: run_or_dir |> Path.join("cases/*.json") |> Path.wildcard()

  defp default_out(dir, opts) do
    if run = opts[:run] do
      Path.join([dir, "runs", run, "index.html"])
    else
      Path.join(dir, "index.html")
    end
  end

  defp template do
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Test Lens</title>
    <style>
      :root {
        --bg: #090b10; --bg-2: #0c0f16; --panel: #11151e; --panel-2: #161b27;
        --line: #222a38; --line-2: #2c3445; --text: #e9ecf3; --muted: #8a93a6;
        --faint: #5a6378;
        --gold: #f4b740;          /* the single UI accent: instrument readout */
        --pass: #45d49a; --fail: #fb6f78; --skip: #6b7488;
        --in: #41c9e3; --act: #a98bff; --out: #fb7faf;   /* refraction channels */
        --ins: #45d49a; --del: #fb6f78; --upd: #f4b740;  /* delta signs */
        --mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
        /* Offline by design: Space Grotesk if the reader has it, else a deliberate
           system stack. No web-font request — the page is fully self-contained. */
        --display: "Space Grotesk", "Avenir Next", "Segoe UI", system-ui, -apple-system, sans-serif;
        --row-h: 32px;
      }

      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 13.5px/1.55 var(--mono);
        -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
        display: grid; grid-template-rows: auto auto 1fr; grid-template-columns: minmax(0, 1fr); height: 100vh; overflow: hidden;
      }

      /* ---------- instrument header ---------- */
      .bar {
        display: flex; align-items: center; gap: 16px 26px; flex-wrap: wrap; min-width: 0;
        padding: 13px 22px; border-bottom: 1px solid var(--line);
        background: linear-gradient(180deg, #0d1019, var(--bg));
      }
      .brand { display: flex; align-items: center; gap: 11px; flex: none; }
      .mark {
        width: 22px; height: 22px; border-radius: 50%;
        background: conic-gradient(from 210deg, var(--in), var(--act), var(--out), var(--in));
        -webkit-mask: radial-gradient(circle 6.5px at 50% 50%, transparent 98%, #000 100%);
                mask: radial-gradient(circle 6.5px at 50% 50%, transparent 98%, #000 100%);
        filter: saturate(.85); flex: none;
      }
      .word { font: 600 16px/1 var(--display); letter-spacing: 3px; }
      .word i { color: var(--gold); font-style: normal; margin: 0 1px; }

      .readout { display: flex; align-items: center; gap: 16px; min-width: 0; flex-wrap: wrap; }
      .meter {
        width: 132px; height: 6px; border-radius: 999px;
        background: rgba(255,255,255,.06); overflow: hidden; flex: none;
        box-shadow: inset 0 0 0 1px var(--line);
      }
      .meter span { display: block; height: 100%; background: linear-gradient(90deg, var(--pass), #6ee7b7); }
      .nums { display: flex; align-items: baseline; gap: 7px; flex-wrap: wrap; }
      .nums .n { font: 600 14px/1 var(--display); letter-spacing: .3px; }
      .nums .n.pass { color: var(--pass); } .nums .n.fail { color: var(--fail); } .nums .n.skip { color: var(--skip); }
      .nums .nl { color: var(--faint); font-size: 11px; letter-spacing: .4px; margin-right: 4px; }
      .nums .sep { width: 1px; height: 13px; background: var(--line-2); margin: 0 4px; }
      .skipwarn { display: inline-flex; align-items: center; gap: 5px; color: var(--upd); font-size: 11px; letter-spacing: .3px; white-space: nowrap; }

      /* run-summary chart: the always-on, zero-JS status readout in the header */
      .run-chart { display: flex; align-items: center; flex: none; }

      /* ---------- overview: collapsible static-SVG dashboards (native <details>) ---------- */
      .overview { border-bottom: 1px solid var(--line); background: var(--bg-2); min-width: 0; }
      .overview > summary {
        list-style: none; cursor: pointer; user-select: none;
        display: flex; align-items: center; gap: 9px; padding: 9px 22px;
        color: var(--muted); font: 600 11px/1 var(--display); letter-spacing: 1px;
      }
      .overview > summary::-webkit-details-marker { display: none; }
      .overview > summary:hover { color: var(--text); }
      .ov-caret { color: var(--faint); display: inline-block; transition: transform .14s; }
      .overview[open] > summary .ov-caret { transform: rotate(90deg); }
      .overview[open] > summary { border-bottom: 1px solid var(--line); }
      .overview-body { padding: 16px 22px 20px; display: flex; flex-direction: column; gap: 20px; max-height: 46vh; overflow: auto; }
      .ov-panel { min-width: 0; overflow-x: auto; }
      .ov-h { font: 600 10px/1 var(--display); letter-spacing: 1.4px; color: var(--faint); margin-bottom: 9px; text-transform: uppercase; }

      /* ---------- bench ---------- */
      .bench { display: grid; grid-template-columns: 372px minmax(0, 1fr); min-height: 0; min-width: 0; }

      /* ---------- tray (left) ---------- */
      .tray { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--line); background: var(--bg-2); }
      .tools { padding: 12px 14px 10px; border-bottom: 1px solid var(--line); display: flex; flex-direction: column; gap: 9px; }
      .q {
        width: 100%; height: 34px; padding: 0 12px; border-radius: 8px;
        background: var(--panel); border: 1px solid var(--line); color: var(--text);
        font: 13px var(--mono); outline: none; transition: border-color .14s, box-shadow .14s;
      }
      .q::placeholder { color: var(--faint); }
      .q:focus { border-color: var(--gold); box-shadow: 0 0 0 3px rgba(244,183,64,.12); }

      .seg { display: flex; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
      .seg button {
        flex: 1; appearance: none; background: transparent; border: 0; cursor: pointer;
        color: var(--muted); font: 600 11.5px/1 var(--mono); letter-spacing: .3px;
        padding: 8px 4px; display: flex; align-items: center; justify-content: center; gap: 5px;
        border-right: 1px solid var(--line); transition: background .12s, color .12s;
      }
      .seg button:last-child { border-right: 0; }
      .seg button:hover { color: var(--text); }
      .seg button.on { background: rgba(244,183,64,.13); color: var(--gold); }
      .seg button .c { font-size: 10.5px; color: var(--faint); }
      .seg button.on .c { color: var(--gold); }

      .tools-row { display: flex; align-items: center; gap: 12px; justify-content: space-between; }
      .toggle { display: inline-flex; align-items: center; gap: 7px; cursor: pointer; color: var(--muted); font-size: 11.5px; letter-spacing: .2px; user-select: none; }
      .toggle input { appearance: none; width: 30px; height: 17px; border-radius: 999px; background: var(--panel-2); border: 1px solid var(--line); position: relative; cursor: pointer; transition: background .15s; flex: none; }
      .toggle input::after { content: ""; position: absolute; top: 1px; left: 1px; width: 13px; height: 13px; border-radius: 50%; background: var(--faint); transition: transform .15s, background .15s; }
      .toggle input:checked { background: rgba(244,183,64,.22); border-color: var(--gold); }
      .toggle input:checked::after { transform: translateX(13px); background: var(--gold); }
      .proj { background: var(--panel); border: 1px solid var(--line); color: var(--muted); border-radius: 7px; padding: 6px 8px; font: 11.5px var(--mono); outline: none; }

      .traycount { padding: 7px 16px; color: var(--faint); font-size: 11px; letter-spacing: .3px; border-bottom: 1px solid var(--line); flex: none; }
      .traycount b { color: var(--muted); font-weight: 600; }

      .scroller { position: relative; overflow: auto; flex: 1; min-height: 0; outline: none; }
      .scroller:focus-visible { box-shadow: inset 0 0 0 2px rgba(244,183,64,.4); }
      .sizer { position: relative; width: 100%; }
      .layer { position: absolute; top: 0; left: 0; right: 0; will-change: transform; }

      .row { height: var(--row-h); display: flex; align-items: center; width: 100%; padding: 0 14px 0 0; }
      .row.group {
        gap: 8px; cursor: pointer; color: var(--muted); background: var(--bg);
        border-top: 1px solid var(--line); border-bottom: 1px solid var(--line);
        padding-left: 10px; font-size: 12px;
      }
      .row.group:hover { color: var(--text); }
      .caret { color: var(--faint); transition: transform .12s; display: inline-block; width: 12px; text-align: center; }
      .caret.col { transform: rotate(-90deg); }
      .gm { font-weight: 600; letter-spacing: .2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; }
      .gtally { display: flex; gap: 9px; flex: none; font-size: 11px; }
      .gtally i { font-style: normal; }
      .gtally .t-ok { color: var(--faint); } .gtally .t-fail { color: var(--fail); } .gtally .t-skip { color: var(--skip); }

      .row.test {
        appearance: none; background: transparent; border: 0; text-align: left; cursor: pointer;
        gap: 9px; padding-left: 14px; color: var(--text); font: 12.5px var(--mono);
        border-left: 2px solid transparent; transition: background .1s;
      }
      .row.test:hover { background: rgba(255,255,255,.025); }
      .row.test.sel { background: rgba(244,183,64,.09); border-left-color: var(--gold); }
      .g { width: 3px; height: 15px; border-radius: 2px; flex: none; background: var(--faint); }
      .g.pass { background: var(--pass); } .g.fail { background: var(--fail); box-shadow: 0 0 7px rgba(251,111,120,.6); } .g.skip { background: var(--skip); }
      .rn { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .rn .rmod { color: var(--faint); }
      .rmeta { display: flex; align-items: center; gap: 8px; flex: none; color: var(--faint); font-size: 11px; }
      .sh { display: inline-flex; gap: 2px; }
      .sh i { width: 4px; height: 4px; border-radius: 50%; background: #2a3140; display: inline-block; }
      .sh i.in { background: var(--in); } .sh i.act { background: var(--act); } .sh i.out { background: var(--out); }
      .dur { font-variant-numeric: tabular-nums; }
      .dbt { color: var(--upd); background: rgba(244,183,64,.12); border-radius: 4px; padding: 1px 5px; font-size: 10px; }

      .nomatch { padding: 40px 20px; text-align: center; color: var(--faint); font-size: 12.5px; }

      /* ---------- stage view (right) ---------- */
      .stage-view { overflow: auto; min-height: 0; min-width: 0; background: var(--bg); }
      /* The spec is the query container: the phase columns react to *its* width,
         not the viewport's, so they lay out correctly inside the admin iframe. */
      .spec { padding: 24px 28px 60px; max-width: 1280px; margin: 0 auto; container: bench / inline-size; }
      @media (prefers-reduced-motion: no-preference) {
        .spec { animation: focusin .18s ease both; }
        @keyframes focusin { from { opacity: 0; transform: translateY(5px); filter: blur(1.5px); } to { opacity: 1; transform: none; filter: none; } }
      }

      .spec-head { display: flex; align-items: flex-start; gap: 13px; padding-bottom: 18px; border-bottom: 1px solid var(--line); }
      .g.big { height: 38px; width: 4px; }
      .spec-id { min-width: 0; flex: 1; }
      .spec-name { font: 600 18px/1.3 var(--display); letter-spacing: -.01em; word-break: break-word; }
      .spec-sub { color: var(--muted); font-size: 12px; margin-top: 5px; }
      .spec-sub .mono { color: var(--text); }
      .spec-sub .dim { color: var(--faint); }
      .spec-sub .st { text-transform: uppercase; letter-spacing: .6px; font-weight: 600; font-size: 11px; }
      .spec-sub .st.pass { color: var(--pass); } .spec-sub .st.fail { color: var(--fail); } .spec-sub .st.skip { color: var(--skip); }
      .spec-side { margin-left: auto; display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; max-width: 40%; }
      .tag { font-size: 10.5px; color: var(--muted); background: var(--panel-2); border: 1px solid var(--line); border-radius: 999px; padding: 3px 9px; white-space: nowrap; }
      .tag.proj { color: var(--gold); border-color: rgba(244,183,64,.3); }
      .spec-back { display: none; appearance: none; background: var(--panel); border: 1px solid var(--line); color: var(--text); border-radius: 8px; padding: 7px 12px; font: 600 12px var(--mono); cursor: pointer; margin-bottom: 16px; }

      /* the refraction beam: rings align over the channel columns below. Shown
         only when the columns are side by side (see the container query). */
      .beam { display: none; gap: 0; position: relative; margin: 22px 0 0; height: 30px;
        grid-template-columns: repeat(var(--cols, 3), minmax(0, 1fr)); }
      .beam::before { content: ""; position: absolute; left: 8%; right: 8%; top: 14px; height: 2px;
        background: linear-gradient(90deg, var(--in), var(--act), var(--out)); opacity: .55; border-radius: 2px; }
      .ap { display: flex; align-items: center; justify-content: center; position: relative; }
      .ring { width: 13px; height: 13px; border-radius: 50%; background: var(--bg); position: relative; z-index: 1; box-shadow: 0 0 0 2px currentColor, 0 0 12px currentColor; }
      .ap.in { color: var(--in); } .ap.act { color: var(--act); } .ap.out { color: var(--out); }

      /* Stacked full-width by default; balanced columns only when the spec is
         genuinely wide. Narrow (the iframe, mobile) never squeezes three columns. */
      .axis { display: grid; gap: 14px; margin-top: 14px; align-items: start; grid-template-columns: minmax(0, 1fr); }
      @container bench (min-width: 1100px) {
        .beam { display: grid; }
        .axis { margin-top: 6px; grid-template-columns: repeat(var(--cols, 3), minmax(0, 1fr)); }
      }
      /* Each channel is its own query container so a collapsed source row reacts
         to the *column* width (narrow in 3-up, wide when stacked). overflow is
         visible so the source peek popover is not clipped. */
      .chan { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); overflow: visible; min-width: 0; container: bench / inline-size; }
      .chan-h { display: flex; align-items: center; gap: 8px; padding: 11px 14px; font: 600 11px/1 var(--display); letter-spacing: 1.6px; border-bottom: 1px solid var(--line); }
      .chan.in .chan-h { color: var(--in); } .chan.act .chan-h { color: var(--act); } .chan.out .chan-h { color: var(--out); }
      .chan-h .ci { font: 600 10px/1 var(--mono); opacity: .6; letter-spacing: 0; }
      .chan-body { padding: 13px 14px; }
      .chan.in { box-shadow: inset 3px 0 0 -1px var(--in); }
      .chan.act { box-shadow: inset 3px 0 0 -1px var(--act); }
      .chan.out { box-shadow: inset 3px 0 0 -1px var(--out); }

      .item { margin-bottom: 13px; } .item:last-child { margin-bottom: 0; }
      __SHARED_CSS__

      .prompt { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px; color: var(--faint); text-align: center; padding: 40px; }
      .prompt .lens { width: 64px; height: 64px; border-radius: 50%;
        background: conic-gradient(from 210deg, var(--in), var(--act), var(--out), var(--in));
        -webkit-mask: radial-gradient(circle 22px at 50% 50%, transparent 96%, #000 100%);
                mask: radial-gradient(circle 22px at 50% 50%, transparent 96%, #000 100%);
        opacity: .5; }
      .prompt h2 { margin: 0; font: 600 15px var(--display); color: var(--muted); letter-spacing: .3px; }
      .prompt p { margin: 0; font-size: 12px; max-width: 320px; }
      .prompt kbd { font: 11px var(--mono); background: var(--panel-2); border: 1px solid var(--line); border-radius: 4px; padding: 1px 6px; color: var(--muted); }

      /* ---------- responsive floor ---------- */
      @media (max-width: 880px) {
        .bench { grid-template-columns: minmax(0, 1fr); }
        .stage-view { display: none; }
        body.focus .tray { display: none; }
        body.focus .stage-view { display: block; }
        .spec-back { display: inline-flex; }
        .spec-side { max-width: 50%; }
        .spec { padding: 20px 15px 44px; }
      }
    </style>
    </head>
    <body data-skipped="__SKIPPED__">
      <header class="bar">
        <div class="brand"><span class="mark" aria-hidden="true"></span><span class="word">TEST<i>&middot;</i>LENS</span></div>
        <div class="run-chart">__RUN_SUMMARY__</div>
        <div class="readout" id="readout"></div>
      </header>

      <details class="overview">
        <summary><span class="ov-caret" aria-hidden="true">&#9656;</span> Overview</summary>
        <div class="overview-body">
          <div class="ov-panel"><div class="ov-h">Slowest tests</div>__DURATION_CHART__</div>
          <div class="ov-panel"><div class="ov-h">By module</div>__MODULE_CHART__</div>
        </div>
      </details>

      <div class="bench">
        <aside class="tray">
          <div class="tools">
            <input id="q" class="q" type="search" placeholder="Filter by name or module" aria-label="Filter specimens" />
            <div class="seg" id="statusSeg" role="group" aria-label="Status filter"></div>
            <div class="tools-row">
              <label class="toggle"><input type="checkbox" id="groupBy" checked /> group by module</label>
              <select id="proj" class="proj" aria-label="Project filter"></select>
            </div>
          </div>
          <div class="traycount" id="traycount"></div>
          <div class="scroller" id="scroller" tabindex="0" aria-label="Specimen list">
            <div class="sizer" id="sizer"><div class="layer" id="layer"></div></div>
            <div class="nomatch" id="nomatch" hidden>No specimens match this filter.</div>
          </div>
        </aside>
        <section class="stage-view" id="detail"></section>
      </div>

      <script>__HLJS__</script>
      <script id="data" type="application/json">__CASES_JSON__</script>
      <script>
      const CASES = JSON.parse(document.getElementById("data").textContent);
      const SKIPPED = +(document.body.dataset.skipped || 0);
      const ROW_H = 32, OVERSCAN = 8;

      CASES.forEach((c, i) => {
        c._id = i;
        c._dbn = (c.db_events || []).length;
      });

      let search = "", statusF = "all", projF = "all", groupBy = true;
      const collapsed = new Set();
      let selectedId = null;
      let rows = [];

      __SHARED_JS__
      const sev = c => { const k = kind(c.status); return k === "fail" ? 0 : k === "skip" ? 1 : 2; };
      const caseId = c => c.module + "::" + c.name;
      const caseKey = c => encodeURIComponent(caseId(c));

      /* ---------- readout ---------- */
      function renderReadout() {
        const t = CASES.length;
        const pass = CASES.filter(c => kind(c.status) === "pass").length;
        const fail = CASES.filter(c => kind(c.status) === "fail").length;
        const skip = t - pass - fail;
        const db = CASES.reduce((n, c) => n + c._dbn, 0);
        const rate = t ? (pass / t * 100) : 0;
        $("readout").innerHTML =
          `<div class="meter" title="${rate.toFixed(1)}% passing"><span style="width:${rate}%"></span></div>` +
          `<div class="nums">` +
            `<b class="n">${t.toLocaleString()}</b><span class="nl">specimens</span>` +
            `<span class="sep"></span>` +
            `<b class="n pass">${pass.toLocaleString()}</b><span class="nl">pass</span>` +
            `<b class="n fail">${fail.toLocaleString()}</b><span class="nl">fail</span>` +
            `<b class="n skip">${skip.toLocaleString()}</b><span class="nl">skip</span>` +
            `<span class="sep"></span>` +
            `<b class="n">${db.toLocaleString()}</b><span class="nl">db writes</span>` +
          `</div>` +
          (SKIPPED
            ? `<span class="skipwarn" title="${SKIPPED.toLocaleString()} case file${SKIPPED === 1 ? "" : "s"} could not be read and ${SKIPPED === 1 ? "was" : "were"} skipped">` +
                `&#9888; ${SKIPPED.toLocaleString()} unreadable</span>`
            : "");
      }

      /* ---------- controls ---------- */
      function renderControls() {
        const counts = { all: CASES.length, pass: 0, fail: 0, skip: 0 };
        CASES.forEach(c => counts[kind(c.status)]++);
        const segs = [["all", "All"], ["fail", "Fail"], ["skip", "Skip"], ["pass", "Pass"]];
        $("statusSeg").innerHTML = segs.map(([v, l]) =>
          `<button data-st="${v}" class="${v === statusF ? "on" : ""}">${l}<span class="c">${counts[v].toLocaleString()}</span></button>`).join("");
        $("statusSeg").querySelectorAll("button").forEach(b => b.onclick = () => {
          statusF = b.dataset.st; renderControls(); rebuild(true);
        });

        const projects = [...new Set(CASES.map(c => c.project).filter(Boolean))];
        const proj = $("proj");
        if (projects.length <= 1) { proj.style.display = "none"; }
        else {
          proj.style.display = "";
          proj.innerHTML = ['<option value="all">all projects</option>']
            .concat(projects.map(p => `<option value="${escA(p)}">${esc(p)}</option>`)).join("");
          proj.value = projF;
          proj.onchange = () => { projF = proj.value; rebuild(true); };
        }
      }

      /* ---------- row model ---------- */
      function buildRows() {
        const q = search.trim().toLowerCase();
        const list = CASES.filter(c =>
          (statusF === "all" || kind(c.status) === statusF) &&
          (projF === "all" || c.project === projF) &&
          (!q || c.name.toLowerCase().includes(q) || (c.module || "").toLowerCase().includes(q)));

        if (!groupBy) {
          list.sort((a, b) => sev(a) - sev(b) || (a.module || "").localeCompare(b.module || "") || (a.line || 0) - (b.line || 0));
          return { rows: list.map(c => ({ type: "test", id: c._id })), tests: list.length, mods: new Set(list.map(c => c.module)).size };
        }

        const groups = {};
        list.forEach(c => (groups[c.module] || (groups[c.module] = [])).push(c));
        Object.values(groups).forEach(g => g.sort((a, b) => sev(a) - sev(b) || (a.line || 0) - (b.line || 0) || a.name.localeCompare(b.name)));
        const mods = Object.keys(groups).sort((a, b) => {
          const fa = groups[a].filter(c => kind(c.status) === "fail").length;
          const fb = groups[b].filter(c => kind(c.status) === "fail").length;
          return (fb - fa) || a.localeCompare(b);
        });
        const out = [];
        mods.forEach(m => {
          const g = groups[m];
          const pass = g.filter(c => kind(c.status) === "pass").length;
          const fail = g.filter(c => kind(c.status) === "fail").length;
          out.push({ type: "group", module: m, pass, fail, skip: g.length - pass - fail });
          if (!collapsed.has(m)) g.forEach(c => out.push({ type: "test", id: c._id }));
        });
        return { rows: out, tests: list.length, mods: mods.length };
      }

      function shape(c) {
        const has = { setup: false, action: false, verify: false };
        (c.captures || []).forEach(x => { if (x.stage in has) has[x.stage] = true; });
        (c.db_events || []).forEach(x => { if (x.stage in has) has[x.stage] = true; });
        return `<span class="sh"><i class="${has.setup ? "in" : ""}"></i><i class="${has.action ? "act" : ""}"></i><i class="${has.verify ? "out" : ""}"></i></span>`;
      }

      function rowHtml(r) {
        if (r.type === "group") {
          const col = collapsed.has(r.module);
          return `<div class="row group" data-mod="${escA(r.module)}">` +
            `<span class="caret ${col ? "col" : ""}">&#9662;</span>` +
            `<span class="gm" title="${escA(r.module)}">${esc(r.module)}</span>` +
            `<span class="gtally">${r.fail ? `<i class="t-fail">${r.fail}&#10007;</i>` : ""}${r.skip ? `<i class="t-skip">${r.skip}&#8856;</i>` : ""}<i class="t-ok">${r.pass}&#10003;</i></span>` +
          `</div>`;
        }
        const c = CASES[r.id];
        const k = kind(c.status);
        const mod = groupBy ? "" : `<span class="rmod">${esc(c.module)} &rsaquo; </span>`;
        return `<button class="row test${r.id === selectedId ? " sel" : ""}" data-id="${r.id}">` +
          `<span class="g ${k}"></span>` +
          `<span class="rn" title="${escA(c.name)}">${mod}${esc(c.name)}</span>` +
          `<span class="rmeta">${shape(c)}${c.duration_us != null ? `<span class="dur">${formatMs(c.duration_us)}</span>` : ""}${c._dbn ? `<span class="dbt">&#43;${c._dbn}</span>` : ""}</span>` +
        `</button>`;
      }

      /* ---------- virtualized paint ---------- */
      const scroller = $("scroller"), sizer = $("sizer"), layer = $("layer");
      function paint() {
        const st = scroller.scrollTop, h = scroller.clientHeight;
        const start = Math.max(0, Math.floor(st / ROW_H) - OVERSCAN);
        const end = Math.min(rows.length, Math.ceil((st + h) / ROW_H) + OVERSCAN);
        layer.style.transform = `translateY(${start * ROW_H}px)`;
        let html = "";
        for (let i = start; i < end; i++) html += rowHtml(rows[i]);
        layer.innerHTML = html;
      }
      scroller.addEventListener("scroll", () => requestAnimationFrame(paint), { passive: true });

      function rebuild(resetScroll) {
        const r = buildRows();
        rows = r.rows;
        sizer.style.height = (rows.length * ROW_H) + "px";
        $("nomatch").hidden = rows.length > 0;
        $("traycount").innerHTML = `<b>${r.tests.toLocaleString()}</b> tests` + (groupBy ? ` &middot; <b>${r.mods.toLocaleString()}</b> modules` : "");
        if (resetScroll) scroller.scrollTop = 0;
        paint();
      }

      function emptyPrompt() {
        return `<div class="prompt"><div class="lens"></div><h2>Select a specimen</h2>` +
          `<p>Pick a test from the tray to see it refracted into input, action and result. Use <kbd>&uarr;</kbd> <kbd>&darr;</kbd> to step through, <kbd>/</kbd> to filter.</p></div>`;
      }
      function notFoundPrompt(want) {
        return `<div class="prompt"><div class="lens"></div><h2>Specimen not found</h2>` +
          `<p>No test in this run matches <kbd>${esc(want)}</kbd>. Pick one from the tray, ` +
          `or drop the <kbd>?test=</kbd> from the link.</p></div>`;
      }
      function renderDetail() {
        const d = $("detail");
        if (selectedId == null) { d.innerHTML = emptyPrompt(); return; }
        const c = CASES[selectedId];
        const stages = buildStages(c);
        const tags = [].concat(c.tags || []).map(t => `<span class="tag">${esc(String(t))}</span>`).join("");
        d.innerHTML =
          `<div class="spec">` +
            `<button class="spec-back" id="back">&larr; specimens</button>` +
            `<div class="spec-head"><span class="g ${kind(c.status)} big"></span>` +
              `<div class="spec-id"><div class="spec-name">${esc(c.name)}</div>` +
                `<div class="spec-sub"><span class="mono">${esc(c.module)}</span>` +
                  `<span class="dim">${c.file ? ` &middot; ${esc(c.file)}${c.line ? ":" + esc(String(c.line)) : ""}` : ""}</span>` +
                  `${c.duration_us != null ? ` &middot; ${formatMs(c.duration_us)}` : ""} &middot; <span class="st ${kind(c.status)}">${esc(c.status)}</span></div>` +
              `</div>` +
              `<div class="spec-side">${tags}${c.project ? `<span class="tag proj">${esc(c.project)}</span>` : ""}</div>` +
            `</div>` +
            `<div class="beam" style="--cols:${stages.length}">${stages.map(s => `<div class="ap ${s.key}"><span class="ring"></span></div>`).join("")}</div>` +
            `<div class="axis" style="--cols:${stages.length}">` +
              stages.map(s => `<div class="chan ${s.key}"><div class="chan-h"><span class="ci">${s.idx}</span>${esc(s.label)}</div>` +
                `<div class="chan-body">${s.items.length ? s.items.map(itemHtml).join("") : '<div class="none">nothing captured here</div>'}</div></div>`).join("") +
            `</div>` +
          `</div>`;
        hydrateBlocks(d);
        const back = $("back");
        if (back) back.onclick = () => document.body.classList.remove("focus");
      }

      function select(id) {
        selectedId = id;
        if (window.innerWidth <= 880) document.body.classList.add("focus");
        renderDetail();
        // refresh sel highlight in the visible window
        paint();
        const c = CASES[id];
        if (c) history.replaceState(null, "", "?test=" + caseKey(c));
      }

      /* ---------- interactions ---------- */
      layer.addEventListener("click", e => {
        const grp = e.target.closest(".row.group");
        if (grp) { const m = grp.dataset.mod; collapsed.has(m) ? collapsed.delete(m) : collapsed.add(m); rebuild(false); return; }
        const row = e.target.closest(".row.test");
        if (row) select(+row.dataset.id);
      });

      let qt;
      $("q").addEventListener("input", e => { clearTimeout(qt); qt = setTimeout(() => { search = e.target.value; rebuild(true); }, 110); });
      $("groupBy").addEventListener("change", e => { groupBy = e.target.checked; rebuild(true); });

      document.addEventListener("keydown", e => {
        if (e.key === "/" && document.activeElement !== $("q")) { e.preventDefault(); $("q").focus(); return; }
        if (e.key === "Escape" && document.activeElement === $("q")) { $("q").blur(); return; }
        if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
        if (document.activeElement === $("q")) return;
        e.preventDefault();
        const testRows = rows.map((r, i) => r.type === "test" ? i : -1).filter(i => i >= 0);
        if (!testRows.length) return;
        const cur = rows.findIndex(r => r.type === "test" && r.id === selectedId);
        let pos = testRows.indexOf(cur);
        pos = e.key === "ArrowDown" ? Math.min(testRows.length - 1, pos + 1) : Math.max(0, pos - 1);
        if (pos < 0) pos = 0;
        const idx = testRows[pos];
        const top = idx * ROW_H;
        if (top < scroller.scrollTop) scroller.scrollTop = top;
        else if (top + ROW_H > scroller.scrollTop + scroller.clientHeight) scroller.scrollTop = top + ROW_H - scroller.clientHeight;
        select(rows[idx].id);
      });

      /* ---------- boot ---------- */
      wireBlocks($("detail"));
      renderReadout();
      renderControls();
      rebuild(true);
      const wantTest = new URLSearchParams(location.search).get("test");
      const target = wantTest ? CASES.find(c => caseId(c) === wantTest) : null;
      if (target) {
        collapsed.delete(target.module);
        rebuild(true);
        select(target._id);
        const idx = rows.findIndex(r => r.type === "test" && r.id === target._id);
        if (idx >= 0) { scroller.scrollTop = Math.max(0, idx * ROW_H - scroller.clientHeight / 2); paint(); }
      } else if (wantTest) {
        // an explicit ?test= that matched nothing: say so, don't silently pick another
        $("detail").innerHTML = notFoundPrompt(wantTest);
      } else {
        const first = rows.find(r => r.type === "test");
        if (first && window.innerWidth > 880) select(first.id);
        else renderDetail();
      }
      </script>
    </body>
    </html>
    """
  end
end
