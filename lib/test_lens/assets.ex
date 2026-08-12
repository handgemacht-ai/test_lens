defmodule TestLens.Assets do
  @moduledoc """
  The CSS and JavaScript shared by `TestLens.Viewer` and `TestLens.DiffViewer`.

  Both render self-contained HTML from the same on-disk case format, and both
  paint each test's input -> action -> result refraction with database deltas
  inline. The rules and functions that do that rendering are identical in both
  reports; hoisting them here keeps one source of truth so the two viewers
  cannot drift. Each report supplies its own `:root`, reset, layout and chrome
  around this shared core, and interpolates `css/0`, `js/0` and `hljs/0` into its
  template.

  ## Syntax highlighting

  JSON, SQL and Elixir are highlighted by a vendored, minimal build of
  [highlight.js](https://highlightjs.org) (core + those three grammars only,
  ~30KB minified) inlined by `hljs/0`. It replaces a hand-rolled regex
  highlighter: hljs ships real grammars (multi-word SQL keywords, Elixir sigils
  and atoms, robust JSON) and escapes untrusted input internally.

  ## XSS discipline (do not weaken)

    * `esc/1` runs on every value before it is placed inside a tag; `escA/1`
      additionally quotes `"` for attribute contexts.
    * `jsonHtml`/`sqlHtml`/`elixirHtml` hand highlight.js the **plain** value —
      never pre-injected HTML. hljs escapes `& < > " '` itself and emits only its
      own `hljs-*` spans, so recorded content cannot become live markup.
    * The recorded data block is protected separately by the caller rewriting the
      script-closing sequence in the JSON payload before it is embedded.
  """

  @hljs_path Path.join([__DIR__, "..", "..", "priv", "highlight.min.js"])
  @external_resource @hljs_path
  @hljs File.read!(@hljs_path)

  @doc """
  The vendored highlight.js bundle (core + json + sql + elixir), minified. Each
  report injects it as its own `<script>` ahead of the shared page script, which
  calls `hljs.highlight/2` at render time. Trusted, first-party code — it carries
  no `</script>` sequence, so it embeds directly.
  """
  @spec hljs() :: String.t()
  def hljs, do: @hljs

  @doc """
  The shared stylesheet fragment: the content and refraction rules common to
  both reports (value blocks, database deltas, the highlight.js token theme,
  collapsible source and clamped code blocks, annotation readout, dolt captures).
  """
  @spec css() :: String.t()
  def css do
    ~S"""
      .ilabel { color: var(--muted); font-size: 11.5px; margin-bottom: 5px; }
      .ilabel b { color: var(--text); font-weight: 600; }
      .none { color: var(--faint); font-style: italic; font-size: 12px; }

      /* Long lines scroll inside their own block; they never wrap mid-token and
         never push the page sideways. */
      pre { margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 8px;
        padding: 9px 11px; overflow: auto; font: 12px/1.55 var(--mono);
        white-space: pre; overflow-wrap: normal; tab-size: 2; }
      .kv { display: grid; grid-template-columns: auto minmax(0,1fr); gap: 2px 12px; font: 12px/1.5 var(--mono); margin: 4px 0; }
      .kv .k { color: var(--muted); }
      .kv > div { min-width: 0; overflow-wrap: anywhere; }
      .httpline { font: 12.5px/1.5 var(--mono); margin-bottom: 7px; overflow-wrap: anywhere; }
      .method { color: var(--act); font-weight: 700; }
      .scode.ok { color: var(--pass); font-weight: 700; } .scode.bad { color: var(--fail); font-weight: 700; }

      .delta { border-radius: 8px; padding: 9px 11px; margin-bottom: 11px; border: 1px solid var(--line); background: var(--bg-2); min-width: 0; }
      .delta-h { display: flex; align-items: center; gap: 8px; font-size: 11.5px; margin-bottom: 7px; }
      .delta .sign { font-weight: 800; width: 15px; height: 15px; display: inline-flex; align-items: center; justify-content: center; border-radius: 4px; font-size: 12px; }
      .delta.ins { border-color: rgba(69,212,154,.4); } .delta.ins .sign { color: var(--ins); background: rgba(69,212,154,.14); }
      .delta.del { border-color: rgba(251,111,120,.4); } .delta.del .sign { color: var(--del); background: rgba(251,111,120,.14); }
      .delta.upd { border-color: rgba(244,183,64,.4); }  .delta.upd .sign { color: var(--upd); background: rgba(244,183,64,.14); }
      .delta .op { font-weight: 700; letter-spacing: .5px; } .delta .src { color: var(--muted); }
      .delta pre { background: var(--bg); }

      /* ---------- highlight.js theme, mapped to the instrument palette ---------- */
      .hljs-attr, .hljs-property { color: #79c0ff; }
      .hljs-string, .hljs-symbol, .hljs-regexp, .hljs-meta .hljs-string { color: #8dd1a6; }
      .hljs-number { color: #f0a45a; }
      .hljs-literal { color: #ff9a8d; }
      .hljs-keyword, .hljs-selector-tag { color: var(--act); font-weight: 600; }
      .hljs-built_in, .hljs-title, .hljs-title.function_, .hljs-title.class_, .hljs-section, .hljs-name, .hljs-type { color: #79c0ff; }
      .hljs-comment { color: var(--muted); font-style: italic; }
      .hljs-meta, .hljs-variable, .hljs-params { color: var(--text); }
      .hljs-punctuation, .hljs-operator { color: var(--muted); }

      /* ---------- clamp: tall code/JSON blocks get a max height + fade + Expand ---------- */
      .block { position: relative; min-width: 0; }
      .block.clamped > pre { max-height: var(--clamp, 300px); }
      .block.open > pre { max-height: none; }
      .block.clamped:not(.open)::after {
        content: ""; position: absolute; left: 1px; right: 1px; bottom: 1px; height: 52px;
        pointer-events: none; border-radius: 0 0 8px 8px;
        background: linear-gradient(180deg, rgba(9,11,16,0), var(--bg) 88%);
      }
      .block-x {
        position: absolute; right: 9px; bottom: 9px; z-index: 2;
        appearance: none; cursor: pointer; font: 600 10.5px/1 var(--mono); letter-spacing: .3px;
        color: var(--muted); background: var(--panel); border: 1px solid var(--line);
        border-radius: 6px; padding: 5px 9px;
      }
      .block-x:hover { color: var(--text); border-color: var(--line-2); }
      .block-x:focus-visible { outline: 2px solid var(--gold); outline-offset: 2px; }

      /* ---------- copied phase source: collapsed summary, peek popover, expand ---------- */
      pre.phase-src { background: var(--bg-2); color: var(--text); border-left: 2px solid var(--line-2); }
      .chan.in pre.phase-src { border-left-color: var(--in); }
      .chan.act pre.phase-src { border-left-color: var(--act); }
      .chan.out pre.phase-src { border-left-color: var(--out); }

      .srcblock { position: relative; margin-bottom: 4px; }
      .src-summary {
        width: 100%; display: flex; align-items: center; gap: 9px; text-align: left;
        appearance: none; cursor: pointer; color: var(--text);
        background: var(--bg-2); border: 1px solid var(--line); border-left: 2px solid var(--line-2);
        border-radius: 8px; padding: 7px 10px; font: 12px var(--mono); min-width: 0; overflow: hidden;
      }
      .chan.in .src-summary { border-left-color: var(--in); }
      .chan.act .src-summary { border-left-color: var(--act); }
      .chan.out .src-summary { border-left-color: var(--out); }
      .src-summary:hover { background: var(--panel); }
      .src-summary:focus-visible { outline: 2px solid var(--gold); outline-offset: 2px; }
      .src-summary .caret { color: var(--faint); flex: none; display: inline-block; width: 9px; text-align: center; }
      .srcblock.open .src-summary .caret { transform: rotate(90deg); }
      .src-tag { flex: none; font: 600 9.5px/1 var(--mono); letter-spacing: .6px; text-transform: uppercase;
        color: var(--muted); background: var(--panel-2); border: 1px solid var(--line); border-radius: 4px; padding: 3px 6px; }
      .src-label { flex: 0 1 auto; min-width: 0; color: var(--text); font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .src-first { flex: 1 1 auto; min-width: 2ch; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .src-where { flex: none; color: var(--faint); font-size: 11px; white-space: nowrap; }
      .src-more { flex: none; color: var(--faint); font-size: 11px; letter-spacing: .2px; }
      .src-summary:hover .src-more { color: var(--muted); }
      /* On a narrow container the file:line drops from the collapsed summary — it
         still shows in the expanded block's toolbar. Keeps the row from overflowing. */
      @container bench (max-width: 560px) { .src-where { display: none; } }

      .src-pop {
        position: absolute; left: 0; right: 0; top: calc(100% + 6px); z-index: 30;
        opacity: 0; visibility: hidden; pointer-events: none;
        border: 1px solid var(--line-2); border-radius: 9px; background: var(--panel);
        box-shadow: 0 12px 34px rgba(0,0,0,.5); padding: 6px; max-height: 260px; overflow: auto;
      }
      .src-pop pre { border: 0; background: transparent; max-height: none; }
      .srcblock:hover > .src-pop, .src-summary:focus-visible ~ .src-pop { opacity: 1; visibility: visible; }
      .srcblock.open > .src-pop { display: none; }
      .src-full[hidden] { display: none; }
      .src-full { margin-top: 6px; }
      .src-tools { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 6px; }
      .src-loc { color: var(--faint); font-size: 11px; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .src-full pre { max-height: 460px; }
      .copy-btn {
        flex: none; appearance: none; cursor: pointer; font: 600 10.5px/1 var(--mono); letter-spacing: .3px;
        color: var(--muted); background: var(--panel-2); border: 1px solid var(--line); border-radius: 6px; padding: 5px 9px;
      }
      .copy-btn:hover { color: var(--text); border-color: var(--line-2); }
      .copy-btn:focus-visible { outline: 2px solid var(--gold); outline-offset: 2px; }

      @media (prefers-reduced-motion: no-preference) {
        .src-summary, .src-pop, .src-summary .caret, .block-x, .copy-btn { transition: opacity .13s ease, background .12s, color .12s, border-color .12s, transform .13s ease; }
        .src-pop { transform: translateY(-4px); }
        .srcblock:hover > .src-pop, .src-summary:focus-visible ~ .src-pop { transform: none; }
      }

      /* ---------- annotation readout ---------- */
      .anno { margin-bottom: 8px; display: flex; flex-direction: column; gap: 5px; min-width: 0; }
      .anno-line {
        display: inline-flex; align-items: baseline; gap: 8px; align-self: flex-start; max-width: 100%;
        border-radius: 7px; padding: 5px 10px; font: 12px/1.4 var(--mono);
        color: var(--gold); background: rgba(244,183,64,.1);
        border: 1px solid rgba(244,183,64,.32); box-shadow: 0 0 10px rgba(244,183,64,.12);
      }
      .anno-path { color: var(--gold); opacity: .85; flex: none; }
      .anno-eq { color: var(--faint); flex: none; }
      .anno-val { color: var(--text); font-weight: 600; min-width: 0; overflow-wrap: anywhere; }
      .anno-line.miss { color: var(--muted); background: var(--panel-2); border-color: var(--line); box-shadow: none; }
      .anno-line.miss .anno-val { color: var(--faint); font-style: italic; font-weight: 400; }
      .hl { border-radius: 3px; padding: 0 2px; background: rgba(244,183,64,.22); box-shadow: 0 0 0 1px rgba(244,183,64,.4); }

      /* ---------- static SVG charts (server-rendered, zero-JS) ----------
         Colours resolve against each report's :root palette, so the charts stay
         theme-consistent with the surrounding instrument. */
      .tl-chart { display: block; width: 100%; max-width: 760px; height: auto; }
      .tl-track { fill: rgba(255,255,255,.05); }
      .tl-bar.pass, .tl-seg-pass { fill: var(--pass); }
      .tl-bar.fail, .tl-seg-fail { fill: var(--fail); }
      .tl-bar.skip, .tl-seg-skip { fill: var(--skip); }
      .tl-seg-add { fill: var(--pass); } .tl-seg-rem { fill: var(--fail); }
      .tl-seg-flip { fill: var(--gold); } .tl-seg-chg { fill: var(--act); }
      .tl-lbl { fill: var(--muted); font: 12px var(--mono); }
      .tl-val, .tl-cnt, .tl-more { fill: var(--faint); font: 11px var(--mono); }
      .tl-t-pass { fill: var(--pass); } .tl-t-fail { fill: var(--fail); } .tl-t-skip { fill: var(--skip); }
      .tl-empty { color: var(--faint); font-style: italic; font-size: 12px; padding: 8px 2px; }

      .tl-runsum { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-width: 0; }
      .tl-bar-wrap { width: 120px; height: 8px; border-radius: 999px; overflow: hidden; flex: none;
        background: rgba(255,255,255,.05); box-shadow: inset 0 0 0 1px var(--line); }
      .tl-bar-wrap .tl-segbar { display: block; width: 100%; height: 100%; }
      .tl-legend { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; font: 11px var(--mono); color: var(--muted); }
      .tl-legend .k { display: inline-flex; align-items: center; gap: 5px; white-space: nowrap; }
      .tl-legend .sw { width: 8px; height: 8px; border-radius: 2px; display: inline-block; flex: none; }
      .tl-legend .sw.pass, .tl-legend .sw.add { background: var(--pass); }
      .tl-legend .sw.fail, .tl-legend .sw.rem { background: var(--fail); }
      .tl-legend .sw.skip { background: var(--skip); }
      .tl-legend .sw.flip { background: var(--gold); }
      .tl-legend .sw.chg { background: var(--act); }
      .tl-legend .sw.unch { background: var(--faint); }
      .tl-none-note { color: var(--faint); font-style: italic; }

      /* ---------- dolt_op capture ---------- */
      .dolt-op { border-radius: 10px; padding: 10px 13px; border: 1px solid rgba(130,100,220,.35); background: rgba(100,60,200,.07); min-width: 0; }
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
      .dolt-msg { font: 13px/1.5 var(--mono); color: var(--text); margin-top: 2px; overflow-wrap: anywhere; }
      .dolt-result { margin-top: 8px; }
    """
  end

  @doc """
  The shared page script: the escaping helpers (`$`, `esc`, `escA`, `kind`), the
  highlight.js-backed renderers (`jsonHtml`, `sqlHtml`, `elixirHtml`,
  `annoHtml`, `kindRenderers`, `renderValue`, `deltaHtml`, `buildStages`,
  `itemHtml`, ...) and the block behaviours (`codeBlock`, `hydrateBlocks`,
  `wireBlocks`, `copyFrom`). Interpolated verbatim into each report's page
  `script`, ahead of the page-specific code that calls it.
  """
  @spec js() :: String.t()
  def js do
    ~S"""
      const $ = id => document.getElementById(id);
      const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
      const escA = s => esc(s).replace(/"/g, '&quot;');
      // highlight.js escapes & < > " ' internally; match it when we splice into its output.
      const escHljs = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#x27;'}[c]));
      // Collapses a case status to the pass/skip/fail CSS class. Pinned 1:1 to
      // TestLens.Status.css_class/1 (Elixir): every status string that module
      // emits resolves to the same class name here, so the server-rendered charts
      // and this client renderer never disagree.
      const kind = s => s === "passed" ? "pass" : (s === "skipped" || s === "excluded") ? "skip" : "fail";

      /* ---------- syntax highlighting (highlight.js, XSS-safe) ----------
         Every helper hands hljs the PLAIN value; hljs escapes it and emits only
         its own <span> tags. We never build highlighted HTML by hand. */
      function hi(code, lang) {
        return hljs.highlight(String(code), { language: lang, ignoreIllegals: true }).value;
      }
      function jsonHtml(v) {
        const s = JSON.stringify(v, null, 2);
        return hi(s === undefined ? "null" : s, "json");
      }
      function sqlHtml(s) { return hi(s, "sql"); }
      function elixirHtml(s) { return hi(s, "elixir"); }

      /* A code/JSON block that clamps to a max height once hydrated (see
         hydrateBlocks): `inner` is already-highlighted HTML or esc()'d text. */
      function codeBlock(inner, cls) {
        return `<div class="block"><pre class="hljs${cls ? " " + cls : ""}">${inner}</pre></div>`;
      }
      const CLAMP_PX = 300;
      // Measure each block once it is on-screen; only genuinely tall ones get the
      // fade + Expand affordance, so short blocks stay plain.
      function hydrateBlocks(root) {
        root.querySelectorAll(".block > pre").forEach(pre => {
          const block = pre.parentElement;
          if (block.dataset.hy === "1") return;
          block.dataset.hy = "1";
          if (pre.scrollHeight > CLAMP_PX + 28) {
            block.classList.add("clamped");
            const btn = document.createElement("button");
            btn.type = "button";
            btn.className = "block-x";
            btn.textContent = "Expand";
            block.appendChild(btn);
          }
        });
      }
      // Copy the plain text of the block a Copy button belongs to.
      function copyFrom(btn) {
        const scope = btn.closest(".src-full") || btn.closest(".block");
        const pre = scope && scope.querySelector("pre");
        const text = pre ? pre.textContent : "";
        const done = () => { const t = btn.dataset.label || btn.textContent; btn.dataset.label = t; btn.textContent = "Copied"; setTimeout(() => { btn.textContent = t; }, 1200); };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done, () => fallbackCopy(text, done));
        } else { fallbackCopy(text, done); }
      }
      function fallbackCopy(text, done) {
        const ta = document.createElement("textarea");
        ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); done(); } catch (e) {}
        document.body.removeChild(ta);
      }
      // Delegate the block/source toggles for a rendered region. Native <button>s
      // already fire on Enter/Space, so click delegation is all it takes.
      function wireBlocks(root) {
        root.addEventListener("click", e => {
          const x = e.target.closest(".block-x");
          if (x) { const b = x.closest(".block"); x.textContent = b.classList.toggle("open") ? "Collapse" : "Expand"; return; }
          const s = e.target.closest(".src-summary");
          if (s) {
            const sb = s.closest(".srcblock");
            const open = sb.classList.toggle("open");
            s.setAttribute("aria-expanded", open ? "true" : "false");
            const full = sb.querySelector(".src-full");
            if (full) full.hidden = !open;
            const more = s.querySelector(".src-more");
            if (more) more.textContent = open ? "Collapse" : "Expand";
            if (open) hydrateBlocks(sb);
            return;
          }
          const cp = e.target.closest(".copy-btn");
          if (cp) copyFrom(cp);
        });
      }

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
      // Highlight the matched leaf keys of each annotation path inside the JSON.
      // hljs renders a JSON key as <span class="hljs-attr">&quot;key&quot;</span>.
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
          const needle = `<span class="hljs-attr">&quot;${escHljs(k)}&quot;</span>`;
          html = html.split(needle).join(`<span class="hl">${needle}</span>`);
        });
        return html;
      }
      function kvHtml(obj) {
        if (!obj || typeof obj !== "object") return "";
        return '<div class="kv">' + Object.entries(obj)
          .map(([k, v]) => `<div class="k">${esc(k)}</div><div>${esc(typeof v === "object" ? JSON.stringify(v) : v)}</div>`).join("") + "</div>";
      }
      // The first line of source worth previewing: skip blanks, bare do/end and comments.
      function firstMeaningfulLine(src) {
        const lines = String(src).split("\n");
        for (const ln of lines) {
          const t = ln.trim();
          if (t && t !== "do" && t !== "end" && !t.startsWith("#")) return t;
        }
        return (lines.find(l => l.trim()) || "").trim();
      }

      /* ---------- kind → renderer registry ----------
         Each entry is a function (value, item) -> HTML string.
         Unknown kinds fall back to the generic JSON block.
      --------------------------------------------------------- */
      const kindRenderers = {
        http_request: v =>
          `<div class="httpline"><span class="method">${esc(v.method)}</span> ${esc(v.path)}</div>` +
          (v.headers ? kvHtml(v.headers) : "") + (v.body ? codeBlock(jsonHtml(v.body)) : ""),

        http_response: v => {
          const cls = String(v.status)[0] >= "4" ? "bad" : "ok";
          return `<div class="httpline">HTTP <span class="scode ${cls}">${esc(v.status)}</span></div>` +
            (v.headers ? kvHtml(v.headers) : "") + (v.body ? codeBlock(jsonHtml(v.body)) : "");
        },

        text: v => codeBlock(esc(v)),

        source: (v, it) => {
          const label = it.label != null && String(it.label).trim() !== "" ? esc(String(it.label)) : "";
          const where = it._file ? esc(it._file) + (it._line ? ":" + esc(String(it._line)) : "") : "";
          const first = esc(firstMeaningfulLine(v));
          const body = elixirHtml(v);
          return `<div class="srcblock">` +
            `<button type="button" class="src-summary" aria-expanded="false">` +
              `<span class="caret" aria-hidden="true">&#9656;</span>` +
              `<span class="src-tag">source</span>` +
              (label ? `<span class="src-label">${label}</span>` : "") +
              `<code class="src-first">${first}</code>` +
              (where ? `<span class="src-where">${where}</span>` : "") +
              `<span class="src-more">Expand</span>` +
            `</button>` +
            `<div class="src-pop" aria-hidden="true"><pre class="hljs phase-src">${body}</pre></div>` +
            `<div class="src-full" hidden>` +
              `<div class="src-tools"><span class="src-loc">${where || label || "block source"}</span>` +
                `<button type="button" class="copy-btn">Copy</button></div>` +
              `<pre class="hljs phase-src">${body}</pre>` +
            `</div>` +
          `</div>`;
        },

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
            ? `<div class="dolt-result">${codeBlock(jsonHtml(v.result))}</div>`
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
        if (it.paths && it.paths.length) return codeBlock(jsonHtmlHighlighted(it.value, it.paths));
        return codeBlock(jsonHtml(it.value));
      }
      function deltaHtml(ev) {
        const op = (ev.op || "").toUpperCase();
        const map = op.startsWith("INSERT") ? ["ins", "&#43;"] : op.startsWith("DELETE") ? ["del", "&#8722;"] : op.startsWith("UPDATE") ? ["upd", "~"] : ["upd", "&middot;"];
        return `<div class="delta ${map[0]}"><div class="delta-h"><span class="sign">${map[1]}</span><span class="op">${esc(ev.op)}</span><span class="src">${esc(ev.source || "")}</span></div>` +
          codeBlock(sqlHtml(ev.sql), "sql") +
          (ev.params && ev.params.length ? `<div class="ilabel">params</div>${codeBlock(jsonHtml(ev.params))}` : "") + "</div>";
      }
      function buildStages(c) {
        const defs = [["setup", "INPUT", "in", "I"], ["action", "ACTION", "act", "II"], ["verify", "RESULT", "out", "III"]];
        const items = { setup: [], action: [], verify: [] };
        // Stamp the case's file:line onto each capture so a collapsed source block
        // can show where the test lives. Does not touch the embedded data payload.
        (c.captures || []).forEach(x => (items[x.stage] || (items[x.stage] = [])).push({ ...x, _t: "cap", _file: c.file, _line: c.line }));
        (c.db_events || []).forEach(x => (items[x.stage] || (items[x.stage] = [])).push({ ...x, _t: "db" }));
        Object.values(items).forEach(a => a.sort((p, q) => (p.seq || 0) - (q.seq || 0)));
        const stages = defs.map(([k, label, key, idx]) => ({ key, label, idx, items: items[k] || [] }));
        Object.keys(items).forEach(k => { if (!["setup", "action", "verify"].includes(k)) stages.push({ key: "act", label: k.toUpperCase(), idx: "&middot;", items: items[k] }); });
        return stages;
      }
      function itemHtml(it) {
        if (it._t === "db") return deltaHtml(it);
        const bare = it.kind === "http_request" || it.kind === "http_response" || it.kind === "source";
        const hasLabel = !bare && it.label != null && String(it.label).trim() !== "";
        const label = hasLabel ? `<div class="ilabel"><b>${esc(it.label)}</b></div>` : "";
        return `<div class="item">${label}${annoHtml(it)}${renderValue(it)}</div>`;
      }
    """
  end
end
