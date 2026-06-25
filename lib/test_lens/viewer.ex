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

  @doc "Read `<dir>/cases/*.json` and write `<dir>/index.html`. Returns {:ok, path, count}."
  def build(opts \\ []) do
    dir = opts[:dir] || "test_lens_out"
    out = opts[:out] || Path.join(dir, "index.html")

    cases =
      dir
      |> Path.join("cases/*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)

    json = cases |> Jason.encode!() |> String.replace("</", "<\\/")

    html =
      template()
      |> String.replace("__CASES_JSON__", json)
      |> String.replace("__COUNT__", Integer.to_string(length(cases)))

    File.write!(out, html)
    {:ok, out, length(cases)}
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
      @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap');

      :root {
        --bg: #090b10; --bg-2: #0c0f16; --panel: #11151e; --panel-2: #161b27;
        --line: #222a38; --line-2: #2c3445; --text: #e9ecf3; --muted: #8a93a6;
        --faint: #5a6378;
        --gold: #f4b740;          /* the single UI accent: instrument readout */
        --pass: #45d49a; --fail: #fb6f78; --skip: #6b7488;
        --in: #41c9e3; --act: #a98bff; --out: #fb7faf;   /* refraction channels */
        --ins: #45d49a; --del: #fb6f78; --upd: #f4b740;  /* delta signs */
        --mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
        --display: "Space Grotesk", system-ui, "Segoe UI", sans-serif;
        --row-h: 32px;
      }

      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 13.5px/1.55 var(--mono);
        -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
        display: grid; grid-template-rows: auto 1fr; height: 100vh; overflow: hidden;
      }

      /* ---------- instrument header ---------- */
      .bar {
        display: flex; align-items: center; gap: 26px;
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

      .readout { display: flex; align-items: center; gap: 16px; min-width: 0; }
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

      /* ---------- bench ---------- */
      .bench { display: grid; grid-template-columns: 372px 1fr; min-height: 0; }

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
      .stage-view { overflow: auto; min-height: 0; background: var(--bg); }
      .spec { padding: 24px 28px 60px; max-width: 1280px; margin: 0 auto; }
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

      /* the refraction beam: rings align over the channel columns below */
      .beam { display: grid; gap: 0; position: relative; margin: 22px 0 0; height: 30px; }
      .beam::before { content: ""; position: absolute; left: 8%; right: 8%; top: 14px; height: 2px;
        background: linear-gradient(90deg, var(--in), var(--act), var(--out)); opacity: .55; border-radius: 2px; }
      .ap { display: flex; align-items: center; justify-content: center; position: relative; }
      .ring { width: 13px; height: 13px; border-radius: 50%; background: var(--bg); position: relative; z-index: 1; box-shadow: 0 0 0 2px currentColor, 0 0 12px currentColor; }
      .ap.in { color: var(--in); } .ap.act { color: var(--act); } .ap.out { color: var(--out); }

      .axis { display: grid; gap: 14px; margin-top: 6px; align-items: start; }
      .chan { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); overflow: hidden; min-width: 0; }
      .chan-h { display: flex; align-items: center; gap: 8px; padding: 11px 14px; font: 600 11px/1 var(--display); letter-spacing: 1.6px; border-bottom: 1px solid var(--line); }
      .chan.in .chan-h { color: var(--in); } .chan.act .chan-h { color: var(--act); } .chan.out .chan-h { color: var(--out); }
      .chan-h .ci { font: 600 10px/1 var(--mono); opacity: .6; letter-spacing: 0; }
      .chan-body { padding: 13px 14px; }
      .chan.in { box-shadow: inset 3px 0 0 -1px var(--in); }
      .chan.act { box-shadow: inset 3px 0 0 -1px var(--act); }
      .chan.out { box-shadow: inset 3px 0 0 -1px var(--out); }

      .item { margin-bottom: 13px; } .item:last-child { margin-bottom: 0; }
      .ilabel { color: var(--muted); font-size: 11.5px; margin-bottom: 5px; }
      .ilabel b { color: var(--text); font-weight: 600; }
      .none { color: var(--faint); font-style: italic; font-size: 12px; }

      pre { margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 8px;
        padding: 9px 11px; overflow-x: auto; font: 12px/1.55 var(--mono);
        white-space: pre-wrap; word-break: break-word; }
      .kv { display: grid; grid-template-columns: auto 1fr; gap: 2px 12px; font: 12px/1.5 var(--mono); margin: 4px 0; }
      .kv .k { color: var(--muted); }
      .httpline { font: 12.5px/1.5 var(--mono); margin-bottom: 7px; }
      .method { color: var(--act); font-weight: 700; }
      .scode.ok { color: var(--pass); font-weight: 700; } .scode.bad { color: var(--fail); font-weight: 700; }

      .delta { border-radius: 8px; padding: 9px 11px; margin-bottom: 11px; border: 1px solid var(--line); background: var(--bg-2); }
      .delta-h { display: flex; align-items: center; gap: 8px; font-size: 11.5px; margin-bottom: 7px; }
      .delta .sign { font-weight: 800; width: 15px; height: 15px; display: inline-flex; align-items: center; justify-content: center; border-radius: 4px; font-size: 12px; }
      .delta.ins { border-color: rgba(69,212,154,.4); } .delta.ins .sign { color: var(--ins); background: rgba(69,212,154,.14); }
      .delta.del { border-color: rgba(251,111,120,.4); } .delta.del .sign { color: var(--del); background: rgba(251,111,120,.14); }
      .delta.upd { border-color: rgba(244,183,64,.4); }  .delta.upd .sign { color: var(--upd); background: rgba(244,183,64,.14); }
      .delta .op { font-weight: 700; letter-spacing: .5px; } .delta .src { color: var(--muted); }
      .delta pre { background: var(--bg); }

      .json-key { color: #79c0ff; } .json-str { color: #8dd1a6; } .json-num { color: #f0a45a; } .json-bool { color: #ff9a8d; }

      /* ---------- inline SQL / Elixir token colors ---------- */
      .tok-kw { color: var(--act); font-weight: 600; }
      .tok-str { color: #8dd1a6; }
      .tok-num { color: #f0a45a; }
      .tok-com { color: var(--muted); font-style: italic; }
      .tok-fn  { color: #79c0ff; }

      /* ---------- copied phase source (what the test does) ---------- */
      pre.phase-src { background: var(--bg-2); color: var(--text); border-left: 2px solid var(--line-2); }
      .chan.in pre.phase-src { border-left-color: var(--in); }
      .chan.act pre.phase-src { border-left-color: var(--act); }
      .chan.out pre.phase-src { border-left-color: var(--out); }

      /* ---------- annotation readout ---------- */
      .anno { margin-bottom: 8px; display: flex; flex-direction: column; gap: 5px; }
      .anno-line {
        display: inline-flex; align-items: baseline; gap: 8px; align-self: flex-start;
        border-radius: 7px; padding: 5px 10px; font: 12px/1.4 var(--mono);
        color: var(--gold); background: rgba(244,183,64,.1);
        border: 1px solid rgba(244,183,64,.32); box-shadow: 0 0 10px rgba(244,183,64,.12);
      }
      .anno-path { color: var(--gold); opacity: .85; }
      .anno-eq { color: var(--faint); }
      .anno-val { color: var(--text); font-weight: 600; }
      .anno-line.miss { color: var(--muted); background: var(--panel-2); border-color: var(--line); box-shadow: none; }
      .anno-line.miss .anno-val { color: var(--faint); font-style: italic; font-weight: 400; }
      .hl { border-radius: 3px; padding: 0 2px; background: rgba(244,183,64,.22); box-shadow: 0 0 0 1px rgba(244,183,64,.4); }

      /* ---------- dolt_op capture ---------- */
      .dolt-op { border-radius: 10px; padding: 10px 13px; border: 1px solid rgba(130,100,220,.35); background: rgba(100,60,200,.07); }
      .dolt-op-head { display: flex; align-items: center; gap: 9px; margin-bottom: 8px; flex-wrap: wrap; }
      .dolt-badge { font: 700 10.5px/1 var(--mono); letter-spacing: .8px; text-transform: uppercase; border-radius: 5px; padding: 3px 8px; flex: none; }
      .dolt-badge.commit { color: #a78bfa; background: rgba(167,139,250,.14); border: 1px solid rgba(167,139,250,.3); }
      .dolt-badge.branch { color: #34d399; background: rgba(52,211,153,.12); border: 1px solid rgba(52,211,153,.28); }
      .dolt-badge.merge  { color: #f472b6; background: rgba(244,114,182,.12); border: 1px solid rgba(244,114,182,.28); }
      .dolt-badge.diff   { color: #60a5fa; background: rgba(96,165,250,.12); border: 1px solid rgba(96,165,250,.28); }
      .dolt-badge.other  { color: var(--muted); background: var(--panel-2); border: 1px solid var(--line); }
      .dolt-hash { font: 600 11px/1 var(--mono); color: var(--faint); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: 2px 7px; letter-spacing: .5px; }
      .dolt-branch { font: 12px/1 var(--mono); color: var(--muted); }
      .dolt-branch::before { content: "⎇ "; color: var(--faint); font-size: 10px; }
      .dolt-msg { font: 13px/1.5 var(--mono); color: var(--text); margin-top: 2px; }
      .dolt-result { margin-top: 8px; }

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
        .bench { grid-template-columns: 1fr; }
        .stage-view { display: none; }
        body.focus .tray { display: none; }
        body.focus .stage-view { display: block; }
        .spec-back { display: inline-flex; }
        .spec-side { max-width: 50%; }
      }
    </style>
    </head>
    <body>
      <header class="bar">
        <div class="brand"><span class="mark" aria-hidden="true"></span><span class="word">TEST<i>&middot;</i>LENS</span></div>
        <div class="readout" id="readout"></div>
      </header>

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

      <script id="data" type="application/json">__CASES_JSON__</script>
      <script>
      const CASES = JSON.parse(document.getElementById("data").textContent);
      const ROW_H = 32, OVERSCAN = 8;

      CASES.forEach((c, i) => {
        c._id = i;
        c._dbn = (c.db_events || []).length;
        c._dur = c.duration_us != null ? c.duration_us / 1000 : null;
      });

      let search = "", statusF = "all", projF = "all", groupBy = true;
      const collapsed = new Set();
      let selectedId = null;
      let rows = [];

      const $ = id => document.getElementById(id);
      const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
      const escA = s => esc(s).replace(/"/g, '&quot;');
      const kind = s => s === "passed" ? "pass" : (s === "skipped" || s === "excluded") ? "skip" : "fail";
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
          `</div>`;
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
          `<span class="rmeta">${shape(c)}${c._dur != null ? `<span class="dur">${c._dur.toFixed(1)}ms</span>` : ""}${c._dbn ? `<span class="dbt">&#43;${c._dbn}</span>` : ""}</span>` +
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

      /* ---------- detail / refraction ---------- */
      function jsonHtml(v) {
        return esc(JSON.stringify(v, null, 2))
          .replace(/&quot;([^&]+)&quot;(\s*:)/g, '<span class="json-key">"$1"</span>$2')
          .replace(/: (&quot;[^]*?&quot;)(,?)$/gm, ': <span class="json-str">$1</span>$2')
          .replace(/: (-?\d+\.?\d*)(,?)$/gm, ': <span class="json-num">$1</span>$2')
          .replace(/: (true|false|null)(,?)$/gm, ': <span class="json-bool">$1</span>$2');
      }
      /* ---------- inline syntax highlighting (dependency-free, XSS-safe) ----------
         esc() runs FIRST so &<> become entities; the only HTML we inject is our own
         <span> tags. A single combined regex avoids nested-span corruption. */
      function hl(s, kw) {
        const RE = /((?:'(?:[^'\\]|\\.)*')|(?:"(?:[^"\\]|\\.)*"))|(--[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\/)|(\b\d[\d_.]*\b)|([A-Za-z_][A-Za-z0-9_]*[!?]?)/g;
        const E = esc(s);
        return E.replace(RE, (m, str, com, num, word, off) => {
          if (str) return `<span class="tok-str">${m}</span>`;
          if (com) return `<span class="tok-com">${m}</span>`;
          if (num) return `<span class="tok-num">${m}</span>`;
          if (word) {
            if (kw.has(word.toUpperCase())) return `<span class="tok-kw">${m}</span>`;
            if (E[off + m.length] === "(") return `<span class="tok-fn">${m}</span>`;
          }
          return m;
        });
      }
      const SQL_KW = new Set("SELECT INSERT INTO VALUES UPDATE SET DELETE FROM WHERE AND OR NOT NULL JOIN LEFT RIGHT INNER OUTER FULL CROSS ON AS ORDER GROUP BY HAVING LIMIT OFFSET RETURNING DISTINCT IN IS LIKE ILIKE BETWEEN CREATE TABLE PRIMARY KEY FOREIGN REFERENCES INDEX UNIQUE DROP ALTER ADD COLUMN COMMIT ROLLBACK BEGIN TRANSACTION SAVEPOINT CASE WHEN THEN ELSE END UNION ALL EXISTS ASC DESC USING DEFAULT CONSTRAINT CHECK INT INTEGER VARCHAR TEXT BOOLEAN TIMESTAMP".split(" "));
      const EX_KW = new Set("DEF DEFP DEFMODULE DEFMACRO DEFMACROP DEFPROTOCOL DEFIMPL DEFSTRUCT DEFEXCEPTION DEFGUARD DEFGUARDP DO END FN IF UNLESS ELSE COND CASE WHEN WITH FOR TRY CATCH RESCUE AFTER RAISE THROW RECEIVE AND OR NOT IN NIL TRUE FALSE IMPORT ALIAS REQUIRE USE QUOTE UNQUOTE".split(" "));
      function sqlHtml(s){ return hl(s, SQL_KW); }
      function elixirHtml(s){ return hl(s, EX_KW); }
      /* ---------- annotation: resolve + highlight ---------- */
      const PATH_MISS = Symbol("miss");
      function resolvePath(value, path) {
        let cur = value;
        for (const key of path) {
          if (cur == null) return PATH_MISS;
          if (Array.isArray(cur)) {
            if (typeof key !== "number" || key < 0 || key >= cur.length) return PATH_MISS;
            cur = cur[key];
          } else if (typeof cur === "object") {
            const k = String(key);
            if (!Object.prototype.hasOwnProperty.call(cur, k)) return PATH_MISS;
            cur = cur[k];
          } else {
            return PATH_MISS;
          }
        }
        return cur;
      }
      function pathLabel(path) { return path.map(k => String(k)).join("."); }
      function annoHtml(it) {
        if (!it.paths || !it.paths.length) return "";
        const lines = it.paths.map(path => {
          const resolved = resolvePath(it.value, path);
          if (resolved === PATH_MISS) {
            return `<div class="anno-line miss"><span class="anno-path">${esc(pathLabel(path))}</span>` +
              `<span class="anno-val">annotation matched no value</span></div>`;
          }
          const shown = typeof resolved === "object" ? JSON.stringify(resolved) : String(resolved);
          return `<div class="anno-line"><span class="anno-path">${esc(pathLabel(path))}</span>` +
            `<span class="anno-eq">=</span><span class="anno-val">${esc(shown)}</span></div>`;
        }).join("");
        return `<div class="anno">${lines}</div>`;
      }
      // Highlight the matched leaf keys of each annotation path inside the expanded JSON.
      function jsonHtmlHighlighted(value, paths) {
        const keys = new Set();
        (paths || []).forEach(path => {
          if (!path.length) return;
          if (resolvePath(value, path) === PATH_MISS) return;
          const last = path[path.length - 1];
          if (typeof last !== "number") keys.add(String(last));
        });
        let html = jsonHtml(value);
        keys.forEach(k => {
          const needle = `<span class="json-key">"${esc(k)}"</span>`;
          html = html.split(needle).join(`<span class="hl">${needle}</span>`);
        });
        return html;
      }
      function kvHtml(obj) {
        if (!obj || typeof obj !== "object") return "";
        return '<div class="kv">' + Object.entries(obj)
          .map(([k, v]) => `<div class="k">${esc(k)}</div><div>${esc(typeof v === "object" ? JSON.stringify(v) : v)}</div>`).join("") + "</div>";
      }
      /* ---------- kind → renderer registry ----------
         Each entry is a function (value, item) -> HTML string.
         Unknown kinds fall back to the generic JSON block.
         To add a new capture source: register one entry here.
         The collect and transform steps need no core change at all.
      --------------------------------------------------------- */
      const kindRenderers = {
        http_request: v =>
          `<div class="httpline"><span class="method">${esc(v.method)}</span> ${esc(v.path)}</div>` +
          (v.headers ? kvHtml(v.headers) : "") + (v.body ? `<pre>${jsonHtml(v.body)}</pre>` : ""),

        http_response: v => {
          const cls = String(v.status)[0] >= "4" ? "bad" : "ok";
          return `<div class="httpline">HTTP <span class="scode ${cls}">${esc(v.status)}</span></div>` +
            (v.headers ? kvHtml(v.headers) : "") + (v.body ? `<pre>${jsonHtml(v.body)}</pre>` : "");
        },

        text: v => `<pre>${esc(v)}</pre>`,

        source: v => `<pre class="phase-src hl elixir">${elixirHtml(v)}</pre>`,

        dolt_op: v => {
          const action = (v.action || "op").toLowerCase();
          const knownActions = ["commit", "branch", "merge", "diff"];
          const badgeCls = knownActions.includes(action) ? action : "other";
          const badge = `<span class="dolt-badge ${badgeCls}">${esc(action)}</span>`;
          const hash = v.commit_hash
            ? `<span class="dolt-hash">${esc(String(v.commit_hash).slice(0, 7))}</span>`
            : "";
          const branch = v.branch
            ? `<span class="dolt-branch">${esc(v.branch)}</span>`
            : "";
          const msg = v.message
            ? `<div class="dolt-msg">${esc(v.message)}</div>`
            : "";
          const result = v.result != null
            ? `<div class="dolt-result"><pre>${jsonHtml(v.result)}</pre></div>`
            : "";
          return `<div class="dolt-op">` +
            `<div class="dolt-op-head">${badge}${hash}${branch}</div>` +
            msg + result +
            `</div>`;
        }
      };

      function renderValue(it) {
        const renderer = Object.prototype.hasOwnProperty.call(kindRenderers, it.kind) ? kindRenderers[it.kind] : null;
        if (renderer) return renderer(it.value, it);
        if (it.paths && it.paths.length) return `<pre>${jsonHtmlHighlighted(it.value, it.paths)}</pre>`;
        return `<pre>${jsonHtml(it.value)}</pre>`;
      }
      function deltaHtml(ev) {
        const op = (ev.op || "").toUpperCase();
        const map = op.startsWith("INSERT") ? ["ins", "&#43;"] : op.startsWith("DELETE") ? ["del", "&#8722;"] : op.startsWith("UPDATE") ? ["upd", "~"] : ["upd", "&middot;"];
        return `<div class="delta ${map[0]}"><div class="delta-h"><span class="sign">${map[1]}</span><span class="op">${esc(ev.op)}</span><span class="src">${esc(ev.source || "")}</span></div>` +
          `<pre class="hl sql">${sqlHtml(ev.sql)}</pre>` +
          (ev.params && ev.params.length ? `<div class="ilabel">params</div><pre>${jsonHtml(ev.params)}</pre>` : "") + "</div>";
      }
      function buildStages(c) {
        const defs = [["setup", "INPUT", "in", "I"], ["action", "ACTION", "act", "II"], ["verify", "RESULT", "out", "III"]];
        const items = { setup: [], action: [], verify: [] };
        (c.captures || []).forEach(x => (items[x.stage] || (items[x.stage] = [])).push({ ...x, _t: "cap" }));
        (c.db_events || []).forEach(x => (items[x.stage] || (items[x.stage] = [])).push({ ...x, _t: "db" }));
        Object.values(items).forEach(a => a.sort((p, q) => (p.seq || 0) - (q.seq || 0)));
        const stages = defs.map(([k, label, key, idx]) => ({ key, label, idx, items: items[k] || [] }));
        Object.keys(items).forEach(k => { if (!["setup", "action", "verify"].includes(k)) stages.push({ key: "act", label: k.toUpperCase(), idx: "&middot;", items: items[k] }); });
        return stages;
      }
      function itemHtml(it) {
        if (it._t === "db") return deltaHtml(it);
        const bare = it.kind === "http_request" || it.kind === "http_response";
        const hasLabel = !bare && it.label != null && String(it.label).trim() !== "";
        const label = hasLabel ? `<div class="ilabel"><b>${esc(it.label)}</b></div>` : "";
        return `<div class="item">${label}${annoHtml(it)}${renderValue(it)}</div>`;
      }
      function emptyPrompt() {
        return `<div class="prompt"><div class="lens"></div><h2>Select a specimen</h2>` +
          `<p>Pick a test from the tray to see it refracted into input, action and result. Use <kbd>&uarr;</kbd> <kbd>&darr;</kbd> to step through, <kbd>/</kbd> to filter.</p></div>`;
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
                  `${c._dur != null ? ` &middot; ${c._dur.toFixed(1)}ms` : ""} &middot; <span class="st ${kind(c.status)}">${esc(c.status)}</span></div>` +
              `</div>` +
              `<div class="spec-side">${tags}${c.project ? `<span class="tag proj">${esc(c.project)}</span>` : ""}</div>` +
            `</div>` +
            `<div class="beam" style="grid-template-columns:repeat(${stages.length},1fr)">${stages.map(s => `<div class="ap ${s.key}"><span class="ring"></span></div>`).join("")}</div>` +
            `<div class="axis" style="grid-template-columns:repeat(${stages.length},1fr)">` +
              stages.map(s => `<div class="chan ${s.key}"><div class="chan-h"><span class="ci">${s.idx}</span>${esc(s.label)}</div>` +
                `<div class="chan-body">${s.items.length ? s.items.map(itemHtml).join("") : '<div class="none">nothing captured here</div>'}</div></div>`).join("") +
            `</div>` +
          `</div>`;
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
