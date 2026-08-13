defmodule TestLens.Charts do
  @moduledoc """
  Static, self-contained SVG visualizations rendered in Elixir at viewer build
  time and string-substituted into `TestLens.Viewer` and `TestLens.DiffViewer`.

  Every chart is plain inline SVG plus a little HTML chrome: it draws with zero
  JavaScript (no client-side layout, no libraries, no network) so the reports
  keep their hard offline guarantee. Colours come from CSS classes resolved
  against each report's `:root` palette (see `TestLens.Assets.css/0`), so the
  charts stay theme-consistent with the surrounding instrument.

    * `run_summary/1` — a compact pass/fail/skip status bar for the header.
    * `durations/2` — horizontal bars of the slowest N tests.
    * `modules/2` — a per-module pass/fail/skip stacked-bar breakdown.
    * `diff_summary/1` — an added/removed/flipped/changed bar for the diff report.

  ## XSS discipline

  These helpers emit markup directly (unlike the shared JS renderers, which hand
  highlight.js plain values). Test and module names come from arbitrary test
  code, so every user-derived string is passed through `esc/1` before it lands in
  a tag, attribute, `<text>` node or `<title>`. Numbers and the fixed CSS class
  names are ours, never the recorded content.
  """

  @duration_top 12
  @module_top 12

  @dur_w 720
  @dur_row 26
  @dur_pad 8
  @dur_bar_x 300
  @dur_bar_w 360
  @dur_label_chars 40

  @mod_w 720
  @mod_row 24
  @mod_pad 8
  @mod_bar_x 240
  @mod_bar_w 380
  @mod_label_chars 32

  @doc """
  A compact pass/fail/skip bar with a count legend, for the viewer header. An
  empty run degrades to an empty track and a zeroed legend.
  """
  @spec run_summary([map()]) :: String.t()
  def run_summary(cases) do
    {pass, fail, skip} = tally(cases)
    total = pass + fail + skip
    aria = "#{total} tests: #{pass} passed, #{fail} failed, #{skip} skipped"

    bar(
      "tl-runsum",
      [{"tl-seg-pass", pass}, {"tl-seg-fail", fail}, {"tl-seg-skip", skip}],
      total,
      aria,
      [{"pass", "pass", pass}, {"fail", "fail", fail}, {"skip", "skip", skip}],
      ""
    )
  end

  @doc """
  Horizontal bars of the slowest `top` tests by `duration_us`, longest first.
  Each bar carries the test name (truncated with an ellipsis, full name in a
  `<title>`) and its duration in milliseconds. A run with no timing data
  degrades to a short note.
  """
  @spec durations([map()], pos_integer()) :: String.t()
  def durations(cases, top \\ @duration_top) do
    rows =
      cases
      |> Enum.filter(&is_number(&1["duration_us"]))
      |> Enum.sort_by(& &1["duration_us"], :desc)
      |> Enum.take(top)

    case rows do
      [] -> empty("no timing data")
      _ -> duration_svg(rows)
    end
  end

  @doc """
  A per-module breakdown: one absolute stacked bar per module (width by test
  count, segments by pass/skip/fail), sorted failures-first. Only the top `top`
  modules are drawn; any remainder is noted. An empty run degrades to a note.
  """
  @spec modules([map()], pos_integer()) :: String.t()
  def modules(cases, top \\ @module_top) do
    stats =
      cases
      |> Enum.group_by(&to_string(&1["module"] || ""))
      |> Enum.map(fn {mod, cs} ->
        {pass, fail, skip} = tally(cs)
        %{mod: mod, pass: pass, fail: fail, skip: skip, total: pass + fail + skip}
      end)
      |> Enum.sort_by(&{-&1.fail, -&1.total, &1.mod})

    shown = Enum.take(stats, top)

    case shown do
      [] -> empty("no modules")
      _ -> module_svg(shown, length(stats) - length(shown))
    end
  end

  @doc """
  A compact added/removed/flipped/changed bar with a count legend, for the diff
  report. `counts` is the diff's `counts` map (string keys). When nothing
  differs the bar is an empty track and a note is shown.
  """
  @spec diff_summary(map()) :: String.t()
  def diff_summary(counts) do
    added = count(counts, "added")
    removed = count(counts, "removed")
    flipped = count(counts, "flipped")
    changed = count(counts, "changed")
    unchanged = count(counts, "unchanged")
    diffs = added + removed + flipped + changed
    aria = "#{added} added, #{removed} removed, #{flipped} flipped, #{changed} changed"

    bar(
      "tl-runsum tl-diffsum",
      [
        {"tl-seg-add", added},
        {"tl-seg-rem", removed},
        {"tl-seg-flip", flipped},
        {"tl-seg-chg", changed}
      ],
      diffs,
      aria,
      [
        {"add", "added", added},
        {"rem", "removed", removed},
        {"flip", "flipped", flipped},
        {"chg", "changed", changed},
        {"unch", "unchanged", unchanged}
      ],
      if(diffs == 0, do: ~s(<span class="tl-none-note">no differences</span>), else: "")
    )
  end

  # ---------- compact segmented bar (run summary + diff summary) ----------

  defp bar(wrap_class, segments, total, aria, legend_items, note) do
    ~s(<div class="#{wrap_class}">) <>
      ~s(<div class="tl-bar-wrap" role="img" aria-label="#{esc(aria)}">) <>
      seg_svg(segments, total) <>
      ~s(</div>) <>
      legend(legend_items) <>
      note <>
      ~s(</div>)
  end

  defp seg_svg(_segments, total) when total <= 0 do
    ~s(<svg class="tl-segbar" viewBox="0 0 100 8" preserveAspectRatio="none">) <>
      ~s(<rect class="tl-track" x="0" y="0" width="100" height="8"/></svg>)
  end

  defp seg_svg(segments, total) do
    {_, rects} =
      Enum.reduce(segments, {0.0, []}, fn {cls, n}, {x, acc} ->
        w = n / total * 100

        rect =
          if n > 0 do
            ~s(<rect class="#{cls}" x="#{fmt(x)}" y="0" width="#{fmt(w)}" height="8"/>)
          else
            ""
          end

        {x + w, [rect | acc]}
      end)

    ~s(<svg class="tl-segbar" viewBox="0 0 100 8" preserveAspectRatio="none">) <>
      Enum.join(Enum.reverse(rects)) <> ~s(</svg>)
  end

  defp legend(items) do
    keys =
      Enum.map(items, fn {sw, label, n} ->
        ~s(<span class="k"><span class="sw #{sw}"></span>#{n} #{esc(label)}</span>)
      end)

    ~s(<div class="tl-legend">) <> Enum.join(keys) <> ~s(</div>)
  end

  # ---------- slowest-tests chart ----------

  defp duration_svg(rows) do
    maxd = rows |> Enum.map(& &1["duration_us"]) |> Enum.max() |> max(1)
    n = length(rows)
    h = @dur_pad * 2 + n * @dur_row

    bars =
      rows
      |> Enum.with_index()
      |> Enum.map_join(fn {c, i} -> duration_row(c, i, maxd) end)

    svg_open(@dur_w, h, "Slowest #{n} tests by duration") <> bars <> "</svg>"
  end

  defp duration_row(c, i, maxd) do
    y = @dur_pad + i * @dur_row
    baseline = y + 17
    bar_y = y + 7
    bar_w = c["duration_us"] / maxd * @dur_bar_w
    k = TestLens.Status.css_class(c["status"])
    name = to_string(c["name"] || "")
    dur = TestLens.Duration.to_string(c["duration_us"])
    full = "#{c["module"]} › #{name} · #{dur}"

    ~s(<g><title>#{esc(full)}</title>) <>
      ~s(<text class="tl-lbl" x="0" y="#{baseline}">#{esc(truncate(name, @dur_label_chars))}</text>) <>
      ~s(<rect class="tl-track" x="#{@dur_bar_x}" y="#{bar_y}" width="#{@dur_bar_w}" height="12" rx="3"/>) <>
      ~s(<rect class="tl-bar #{k}" x="#{@dur_bar_x}" y="#{bar_y}" width="#{fmt(bar_w)}" height="12" rx="3"/>) <>
      ~s(<text class="tl-val" x="#{@dur_w}" y="#{baseline}" text-anchor="end">#{esc(dur)}</text>) <>
      ~s(</g>)
  end

  # ---------- per-module breakdown ----------

  defp module_svg(stats, extra) do
    maxt = stats |> Enum.map(& &1.total) |> Enum.max() |> max(1)
    n = length(stats)
    tail = if extra > 0, do: 1, else: 0
    h = @mod_pad * 2 + (n + tail) * @mod_row

    bars =
      stats
      |> Enum.with_index()
      |> Enum.map_join(fn {m, i} -> module_row(m, i, maxt) end)

    more =
      if extra > 0 do
        y = @mod_pad + n * @mod_row + 16
        ~s(<text class="tl-more" x="0" y="#{y}">+#{extra} more module#{plural(extra)}</text>)
      else
        ""
      end

    svg_open(@mod_w, h, "Test outcomes by module") <> bars <> more <> "</svg>"
  end

  defp module_row(m, i, maxt) do
    y = @mod_pad + i * @mod_row
    baseline = y + 16
    bar_y = y + 6
    full_w = m.total / maxt * @mod_bar_w
    segs = stacked([{"pass", m.pass}, {"skip", m.skip}, {"fail", m.fail}], m.total, bar_y, full_w)
    title = "#{m.mod}: #{m.pass} passed, #{m.fail} failed, #{m.skip} skipped"

    ~s(<g><title>#{esc(title)}</title>) <>
      ~s(<text class="tl-lbl" x="0" y="#{baseline}">#{esc(truncate(m.mod, @mod_label_chars))}</text>) <>
      ~s(<rect class="tl-track" x="#{@mod_bar_x}" y="#{bar_y}" width="#{@mod_bar_w}" height="12" rx="3"/>) <>
      segs <>
      ~s(<text class="tl-cnt" x="#{@mod_w}" y="#{baseline}" text-anchor="end">#{module_count(m)}</text>) <>
      ~s(</g>)
  end

  defp stacked(parts, total, y, full_w) do
    total = max(total, 1)

    {_, rects} =
      Enum.reduce(parts, {@mod_bar_x * 1.0, []}, fn {cls, n}, {x, acc} ->
        w = n / total * full_w

        rect =
          if n > 0 do
            ~s(<rect class="tl-bar #{cls}" x="#{fmt(x)}" y="#{y}" width="#{fmt(w)}" height="12"/>)
          else
            ""
          end

        {x + w, [rect | acc]}
      end)

    Enum.join(Enum.reverse(rects))
  end

  defp module_count(m) do
    [
      if(m.fail > 0, do: ~s(<tspan class="tl-t-fail">#{m.fail}&#10007;</tspan>)),
      if(m.skip > 0, do: ~s(<tspan class="tl-t-skip">#{m.skip}&#8856;</tspan>)),
      ~s(<tspan class="tl-t-pass">#{m.pass}&#10003;</tspan>)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(~s(<tspan> </tspan>))
  end

  # ---------- shared helpers ----------

  defp svg_open(w, h, label) do
    ~s(<svg class="tl-chart" viewBox="0 0 #{w} #{h}" preserveAspectRatio="xMinYMin meet" ) <>
      ~s(role="img" aria-label="#{esc(label)}">)
  end

  defp empty(msg), do: ~s(<div class="tl-empty">#{esc(msg)}</div>)

  defp tally(cases) do
    Enum.reduce(cases, {0, 0, 0}, fn c, {pass, fail, skip} ->
      case TestLens.Status.css_class(c["status"]) do
        :pass -> {pass + 1, fail, skip}
        :skip -> {pass, fail, skip + 1}
        :fail -> {pass, fail + 1, skip}
      end
    end)
  end

  defp count(counts, key) when is_map(counts) do
    case Map.get(counts, key, 0) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp count(_counts, _key), do: 0

  defp truncate(s, max) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
