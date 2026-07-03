defmodule TestLens.DiffViewer do
  @moduledoc """
  Render a computed `TestLens.Diff` into a single self-contained HTML file.

  Shares the viewer's instrument aesthetic and its input → action → result
  refraction: each expanded test refracts into INPUT/ACTION/RESULT channels with
  database deltas inline, exactly as `TestLens.Viewer` renders a specimen — so a
  diff reads like two specimens side by side. The whole report is one file: the
  diff payload is injected as a `<script type="application/json">` block and all
  CSS/JS is embedded, with the same single cosmetic web-font import the viewer
  uses.

  Use `TestLens.Diff.build/1` to compute a diff and write this alongside a
  machine-readable `diff.json`.
  """

  alias TestLens.Diff

  @doc "Render a `%TestLens.Diff{}` to a complete HTML document string."
  @spec render(Diff.t()) :: String.t()
  def render(%Diff{} = d) do
    payload = %{
      "base" => header_meta(d.base),
      "head" => header_meta(d.head),
      "counts" => %{
        "added" => length(d.added),
        "removed" => length(d.removed),
        "flipped" => length(d.flipped),
        "changed" => length(d.changed),
        "unchanged" => d.unchanged
      },
      "added" => d.added,
      "removed" => d.removed,
      "flipped" => Enum.map(d.flipped, &%{"id" => &1.id, "base" => &1.base, "head" => &1.head}),
      "changed" =>
        Enum.map(
          d.changed,
          &%{"id" => &1.id, "base" => &1.base, "head" => &1.head, "summary" => &1.summary}
        ),
      "unchanged" => d.unchanged
    }

    json = payload |> Jason.encode!() |> String.replace("</", "<\\/")

    # Inject the static shared assets first; the recorded JSON payload goes in
    # LAST so nothing scans over it and corrupts data that happens to contain a
    # placeholder literal.
    template()
    |> String.replace("__SHARED_CSS__", TestLens.Assets.css())
    |> String.replace("__SHARED_JS__", TestLens.Assets.js())
    |> String.replace("__HLJS__", TestLens.Assets.hljs())
    |> String.replace("__DIFF_JSON__", json)
  end

  defp header_meta(run) do
    m = run.meta || %{}

    %{
      "run_id" => m["run_id"],
      "run_at" => m["run_at"],
      "project" => m["project"],
      "git" => m["git"] || %{},
      "status_counts" => m["status_counts"] || %{},
      "case_count" => m["case_count"] || map_size(run.cases),
      "dir" => Path.expand(run.dir)
    }
  end

  defp template do
    ~S"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Test Lens — Diff</title>
    <style>
      :root {
        --bg: #090b10; --bg-2: #0c0f16; --panel: #11151e; --panel-2: #161b27;
        --line: #222a38; --line-2: #2c3445; --text: #e9ecf3; --muted: #8a93a6;
        --faint: #5a6378;
        --gold: #f4b740;
        --pass: #45d49a; --fail: #fb6f78; --skip: #6b7488;
        --in: #41c9e3; --act: #a98bff; --out: #fb7faf;
        --ins: #45d49a; --del: #fb6f78; --upd: #f4b740;
        --add: #45d49a; --rem: #fb6f78; --flip: #f4b740; --chg: #a98bff;
        --mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, Consolas, monospace;
        /* Offline by design: local Space Grotesk if present, else a system stack. */
        --display: "Space Grotesk", "Avenir Next", "Segoe UI", system-ui, -apple-system, sans-serif;
      }

      * { box-sizing: border-box; }
      html { height: 100%; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 13.5px/1.55 var(--mono);
        -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
        min-height: 100%;
      }

      /* ---------- instrument header ---------- */
      .bar {
        position: sticky; top: 0; z-index: 5;
        display: flex; align-items: center; gap: 26px; flex-wrap: wrap;
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
      .diffpill {
        font: 600 10.5px/1 var(--display); letter-spacing: 2px; color: var(--gold);
        border: 1px solid rgba(244,183,64,.4); border-radius: 999px; padding: 4px 9px;
        background: rgba(244,183,64,.08);
      }

      /* base ↔ head metadata */
      .compare { display: flex; align-items: stretch; gap: 14px; min-width: 0; flex: 1; }
      .mblock { min-width: 0; }
      .mlabel { font: 600 10px/1 var(--display); letter-spacing: 1.6px; color: var(--faint); margin-bottom: 5px; }
      .mbranch { font: 13px/1.2 var(--mono); color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .mcommit { color: var(--gold); }
      .msub { color: var(--muted); font-size: 11px; margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .msub .dim { color: var(--faint); }
      .arrow { align-self: center; color: var(--faint); font-size: 18px; flex: none; }

      /* count chips */
      .counts { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-left: auto; }
      .chip { font: 12px/1 var(--mono); color: var(--muted); border: 1px solid var(--line); border-radius: 999px; padding: 6px 11px; background: var(--panel); white-space: nowrap; }
      .chip b { font: 600 13px var(--display); margin-right: 3px; }
      .chip.added  { color: var(--add); border-color: rgba(69,212,154,.35); }
      .chip.removed{ color: var(--rem); border-color: rgba(251,111,120,.35); }
      .chip.flip   { color: var(--flip); border-color: rgba(244,183,64,.35); }
      .chip.chg    { color: var(--chg); border-color: rgba(169,139,255,.35); }
      .chip.unch   { color: var(--faint); }

      /* ---------- document ---------- */
      main { max-width: 1180px; margin: 0 auto; padding: 22px 22px 80px; }

      .cat { margin-bottom: 26px; }
      .cat-h { display: flex; align-items: center; gap: 10px; padding: 6px 2px 12px; border-bottom: 1px solid var(--line); margin-bottom: 8px; position: sticky; top: 56px; background: var(--bg); z-index: 2; }
      .cat-h .dot { width: 9px; height: 9px; border-radius: 50%; flex: none; }
      .cat.added  .dot { background: var(--add); box-shadow: 0 0 8px rgba(69,212,154,.5); }
      .cat.removed .dot { background: var(--rem); box-shadow: 0 0 8px rgba(251,111,120,.5); }
      .cat.flip   .dot { background: var(--flip); box-shadow: 0 0 8px rgba(244,183,64,.5); }
      .cat.chg    .dot { background: var(--chg); box-shadow: 0 0 8px rgba(169,139,255,.5); }
      .cat-h h2 { margin: 0; font: 600 14px/1 var(--display); letter-spacing: .4px; }
      .cat-h .cn { font: 600 12px var(--display); color: var(--faint); background: var(--panel-2); border: 1px solid var(--line); border-radius: 999px; padding: 2px 9px; }

      .entry { border: 1px solid var(--line); border-radius: 10px; background: var(--bg-2); margin-bottom: 7px; overflow: hidden; }
      .trow {
        width: 100%; appearance: none; background: transparent; border: 0; text-align: left;
        cursor: pointer; display: flex; align-items: center; gap: 10px;
        padding: 11px 14px; color: var(--text); font: 13px var(--mono);
        transition: background .1s;
      }
      .trow:hover { background: rgba(255,255,255,.025); }
      .trow.open { background: rgba(255,255,255,.04); }
      .caret { color: var(--faint); transition: transform .14s; display: inline-block; width: 11px; text-align: center; flex: none; }
      .trow.open .caret { transform: rotate(90deg); }
      .g { width: 3px; height: 15px; border-radius: 2px; flex: none; background: var(--faint); }
      .g.pass { background: var(--pass); } .g.fail { background: var(--fail); box-shadow: 0 0 7px rgba(251,111,120,.6); } .g.skip { background: var(--skip); }
      .rn { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .rn .rmod { color: var(--faint); }
      .rright { display: flex; align-items: center; gap: 8px; flex: none; }
      .st { text-transform: uppercase; letter-spacing: .5px; font-weight: 600; font-size: 10.5px; }
      .st.pass { color: var(--pass); } .st.fail { color: var(--fail); } .st.skip { color: var(--skip); }
      .flip-arrow { color: var(--faint); }
      .ptag { font-size: 10px; letter-spacing: .6px; text-transform: uppercase; font-weight: 600; border-radius: 999px; padding: 3px 9px; }
      .ptag.add { color: var(--add); background: rgba(69,212,154,.12); border: 1px solid rgba(69,212,154,.3); }
      .ptag.rem { color: var(--rem); background: rgba(251,111,120,.12); border: 1px solid rgba(251,111,120,.3); }
      .chip-sm { font-size: 10.5px; color: var(--muted); background: var(--panel-2); border: 1px solid var(--line); border-radius: 5px; padding: 2px 7px; }
      .chip-sm.act { color: var(--chg); border-color: rgba(169,139,255,.3); }

      .tpanel { padding: 4px 14px 16px; border-top: 1px solid var(--line); }
      .tpanel[hidden] { display: none; }

      .chgsum { color: var(--muted); font-size: 12px; margin: 12px 0 4px; }
      .chgsum .dim { color: var(--faint); }
      .cclist { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 6px; }
      .cc { font: 11.5px var(--mono); border-radius: 6px; padding: 3px 8px; border: 1px solid var(--line); }
      .cc.add { color: var(--add); background: rgba(69,212,154,.1); border-color: rgba(69,212,154,.3); }
      .cc.rem { color: var(--rem); background: rgba(251,111,120,.1); border-color: rgba(251,111,120,.3); }

      .sides { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; margin-top: 12px; }
      .sides.one { grid-template-columns: minmax(0, 1fr); }
      /* Each side is the query container for its own phase columns, so a narrow
         side (two side by side, or the iframe) stacks its channels full-width. */
      .side { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); padding: 13px 15px 16px; min-width: 0; container: bench / inline-size; }
      .side-h { display: flex; align-items: baseline; gap: 9px; flex-wrap: wrap; padding-bottom: 11px; border-bottom: 1px solid var(--line); margin-bottom: 4px; }
      .slabel { font: 600 11px/1 var(--display); letter-spacing: 1.6px; color: var(--gold); }
      .side-h .dim { color: var(--faint); font-size: 11px; }

      /* the refraction beam: shown only when the columns are side by side */
      .beam { display: none; gap: 0; position: relative; margin: 16px 0 0; height: 26px;
        grid-template-columns: repeat(var(--cols, 3), minmax(0, 1fr)); }
      .beam::before { content: ""; position: absolute; left: 8%; right: 8%; top: 12px; height: 2px;
        background: linear-gradient(90deg, var(--in), var(--act), var(--out)); opacity: .55; border-radius: 2px; }
      .ap { display: flex; align-items: center; justify-content: center; position: relative; }
      .ring { width: 12px; height: 12px; border-radius: 50%; background: var(--bg); position: relative; z-index: 1; box-shadow: 0 0 0 2px currentColor, 0 0 12px currentColor; }
      .ap.in { color: var(--in); } .ap.act { color: var(--act); } .ap.out { color: var(--out); }

      .axis { display: grid; gap: 12px; margin-top: 12px; align-items: start; grid-template-columns: minmax(0, 1fr); }
      @container bench (min-width: 1100px) {
        .beam { display: grid; }
        .axis { margin-top: 4px; grid-template-columns: repeat(var(--cols, 3), minmax(0, 1fr)); }
      }
      /* Each channel is its own query container so a collapsed source row reacts
         to the column width; overflow visible keeps the source peek unclipped. */
      .chan { border: 1px solid var(--line); border-radius: 12px; background: var(--bg-2); overflow: visible; min-width: 0; container: bench / inline-size; }
      .chan-h { display: flex; align-items: center; gap: 8px; padding: 10px 13px; font: 600 11px/1 var(--display); letter-spacing: 1.6px; border-bottom: 1px solid var(--line); }
      .chan.in .chan-h { color: var(--in); } .chan.act .chan-h { color: var(--act); } .chan.out .chan-h { color: var(--out); }
      .chan-h .ci { font: 600 10px/1 var(--mono); opacity: .6; letter-spacing: 0; }
      .chan-body { padding: 12px 13px; }
      .chan.in { box-shadow: inset 3px 0 0 -1px var(--in); }
      .chan.act { box-shadow: inset 3px 0 0 -1px var(--act); }
      .chan.out { box-shadow: inset 3px 0 0 -1px var(--out); }

      .item { margin-bottom: 12px; } .item:last-child { margin-bottom: 0; }
      __SHARED_CSS__

      /* ---------- empty state ---------- */
      .empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 16px; color: var(--faint); text-align: center; padding: 90px 40px; }
      .empty .lens { width: 64px; height: 64px; border-radius: 50%;
        background: conic-gradient(from 210deg, var(--in), var(--act), var(--out), var(--in));
        -webkit-mask: radial-gradient(circle 22px at 50% 50%, transparent 96%, #000 100%);
                mask: radial-gradient(circle 22px at 50% 50%, transparent 96%, #000 100%);
        opacity: .5; }
      .empty h2 { margin: 0; font: 600 16px var(--display); color: var(--muted); letter-spacing: .3px; }
      .empty p { margin: 0; font-size: 12.5px; max-width: 360px; }
      .empty b { color: var(--text); }

      @media (max-width: 760px) {
        .sides { grid-template-columns: minmax(0, 1fr); }
        .counts { margin-left: 0; }
      }
    </style>
    </head>
    <body>
      <header class="bar">
        <div class="brand"><span class="mark" aria-hidden="true"></span><span class="word">TEST<i>&middot;</i>LENS</span><span class="diffpill">DIFF</span></div>
        <div class="compare" id="compare"></div>
        <div class="counts" id="counts"></div>
      </header>
      <main id="main"></main>

      <script>__HLJS__</script>
      <script id="data" type="application/json">__DIFF_JSON__</script>
      <script>
      const DIFF = JSON.parse(document.getElementById("data").textContent);

      __SHARED_JS__
      const short = s => s ? esc(String(s).slice(0, 7)) : "&mdash;";

      /* ---------- header ---------- */
      function metaBlock(label, m) {
        const g = m.git || {};
        const branch = g.branch ? esc(g.branch) : "&mdash;";
        return `<div class="mblock">` +
          `<div class="mlabel">${label}</div>` +
          `<div class="mbranch" title="${escA(g.commit || "")}">${branch} <span class="mcommit">${short(g.commit)}</span></div>` +
          `<div class="msub"><span class="dim">run</span> ${esc(m.run_id || "—")} &middot; ` +
            `<span class="dim">at</span> ${esc(m.run_at || "—")} &middot; ` +
            `<span class="dim">merge-base</span> ${short(g.merge_base)}</div>` +
        `</div>`;
      }
      function renderHeader() {
        $("compare").innerHTML = metaBlock("BASE", DIFF.base) +
          `<span class="arrow" aria-hidden="true">&rarr;</span>` + metaBlock("HEAD", DIFF.head);
        const c = DIFF.counts;
        const chips = [
          ["added", c.added, "added"], ["removed", c.removed, "removed"],
          ["flips", c.flipped, "flip"], ["changed", c.changed, "chg"],
          ["unchanged", c.unchanged, "unch"]
        ];
        $("counts").innerHTML = chips.map(([l, n, k]) => `<span class="chip ${k}"><b>${n}</b>${l}</span>`).join("");
      }

      function caseStages(c) {
        const stages = buildStages(c);
        return `<div class="beam" style="--cols:${stages.length}">${stages.map(s => `<div class="ap ${s.key}"><span class="ring"></span></div>`).join("")}</div>` +
          `<div class="axis" style="--cols:${stages.length}">` +
          stages.map(s => `<div class="chan ${s.key}"><div class="chan-h"><span class="ci">${s.idx}</span>${esc(s.label)}</div>` +
            `<div class="chan-body">${s.items.length ? s.items.map(itemHtml).join("") : '<div class="none">nothing captured here</div>'}</div></div>`).join("") +
          `</div>`;
      }
      function sideHtml(label, c) {
        const where = c.file ? esc(c.file) + (c.line ? ":" + esc(String(c.line)) : "") : "";
        const dur = c.duration_us != null ? (c.duration_us / 1000).toFixed(1) + "ms" : "";
        const meta = [where, dur].filter(Boolean).join(" · ");
        return `<div class="side"><div class="side-h"><span class="slabel">${label}</span>` +
          `<span class="st ${kind(c.status)}">${esc(c.status)}</span>` +
          (meta ? `<span class="dim">${meta}</span>` : "") + `</div>${caseStages(c)}</div>`;
      }

      /* ---------- rows ---------- */
      function rowBase(k, name, mod, right) {
        return `<span class="caret" aria-hidden="true">&#9656;</span><span class="g ${k}"></span>` +
          `<span class="rn" title="${escA(mod)} › ${escA(name)}"><span class="rmod">${esc(mod)} &rsaquo; </span>${esc(name)}</span>` +
          `<span class="rright">${right}</span>`;
      }
      const flipRow = x => rowBase(kind(x.head.status), x.head.name, x.head.module,
        `<span class="st ${kind(x.base.status)}">${esc(x.base.status)}</span>` +
        `<span class="flip-arrow">&rarr;</span>` +
        `<span class="st ${kind(x.head.status)}">${esc(x.head.status)}</span>`);
      const addRow = c => rowBase(kind(c.status), c.name, c.module, `<span class="ptag add">added</span>`);
      const remRow = c => rowBase(kind(c.status), c.name, c.module, `<span class="ptag rem">removed</span>`);
      const chgRow = x => {
        const s = x.summary || {}, cap = s.captures || {}, db = s.db_events || {};
        let chips = `<span class="chip-sm act">cap ${cap.base}&rarr;${cap.head}</span>`;
        if (db.base !== db.head) chips += `<span class="chip-sm">db ${db.base}&rarr;${db.head}</span>`;
        return rowBase(kind(x.head.status), x.head.name, x.head.module, chips);
      };

      function changeSummary(s) {
        const cap = s.captures || {}, db = s.db_events || {};
        const cc = (s.capture_changes || []).map(t =>
          `<span class="cc ${t[0] === '+' ? 'add' : 'rem'}">${esc(t)}</span>`).join("");
        return `<div class="chgsum"><span class="dim">captures</span> ${cap.base}&rarr;${cap.head} &middot; ` +
          `<span class="dim">db events</span> ${db.base}&rarr;${db.head}` +
          (cc ? `<div class="cclist">${cc}</div>` : "") + `</div>`;
      }
      function buildPanel(sec, i) {
        if (sec === "flipped") { const x = DIFF.flipped[i]; return `<div class="sides">${sideHtml("BASE", x.base)}${sideHtml("HEAD", x.head)}</div>`; }
        if (sec === "added")   { return `<div class="sides one">${sideHtml("HEAD", DIFF.added[i])}</div>`; }
        if (sec === "removed") { return `<div class="sides one">${sideHtml("BASE", DIFF.removed[i])}</div>`; }
        if (sec === "changed") { const x = DIFF.changed[i]; return changeSummary(x.summary || {}) + `<div class="sides">${sideHtml("BASE", x.base)}${sideHtml("HEAD", x.head)}</div>`; }
        return "";
      }

      function section(key, title, k, list, rowFn) {
        if (!list.length) return "";
        const rows = list.map((x, i) =>
          `<div class="entry"><button class="trow" data-sec="${key}" data-i="${i}">${rowFn(x)}</button>` +
          `<div class="tpanel" hidden></div></div>`).join("");
        return `<section class="cat ${k}"><div class="cat-h"><span class="dot"></span><h2>${title}</h2>` +
          `<span class="cn">${list.length}</span></div>${rows}</section>`;
      }
      function renderMain() {
        const html =
          section("flipped", "Status flips", "flip", DIFF.flipped, flipRow) +
          section("added", "Added", "added", DIFF.added, addRow) +
          section("removed", "Removed", "removed", DIFF.removed, remRow) +
          section("changed", "Changed", "chg", DIFF.changed, chgRow);
        $("main").innerHTML = html ||
          `<div class="empty"><div class="lens"></div><h2>No differences</h2>` +
          `<p>The two runs match on every shared test. <b>${DIFF.counts.unchanged}</b> unchanged.</p></div>`;
      }

      $("main").addEventListener("click", e => {
        const btn = e.target.closest(".trow");
        if (!btn) return;
        const panel = btn.parentElement.querySelector(".tpanel");
        if (panel.dataset.built !== "1") {
          panel.innerHTML = buildPanel(btn.dataset.sec, +btn.dataset.i);
          panel.dataset.built = "1";
        }
        if (panel.hasAttribute("hidden")) {
          panel.removeAttribute("hidden"); btn.classList.add("open");
          hydrateBlocks(panel);
        }
        else { panel.setAttribute("hidden", ""); btn.classList.remove("open"); }
      });

      renderHeader();
      renderMain();
      wireBlocks($("main"));
      </script>
    </body>
    </html>
    """
  end
end
