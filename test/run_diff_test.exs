defmodule TestLens.RunDiffTest do
  @moduledoc """
  Covers the run-vs-run diff: added/removed detection, status flips, changed
  captures (with the per-run `seq` ignored so re-ordered-but-equal content stays
  unchanged), identical runs producing no changes, and that `build/1` writes both
  `diff.html` and `diff.json`. Also exercises the graceful paths — a run with no
  `meta.json`, an empty run, and a base whose git carries no `merge_base`.

  Fixtures are written straight to disk as the on-disk case format so the diff is
  exercised through its real `load_run/1` reader.
  """
  use ExUnit.Case, async: true

  alias TestLens.Diff

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "test_lens_diff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp cap(stage, label, value, opts \\ []) do
    %{
      "stage" => stage,
      "label" => label,
      "kind" => "text",
      "value" => value,
      "seq" => opts[:seq] || 0
    }
  end

  defp mk_case(module, name, status, opts \\ []) do
    %{
      "schema" => "test_lens/v1.1",
      "run_id" => opts[:run_id] || "run",
      "run_at" => opts[:run_at] || "2026-06-26T00:00:00.000000Z",
      "git" =>
        opts[:git] ||
          %{
            "branch" => "feat/x",
            "commit" => "abc123",
            "base_ref" => "origin/main",
            "merge_base" => "def456"
          },
      "project" => opts[:project] || "p",
      "module" => module,
      "name" => name,
      "file" => "test/sample_test.exs",
      "line" => opts[:line] || 1,
      "status" => status,
      "tags" => [],
      "duration_us" => opts[:duration_us] || 1000,
      "captures" => opts[:captures] || [],
      "db_events" => opts[:db_events] || []
    }
  end

  # Write a run directory: a meta.json (unless meta: :none) and one case file each.
  defp write_run(dir, cases, opts \\ []) do
    cases_dir = Path.join(dir, "cases")
    File.mkdir_p!(cases_dir)

    cases
    |> Enum.with_index()
    |> Enum.each(fn {c, i} ->
      File.write!(Path.join(cases_dir, "case_#{i}.json"), Jason.encode!(c))
    end)

    unless opts[:meta] == :none do
      meta =
        Map.merge(
          %{
            "schema" => "test_lens_run/v1",
            "run_id" => "run",
            "run_at" => "2026-06-26T00:00:00.000000Z",
            "project" => "p",
            "git" => %{
              "branch" => "feat/x",
              "commit" => "abc123",
              "base_ref" => "origin/main",
              "merge_base" => "def456"
            },
            "case_count" => length(cases),
            "status_counts" => %{}
          },
          opts[:meta] || %{}
        )

      File.write!(Path.join(dir, "meta.json"), Jason.encode!(meta))
    end

    dir
  end

  test "detects added and removed tests by identity" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "kept", "passed"),
        mk_case("M", "gone", "passed")
      ])

    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "kept", "passed"),
        mk_case("M", "fresh", "passed")
      ])

    diff = Diff.compute(base, head)

    assert Enum.map(diff.added, &Diff.identity/1) == ["M::fresh"]
    assert Enum.map(diff.removed, &Diff.identity/1) == ["M::gone"]
    assert diff.flipped == []
    assert diff.changed == []
    assert diff.unchanged == 1
  end

  test "detects a status flip (passed -> failed) as a flip, not a change" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "t", "passed", captures: [cap("action", "a", "x")])
      ])

    # status changed AND captures changed: still classified as a flip
    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "t", "failed", captures: [cap("action", "a", "y")])
      ])

    diff = Diff.compute(base, head)

    assert [%{id: "M::t", base: b, head: h}] = diff.flipped
    assert b["status"] == "passed"
    assert h["status"] == "failed"
    assert diff.changed == []
    assert diff.unchanged == 0
  end

  test "detects changed captures when status is unchanged" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "t", "passed", captures: [cap("action", "resp", "200")])
      ])

    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "t", "passed",
          captures: [cap("action", "resp", "200"), cap("verify", "extra", "z")]
        )
      ])

    diff = Diff.compute(base, head)

    assert [%{id: "M::t", summary: summary}] = diff.changed
    assert summary["captures"] == %{"base" => 1, "head" => 2}
    assert "+ verify/extra" in summary["capture_changes"]
    assert diff.flipped == []
    assert diff.unchanged == 0
  end

  test "a different capture value is reported as a removed + added pair" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "t", "passed", captures: [cap("action", "resp", "200")])
      ])

    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "t", "passed", captures: [cap("action", "resp", "500")])
      ])

    diff = Diff.compute(base, head)

    assert [%{summary: summary}] = diff.changed
    assert "- action/resp" in summary["capture_changes"]
    assert "+ action/resp" in summary["capture_changes"]
  end

  test "identical runs produce no changes (seq and duration are ignored)" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "a", "passed",
          captures: [cap("action", "x", "1", seq: 3)],
          duration_us: 1000
        ),
        mk_case("M", "b", "failed", captures: [cap("setup", "y", "2", seq: 7)], duration_us: 2000)
      ])

    # Same content, but different per-run seq values and durations: must be unchanged.
    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "a", "passed",
          captures: [cap("action", "x", "1", seq: 11)],
          duration_us: 9999
        ),
        mk_case("M", "b", "failed", captures: [cap("setup", "y", "2", seq: 0)], duration_us: 50)
      ])

    diff = Diff.compute(base, head)

    assert diff.added == []
    assert diff.removed == []
    assert diff.flipped == []
    assert diff.changed == []
    assert diff.unchanged == 2
  end

  test "build/1 writes diff.html and diff.json with counts and schema" do
    root = tmp_dir()

    base =
      write_run(Path.join(root, "base"), [
        mk_case("M", "kept", "passed"),
        mk_case("M", "gone", "passed")
      ])

    head =
      write_run(Path.join(root, "head"), [
        mk_case("M", "kept", "failed"),
        mk_case("M", "fresh", "passed")
      ])

    assert {:ok, html, json, _diff} = Diff.build(base: base, head: head)

    assert html == Path.join(Path.expand(head), "diff.html")
    assert json == Path.join(Path.expand(head), "diff.json")
    assert File.exists?(html)
    assert File.exists?(json)

    body = File.read!(html)
    assert body =~ "<!doctype html>"
    assert body =~ ~s(<script id="data" type="application/json">)

    data = json |> File.read!() |> Jason.decode!()
    assert data["schema"] == "test_lens_diff/v1"

    assert data["counts"] == %{
             "added" => 1,
             "removed" => 1,
             "flipped" => 1,
             "changed" => 0,
             "unchanged" => 0,
             "base_total" => 2,
             "head_total" => 2
           }

    assert [%{"id" => "M::fresh"}] = data["added"]
    assert [%{"id" => "M::gone"}] = data["removed"]

    assert [%{"id" => "M::kept", "base_status" => "passed", "head_status" => "failed"}] =
             data["flipped"]

    assert {:ok, _dt, _off} = DateTime.from_iso8601(data["generated_at"])
  end

  test "respects an explicit --out path for the html and writes diff.json beside it" do
    root = tmp_dir()
    base = write_run(Path.join(root, "base"), [mk_case("M", "t", "passed")])
    head = write_run(Path.join(root, "head"), [mk_case("M", "t", "passed")])
    out = Path.join(root, "reports/run.html")

    assert {:ok, html, json, _diff} = Diff.build(base: base, head: head, out: out)
    assert html == Path.expand(out)
    assert json == Path.join(Path.expand(Path.join(root, "reports")), "diff.json")
    assert File.exists?(html)
    assert File.exists?(json)
  end

  test "handles a run with no meta.json by deriving it from the cases" do
    root = tmp_dir()
    base = write_run(Path.join(root, "base"), [mk_case("M", "t", "passed")], meta: :none)
    head = write_run(Path.join(root, "head"), [mk_case("M", "t", "failed")], meta: :none)

    diff = Diff.compute(base, head)
    assert diff.base.meta["project"] == "p"
    assert diff.base.meta["case_count"] == 1
    assert [%{id: "M::t"}] = diff.flipped

    summary = Diff.summary(diff)
    assert summary["base"]["project"] == "p"
    assert summary["counts"]["base_total"] == 1
  end

  test "handles empty runs and a base with no merge_base" do
    root = tmp_dir()

    base =
      write_run(
        Path.join(root, "base"),
        [
          mk_case("M", "t", "passed",
            git: %{"branch" => "main", "commit" => "c", "base_ref" => nil, "merge_base" => nil}
          )
        ],
        meta: %{
          "git" => %{"branch" => "main", "commit" => "c", "base_ref" => nil, "merge_base" => nil}
        }
      )

    empty = write_run(Path.join(root, "empty"), [])

    # head empty -> the base test reads as removed; no crash on nil merge_base.
    diff = Diff.compute(base, empty)
    assert Enum.map(diff.removed, &Diff.identity/1) == ["M::t"]
    assert diff.added == []

    assert {:ok, html, json, _} = Diff.build(base: base, head: empty)
    assert File.exists?(html)
    assert File.exists?(json)
    assert File.read!(json) |> Jason.decode!() |> get_in(["base", "git", "merge_base"]) == nil
  end
end
