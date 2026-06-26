defmodule TestLens.Diff do
  @moduledoc """
  Compare two Test Lens runs (a BASE and a HEAD) and categorize every test by
  what happened to it between them.

  A run is a `runs/<run_id>/` directory holding a `meta.json` (schema
  `test_lens_run/v1`) and one `cases/<slug>.json` per test (schema
  `test_lens/v1.1`). Tests are matched across runs by their stable identity —
  `module + "::" + name` — and sorted into:

    * `:added`   — present in HEAD, absent from BASE
    * `:removed` — present in BASE, absent from HEAD
    * `:flipped` — present in both, **status changed** (e.g. passed → failed)
    * `:changed` — present in both, **same status** but the captured
      input/action/result (`captures` + `db_events`) differs
    * `:unchanged` — present in both, same status, same captured content (count only)

  Status flips take precedence over content changes: a test whose status changed
  is reported as a flip even if its captures also moved.

  Two helpers turn a computed diff into artifacts:

    * `summary/1` — a machine-readable map (schema `test_lens_diff/v1`) of counts
      plus the added/removed/flipped/changed lists, for tools that want the shape
      without parsing HTML;
    * `build/1` — compute, then write a self-contained `diff.html`
      (`TestLens.DiffViewer`) and a sibling `diff.json` (`summary/1`).

  Knows nothing about any project — only the on-disk case format. See `SPEC.md`
  and `docs/diff-format.md` for the contract.
  """

  @diff_schema "test_lens_diff/v1"

  @enforce_keys [:base, :head, :added, :removed, :flipped, :changed, :unchanged]
  defstruct [:base, :head, :added, :removed, :flipped, :changed, :unchanged]

  @typedoc "A loaded run: its directory, its `meta.json` (or one derived from cases), and its cases keyed by identity."
  @type run :: %{dir: String.t(), meta: map(), cases: %{optional(String.t()) => map()}}

  @type t :: %__MODULE__{
          base: run(),
          head: run(),
          added: [map()],
          removed: [map()],
          flipped: [%{id: String.t(), base: map(), head: map()}],
          changed: [%{id: String.t(), base: map(), head: map(), summary: map()}],
          unchanged: non_neg_integer()
        }

  @doc """
  Compute the diff between two run directories. Returns a `%TestLens.Diff{}`.

  Both directories are read leniently: a missing `meta.json` is reconstructed
  from the cases (each carries its own `run_id`/`run_at`/`git`/`project`), and a
  missing or empty `cases/` directory yields an empty run. Comparing a run with
  itself yields only an `:unchanged` count.
  """
  @spec compute(Path.t(), Path.t()) :: t()
  def compute(base_dir, head_dir) do
    base = load_run(base_dir)
    head = load_run(head_dir)

    base_ids = base.cases |> Map.keys() |> MapSet.new()
    head_ids = head.cases |> Map.keys() |> MapSet.new()

    added =
      head_ids
      |> MapSet.difference(base_ids)
      |> Enum.sort()
      |> Enum.map(&Map.fetch!(head.cases, &1))

    removed =
      base_ids
      |> MapSet.difference(head_ids)
      |> Enum.sort()
      |> Enum.map(&Map.fetch!(base.cases, &1))

    {flipped, changed, unchanged} =
      base_ids
      |> MapSet.intersection(head_ids)
      |> Enum.sort()
      |> Enum.reduce({[], [], 0}, fn id, {flips, chgs, unch} ->
        b = Map.fetch!(base.cases, id)
        h = Map.fetch!(head.cases, id)

        cond do
          status(b) != status(h) ->
            {[%{id: id, base: b, head: h} | flips], chgs, unch}

          content(b) != content(h) ->
            {flips, [%{id: id, base: b, head: h, summary: change_summary(b, h)} | chgs], unch}

          true ->
            {flips, chgs, unch + 1}
        end
      end)

    %__MODULE__{
      base: base,
      head: head,
      added: added,
      removed: removed,
      flipped: Enum.reverse(flipped),
      changed: Enum.reverse(changed),
      unchanged: unchanged
    }
  end

  @doc """
  Compute the diff and write both artifacts:

    * a self-contained `diff.html` (default `<head_run_dir>/diff.html`, override
      with `:out`), and
    * a sibling `diff.json` summary, always written next to the HTML.

  Returns `{:ok, html_path, json_path, diff}` with both paths expanded to
  absolute. Options: `:base` (required), `:head` (required), `:out` (optional
  HTML output path).
  """
  @spec build(keyword()) :: {:ok, String.t(), String.t(), t()}
  def build(opts) do
    base_dir = Keyword.fetch!(opts, :base)
    head_dir = Keyword.fetch!(opts, :head)
    diff = compute(base_dir, head_dir)

    html_path = opts[:out] || Path.join(head_dir, "diff.html")
    json_path = Path.join(Path.dirname(html_path), "diff.json")

    File.mkdir_p!(Path.dirname(html_path))
    File.write!(html_path, TestLens.DiffViewer.render(diff))
    File.write!(json_path, Jason.encode!(summary(diff), pretty: true))

    {:ok, Path.expand(html_path), Path.expand(json_path), diff}
  end

  @doc """
  A machine-readable summary of a computed diff (schema `test_lens_diff/v1`):
  `base`/`head` run metadata, `counts`, and the `added`/`removed`/`flipped`/
  `changed` lists (identities + light per-test fields, no captures). This is what
  is written to `diff.json`.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = d) do
    %{
      "schema" => @diff_schema,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "base" => run_summary(d.base),
      "head" => run_summary(d.head),
      "counts" => %{
        "added" => length(d.added),
        "removed" => length(d.removed),
        "flipped" => length(d.flipped),
        "changed" => length(d.changed),
        "unchanged" => d.unchanged,
        "base_total" => map_size(d.base.cases),
        "head_total" => map_size(d.head.cases)
      },
      "added" => Enum.map(d.added, &case_ref/1),
      "removed" => Enum.map(d.removed, &case_ref/1),
      "flipped" => Enum.map(d.flipped, &flip_ref/1),
      "changed" => Enum.map(d.changed, &changed_ref/1)
    }
  end

  @doc """
  Load a run directory into `%{dir, meta, cases}`. `cases` is a map of identity
  (`module::name`) to the decoded case. A missing `meta.json` is reconstructed
  from the cases; an absent or empty `cases/` yields `%{}`.
  """
  @spec load_run(Path.t()) :: run()
  def load_run(dir) do
    cases =
      dir
      |> Path.join("cases/*.json")
      |> Path.wildcard()
      |> Enum.map(&read_json/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn c -> {identity(c), c} end)

    meta = read_json(Path.join(dir, "meta.json")) || derive_meta(cases)
    %{dir: dir, meta: meta, cases: cases}
  end

  @doc "Stable cross-run identity of a case: `module <> \"::\" <> name`."
  @spec identity(map()) :: String.t()
  def identity(c), do: to_string(c["module"]) <> "::" <> to_string(c["name"])

  # ---- internals ----

  defp read_json(path) do
    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body) do
      data
    else
      _ -> nil
    end
  end

  defp derive_meta(cases) do
    sample = cases |> Map.values() |> List.first() || %{}

    %{
      "schema" => "test_lens_run/v1",
      "run_id" => sample["run_id"],
      "run_at" => sample["run_at"],
      "project" => sample["project"],
      "git" => sample["git"],
      "case_count" => map_size(cases),
      "status_counts" => status_counts(cases)
    }
  end

  defp status_counts(cases) do
    cases
    |> Map.values()
    |> Enum.reduce(%{}, fn c, acc -> Map.update(acc, status(c), 1, &(&1 + 1)) end)
  end

  defp status(c), do: to_string(c["status"])

  # Comparison-stable content: the captured input/action/result, with the
  # per-run global ordering key (`seq`) dropped so the same test compares equal
  # across runs even when other tests shifted its sequence numbers. Wall-clock
  # and duration are deliberately excluded — they always move.
  defp content(c) do
    %{captures: normalize(c["captures"]), db_events: normalize(c["db_events"])}
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &Map.drop(&1, ["seq"]))
  defp normalize(_), do: []

  defp change_summary(b, h) do
    bc = normalize(b["captures"])
    hc = normalize(h["captures"])

    %{
      "captures" => %{"base" => length(bc), "head" => length(hc)},
      "db_events" => %{
        "base" => length(normalize(b["db_events"])),
        "head" => length(normalize(h["db_events"]))
      },
      "capture_changes" => capture_changes(bc, hc)
    }
  end

  # Multiset symmetric difference of the normalized captures, each described as
  # "- <stage>/<label>" (only in base) or "+ <stage>/<label>" (only in head). A
  # value change for the same capture shows as a removed + added pair.
  defp capture_changes(base_caps, head_caps) do
    removed = base_caps -- head_caps
    added = head_caps -- base_caps
    Enum.map(removed, &("- " <> descriptor(&1))) ++ Enum.map(added, &("+ " <> descriptor(&1)))
  end

  defp descriptor(cap) do
    stage = cap["stage"] || "?"
    label = cap["label"] || cap["kind"] || "value"
    "#{stage}/#{label}"
  end

  defp run_summary(run) do
    m = run.meta || %{}

    %{
      "run_id" => m["run_id"],
      "run_at" => m["run_at"],
      "project" => m["project"],
      "case_count" => m["case_count"] || map_size(run.cases),
      "status_counts" => m["status_counts"],
      "git" => m["git"],
      "dir" => Path.expand(run.dir)
    }
  end

  defp case_ref(c) do
    %{
      "id" => identity(c),
      "module" => c["module"],
      "name" => c["name"],
      "status" => c["status"],
      "file" => c["file"],
      "line" => c["line"]
    }
  end

  defp flip_ref(%{base: b, head: h}) do
    %{
      "id" => identity(h),
      "module" => h["module"],
      "name" => h["name"],
      "base_status" => b["status"],
      "head_status" => h["status"],
      "file" => h["file"],
      "line" => h["line"]
    }
  end

  defp changed_ref(%{head: h, summary: s}) do
    %{
      "id" => identity(h),
      "module" => h["module"],
      "name" => h["name"],
      "status" => h["status"],
      "summary" => s
    }
  end
end
