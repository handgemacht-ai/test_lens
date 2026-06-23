defmodule TestLens.Viewer do
  @moduledoc """
  Render captured cases into a single self-contained HTML file: per test, the
  input → action → result flow, with database deltas shown inline on the stage
  that caused them. Knows nothing about any project — only the case format.

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
    <title>TestLens</title>
    <style>
      :root {
        --bg: #0d1117; --panel: #161b22; --panel-2: #1c2230; --border: #2d333b;
        --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff;
        --ok: #3fb950; --fail: #f85149; --skip: #d29922; --db: #bc8cff;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
      }
      header {
        padding: 22px 28px; border-bottom: 1px solid var(--border);
        background: linear-gradient(180deg, #11161f, var(--bg));
        position: sticky; top: 0; z-index: 5; backdrop-filter: blur(6px);
      }
      h1 { margin: 0; font-size: 18px; letter-spacing: .3px; }
      h1 span { color: var(--accent); }
      .sub { color: var(--muted); margin-top: 4px; font-size: 12.5px; }
      .controls { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 14px; }
      .chip {
        border: 1px solid var(--border); background: var(--panel); color: var(--text);
        padding: 5px 12px; border-radius: 999px; cursor: pointer; font-size: 12.5px;
        transition: all .15s ease; user-select: none;
      }
      .chip:hover { border-color: var(--accent); transform: translateY(-1px); }
      .chip.active { background: var(--accent); border-color: var(--accent); color: #0d1117; font-weight: 600; }
      main { padding: 24px 28px; max-width: 1200px; margin: 0 auto; }
      .case {
        border: 1px solid var(--border); border-radius: 12px; background: var(--panel);
        margin-bottom: 20px; overflow: hidden; transition: border-color .15s ease;
      }
      .case:hover { border-color: #3d444d; }
      .case-head { display: flex; align-items: center; gap: 12px; padding: 14px 18px; border-bottom: 1px solid var(--border); }
      .dot { width: 10px; height: 10px; border-radius: 50%; flex: none; }
      .dot.passed { background: var(--ok); box-shadow: 0 0 8px var(--ok); }
      .dot.failed { background: var(--fail); box-shadow: 0 0 8px var(--fail); }
      .dot.skipped, .dot.excluded, .dot.invalid, .dot.unknown { background: var(--skip); }
      .case-name { font-weight: 600; font-size: 14.5px; }
      .case-meta { color: var(--muted); font-size: 12px; margin-top: 2px; }
      .badge {
        margin-left: auto; font-size: 11px; padding: 3px 9px; border-radius: 6px;
        background: var(--panel-2); border: 1px solid var(--border); color: var(--muted);
        white-space: nowrap;
      }
      .flow { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 0; }
      .stage { padding: 16px 18px; border-right: 1px solid var(--border); min-width: 0; }
      .stage:last-child { border-right: none; }
      .stage-title {
        font-size: 11px; text-transform: uppercase; letter-spacing: 1.2px; color: var(--muted);
        margin-bottom: 12px; display: flex; align-items: center; gap: 7px;
      }
      .stage-title::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); }
      .stage[data-stage="action"] .stage-title::before { background: var(--skip); }
      .stage[data-stage="verify"] .stage-title::before { background: var(--ok); }
      .item { margin-bottom: 14px; }
      .item:last-child { margin-bottom: 0; }
      .label { font-size: 12px; color: var(--muted); margin-bottom: 5px; }
      .label b { color: var(--text); font-weight: 600; }
      pre {
        margin: 0; background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
        padding: 10px 12px; overflow-x: auto; font: 12px/1.55 ui-monospace, "SF Mono", Menlo, monospace;
        white-space: pre-wrap; word-break: break-word;
      }
      .kv { display: grid; grid-template-columns: auto 1fr; gap: 2px 10px; font: 12px/1.5 ui-monospace, monospace; margin: 4px 0 8px; }
      .kv .k { color: var(--muted); }
      .http-line { font: 12.5px/1.5 ui-monospace, monospace; margin-bottom: 6px; }
      .method { color: var(--skip); font-weight: 700; }
      .status-201, .status-200 { color: var(--ok); font-weight: 700; }
      .status-4, .status-5 { color: var(--fail); font-weight: 700; }
      .db {
        border: 1px dashed var(--db); border-radius: 8px; padding: 9px 11px; margin-bottom: 14px;
        background: rgba(188, 140, 255, .06);
      }
      .db-op { font-size: 11px; font-weight: 700; color: var(--db); letter-spacing: .5px; }
      .db-op .src { color: var(--text); font-weight: 600; }
      .json-key { color: #79c0ff; }
      .json-str { color: #a5d6ff; }
      .json-num { color: #f0883e; }
      .json-bool { color: #ff7b72; }
      .empty { color: var(--muted); font-style: italic; font-size: 12px; }
      footer { color: var(--muted); text-align: center; padding: 20px; font-size: 12px; }
    </style>
    </head>
    <body>
    <header>
      <h1><span>Test</span>Lens</h1>
      <div class="sub">__COUNT__ captured test cases · input → action → result</div>
      <div class="controls" id="filters"></div>
    </header>
    <main id="cases"></main>
    <footer>Rendered from test_lens/v1 case files · one viewer, any project</footer>

    <script id="data" type="application/json">__CASES_JSON__</script>
    <script>
    const CASES = JSON.parse(document.getElementById("data").textContent);
    const STAGE_ORDER = ["setup", "action", "verify"];
    let projectFilter = "all", statusFilter = "all";

    function esc(s){ return String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

    function jsonHtml(v){
      const json = JSON.stringify(v, null, 2);
      return esc(json)
        .replace(/&quot;([^&]+)&quot;(\s*:)/g, '<span class="json-key">"$1"</span>$2')
        .replace(/: (&quot;[^]*?&quot;)(,?)$/gm, ': <span class="json-str">$1</span>$2')
        .replace(/: (-?\d+\.?\d*)(,?)$/gm, ': <span class="json-num">$1</span>$2')
        .replace(/: (true|false|null)(,?)$/gm, ': <span class="json-bool">$1</span>$2');
    }

    function kv(obj){
      if(!obj || typeof obj !== "object") return "";
      return '<div class="kv">' + Object.entries(obj)
        .map(([k,v]) => '<div class="k">'+esc(k)+'</div><div>'+esc(typeof v==="object"?JSON.stringify(v):v)+'</div>')
        .join("") + '</div>';
    }

    function statusClass(code){
      const c = String(code);
      if(c[0]==="4") return "status-4"; if(c[0]==="5") return "status-5"; return "status-"+c;
    }

    function renderValue(item){
      const v = item.value;
      if(item.kind === "http_request"){
        return '<div class="http-line"><span class="method">'+esc(v.method)+'</span> '+esc(v.path)+'</div>'
          + (v.headers ? kv(v.headers) : "")
          + (v.body ? '<pre>'+jsonHtml(v.body)+'</pre>' : "");
      }
      if(item.kind === "http_response"){
        return '<div class="http-line">HTTP <span class="'+statusClass(v.status)+'">'+esc(v.status)+'</span></div>'
          + (v.headers ? kv(v.headers) : "")
          + (v.body ? '<pre>'+jsonHtml(v.body)+'</pre>' : "");
      }
      if(item.kind === "text") return '<pre>'+esc(v)+'</pre>';
      return '<pre>'+jsonHtml(v)+'</pre>';
    }

    function renderDb(ev){
      return '<div class="db"><div class="db-op">'+esc(ev.op)+' <span class="src">'+esc(ev.source||"")+'</span></div>'
        + '<pre>'+esc(ev.sql)+'</pre>'
        + (ev.params && ev.params.length ? '<div class="label">params</div><pre>'+jsonHtml(ev.params)+'</pre>' : '')
        + '</div>';
    }

    function stagesOf(c){
      const items = (c.captures||[]).map(x => ({...x, _t:"cap"}))
        .concat((c.db_events||[]).map(x => ({...x, _t:"db"})));
      const byStage = {};
      for(const it of items){ (byStage[it.stage] = byStage[it.stage] || []).push(it); }
      const names = Object.keys(byStage).sort((a,b) => {
        const ia = STAGE_ORDER.indexOf(a), ib = STAGE_ORDER.indexOf(b);
        return (ia<0?99:ia) - (ib<0?99:ib);
      });
      return names.map(name => {
        const sorted = byStage[name].sort((a,b)=>a.seq-b.seq);
        const body = sorted.map(it => it._t==="db"
          ? renderDb(it)
          : '<div class="item"><div class="label"><b>'+esc(it.label)+'</b></div>'+renderValue(it)+'</div>'
        ).join("");
        return '<div class="stage" data-stage="'+esc(name)+'"><div class="stage-title">'+esc(name)+'</div>'+body+'</div>';
      }).join("");
    }

    function renderCases(){
      const main = document.getElementById("cases");
      const list = CASES.filter(c =>
        (projectFilter==="all" || c.project===projectFilter) &&
        (statusFilter==="all" || c.status===statusFilter));
      if(!list.length){ main.innerHTML = '<p class="empty">No cases match.</p>'; return; }
      main.innerHTML = list.map(c =>
        '<div class="case">'
        + '<div class="case-head"><div class="dot '+esc(c.status)+'"></div>'
        + '<div><div class="case-name">'+esc(c.name)+'</div>'
        + '<div class="case-meta">'+esc(c.module)+' · '+esc(c.file||"")+(c.line?":"+c.line:"")
        + (c.duration_us!=null ? ' · '+(c.duration_us/1000).toFixed(1)+'ms' : '')+'</div></div>'
        + '<div class="badge">'+esc(c.project)+'</div></div>'
        + '<div class="flow">'+stagesOf(c)+'</div>'
        + '</div>'
      ).join("");
    }

    function renderFilters(){
      const projects = ["all", ...new Set(CASES.map(c=>c.project))];
      const statuses = ["all", ...new Set(CASES.map(c=>c.status))];
      const box = document.getElementById("filters");
      const mk = (val, cur, set, prefix) =>
        '<div class="chip'+(val===cur?" active":"")+'" data-set="'+set+'" data-val="'+esc(val)+'">'+prefix+esc(val)+'</div>';
      box.innerHTML = projects.map(p=>mk(p, projectFilter, "project", "project: ")).join("")
        + statuses.map(s=>mk(s, statusFilter, "status", "status: ")).join("");
      box.querySelectorAll(".chip").forEach(ch => ch.onclick = () => {
        if(ch.dataset.set==="project") projectFilter = ch.dataset.val; else statusFilter = ch.dataset.val;
        renderFilters(); renderCases();
      });
    }

    renderFilters();
    renderCases();
    </script>
    </body>
    </html>
    """
  end
end
