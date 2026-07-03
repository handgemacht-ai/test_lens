defmodule TestLens.Assets do
  @moduledoc """
  The CSS and JavaScript shared by `TestLens.Viewer` and `TestLens.DiffViewer`.

  Both render self-contained HTML from the same on-disk case format, and both
  paint each test's input -> action -> result refraction with database deltas
  inline. The rules and functions that do that rendering are identical in both
  reports; hoisting them here keeps one source of truth so the two viewers
  cannot drift. Each report supplies its own `:root`, reset, layout and chrome
  around this shared core, and interpolates `css/0` and `js/0` into its template.

  ## XSS discipline (do not weaken)

    * `esc/1` runs on every value before it is placed inside a tag; `escA/1`
      additionally quotes `"` for attribute contexts.
    * `hl/2` escapes first, then injects only our own `span` tags via a single
      combined regex, so tokens can never nest and corrupt each other.
    * The recorded data block is protected separately by the caller rewriting the
      script-closing sequence in the JSON payload before it is embedded.
  """

  @doc """
  The shared stylesheet fragment: the content and refraction rules common to
  both reports (value blocks, database deltas, JSON/SQL/Elixir token colors,
  annotation readout, dolt captures). Rendered output is identical to the rules
  the two reports previously embedded inline.
  """
  @spec css() :: String.t()
  def css do
    ~S"""
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
    """
  end

  @doc """
  The shared page script: the escaping helpers (`$`, `esc`, `escA`, `kind`) and
  the input -> action -> result renderers (`jsonHtml`, `hl`, `annoHtml`,
  `kindRenderers`, `renderValue`, `deltaHtml`, `buildStages`, `itemHtml`, ...).
  Interpolated verbatim into each report's page `script`, ahead of the
  page-specific code that calls it. Behaviour is identical to the copies the two
  reports previously embedded inline.
  """
  @spec js() :: String.t()
  def js do
    ~S"""
      const $ = id => document.getElementById(id);
      const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
      const escA = s => esc(s).replace(/"/g, '&quot;');
      const kind = s => s === "passed" ? "pass" : (s === "skipped" || s === "excluded") ? "skip" : "fail";

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
    """
  end
end
