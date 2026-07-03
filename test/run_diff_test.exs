defmodule TestLens.RunDiffTest do
  @moduledoc """
  Covers the run-vs-run diff: added/removed detection, status flips, changed
  captures (with the per-run `seq` ignored so re-ordered-but-equal content stays
  unchanged), identical runs producing no changes, and that `build/1` writes both
  `diff.html` and `diff.json`. Also exercises the graceful paths — a run with no
  `meta.json`, an empty run, and a base whose git carries no `merge_base`.

  Fixtures are written straight to disk as the on-disk case format so the diff is
  exercised through its real `load_run/1` reader.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive values — the
  two runs going in, and the categorized diff coming out — so every test's *own*
  rendered page reads as input → action → result with the concrete BASE/HEAD
  identities and the added/removed/flipped/changed values it asserts on. The diff
  under test operates only on the on-disk temp fixtures, never on this test's live
  recording, so the annotations cannot distort what is verified.
  """
  use ExUnit.Case, async: false
  use TestLens.Case
  require TestLens

  alias TestLens.{Diff, DiffViewer, ViewerCase}

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
    TestLens.setup "two runs sharing M::kept; BASE also has M::gone, HEAD also has M::fresh" do
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

      # The two run identities the diff is asked to reconcile.
      TestLens.capture(
        "runs under diff (identities)",
        %{"base" => ["M::kept", "M::gone"], "head" => ["M::kept", "M::fresh"]},
        annotate: [["base"], ["head"]]
      )
    end

    TestLens.action "compute the run-vs-run diff" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "HEAD-only test is added, BASE-only test is removed, shared one is unchanged" do
      assert Enum.map(diff.added, &Diff.identity/1) == ["M::fresh"]
      assert Enum.map(diff.removed, &Diff.identity/1) == ["M::gone"]
      assert diff.flipped == []
      assert diff.changed == []
      assert diff.unchanged == 1

      # The verified outcome: which identities landed in which bucket.
      TestLens.capture(
        "diff by identity",
        %{
          "added" => Enum.map(diff.added, &Diff.identity/1),
          "removed" => Enum.map(diff.removed, &Diff.identity/1),
          "unchanged" => diff.unchanged
        },
        annotate: [["added"], ["removed"], ["unchanged"]]
      )
    end
  end

  test "detects a status flip (passed -> failed) as a flip, not a change" do
    TestLens.setup "one shared test M::t whose status AND captures both move between the runs" do
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

      # Both the status and the capture value differ; the flip wins over the change.
      TestLens.capture(
        "M::t across the runs",
        %{
          "base" => %{"status" => "passed", "action/a" => "x"},
          "head" => %{"status" => "failed", "action/a" => "y"}
        },
        annotate: [["base", "status"], ["head", "status"]]
      )
    end

    TestLens.action "compute the diff" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "M::t is a flip carrying both statuses; nothing is a plain change" do
      assert [%{id: "M::t", base: b, head: h}] = diff.flipped
      assert b["status"] == "passed"
      assert h["status"] == "failed"
      assert diff.changed == []
      assert diff.unchanged == 0

      # The verified outcome: one flip record, passed -> failed.
      TestLens.capture(
        "flip record",
        %{"id" => "M::t", "base_status" => b["status"], "head_status" => h["status"]},
        annotate: [["base_status"], ["head_status"]]
      )
    end
  end

  test "detects changed captures when status is unchanged" do
    TestLens.setup "M::t stays 'passed' but HEAD grows a second capture (verify/extra)" do
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

      # Same status; the captured content is what moved.
      TestLens.capture(
        "captures per side",
        %{"base" => ["action/resp=200"], "head" => ["action/resp=200", "verify/extra=z"]},
        annotate: [["base"], ["head"]]
      )
    end

    TestLens.action "compute the diff" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "M::t is a content change: capture count 1 -> 2, verify/extra added" do
      assert [%{id: "M::t", summary: summary}] = diff.changed
      assert summary["captures"] == %{"base" => 1, "head" => 2}
      assert "+ verify/extra" in summary["capture_changes"]
      assert diff.flipped == []
      assert diff.unchanged == 0

      # The verified outcome: the change summary the row draws from.
      TestLens.capture("change summary", summary, annotate: [["captures"], ["capture_changes"]])
    end
  end

  test "a different capture value is reported as a removed + added pair" do
    TestLens.setup "M::t keeps its status; the same capture action/resp moves 200 -> 500" do
      root = tmp_dir()

      base =
        write_run(Path.join(root, "base"), [
          mk_case("M", "t", "passed", captures: [cap("action", "resp", "200")])
        ])

      head =
        write_run(Path.join(root, "head"), [
          mk_case("M", "t", "passed", captures: [cap("action", "resp", "500")])
        ])

      # One capture, one changed value — the diff has no "modified" bucket for this.
      TestLens.capture(
        "action/resp value across the runs",
        %{"label" => "action/resp", "base_value" => "200", "head_value" => "500"},
        annotate: [["base_value"], ["head_value"]]
      )
    end

    TestLens.action "compute the diff" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "the changed value shows as a '- action/resp' plus a '+ action/resp' pair" do
      assert [%{summary: summary}] = diff.changed
      assert "- action/resp" in summary["capture_changes"]
      assert "+ action/resp" in summary["capture_changes"]

      # The verified outcome: the removed + added pair standing in for a value change.
      TestLens.capture("capture_changes", summary["capture_changes"], annotate: [[0], [1]])
    end
  end

  test "identical runs produce no changes (seq and duration are ignored)" do
    TestLens.setup "same two tests both sides, but with different per-run seq and duration_us" do
      root = tmp_dir()

      base =
        write_run(Path.join(root, "base"), [
          mk_case("M", "a", "passed",
            captures: [cap("action", "x", "1", seq: 3)],
            duration_us: 1000
          ),
          mk_case("M", "b", "failed",
            captures: [cap("setup", "y", "2", seq: 7)],
            duration_us: 2000
          )
        ])

      # Same content, but different per-run seq values and durations: must be unchanged.
      head =
        write_run(Path.join(root, "head"), [
          mk_case("M", "a", "passed",
            captures: [cap("action", "x", "1", seq: 11)],
            duration_us: 9999
          ),
          mk_case("M", "b", "failed",
            captures: [cap("setup", "y", "2", seq: 0)],
            duration_us: 50
          )
        ])

      # The content is identical; only the volatile ordering/timing fields differ,
      # and those are exactly what the diff ignores.
      TestLens.capture(
        "identical content, differing volatile fields",
        %{
          "content" => "same captures, same statuses both sides",
          "seq" => %{"base" => [3, 7], "head" => [11, 0]},
          "duration_us" => %{"base" => [1000, 2000], "head" => [9999, 50]}
        },
        annotate: [["seq"], ["duration_us"]]
      )
    end

    TestLens.action "compute the diff" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "every bucket is empty; both tests count as unchanged" do
      assert diff.added == []
      assert diff.removed == []
      assert diff.flipped == []
      assert diff.changed == []
      assert diff.unchanged == 2

      # The verified outcome: no differences, two unchanged tests.
      TestLens.capture(
        "diff buckets",
        %{
          "added" => [],
          "removed" => [],
          "flipped" => [],
          "changed" => [],
          "unchanged" => diff.unchanged
        },
        annotate: [["unchanged"]]
      )
    end
  end

  test "build/1 writes diff.html and diff.json with counts and schema" do
    TestLens.setup "BASE {kept:passed, gone}; HEAD {kept:failed, fresh} — one of each category" do
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

      TestLens.capture(
        "runs under diff (with statuses)",
        %{
          "base" => %{"M::kept" => "passed", "M::gone" => "passed"},
          "head" => %{"M::kept" => "failed", "M::fresh" => "passed"}
        },
        annotate: [["base"], ["head"]]
      )
    end

    TestLens.action "build the diff — writes diff.html and diff.json under the HEAD run dir" do
      assert {:ok, html, json, _diff} = Diff.build(base: base, head: head)
    end

    TestLens.verify "both files exist; diff.json carries the schema and per-category counts" do
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

      # The verified outcome: where the artifacts landed and the counts they carry.
      TestLens.capture(
        "written artifacts",
        %{
          "html" => html,
          "json" => json,
          "schema" => data["schema"],
          "counts" => data["counts"]
        },
        annotate: [["html"], ["json"], ["counts"], ["schema"]]
      )
    end
  end

  test "the rendered diff HTML embeds each category's rows and their values" do
    TestLens.setup "one fixture per category: changed / added / flipped / unchanged" do
      root = tmp_dir()

      base =
        write_run(Path.join(root, "base"), [
          mk_case("M", "kept", "passed", captures: [cap("action", "resp", "200")]),
          mk_case("M", "gone", "passed"),
          mk_case("M", "flip", "passed", captures: [cap("action", "a", "x")]),
          mk_case("M", "same", "passed", captures: [cap("verify", "v", "1")])
        ])

      head =
        write_run(Path.join(root, "head"), [
          # same status, an extra capture -> changed
          mk_case("M", "kept", "passed",
            captures: [cap("action", "resp", "200"), cap("verify", "extra", "z")]
          ),
          # new identity -> added
          mk_case("M", "fresh", "passed"),
          # status moved -> flipped
          mk_case("M", "flip", "failed", captures: [cap("action", "a", "x")]),
          # identical -> unchanged (count only)
          mk_case("M", "same", "passed", captures: [cap("verify", "v", "1")])
        ])

      # Which fixture is meant to fall into which diff category.
      TestLens.capture(
        "fixture -> expected category",
        %{
          "changed" => "M::kept",
          "added" => "M::fresh",
          "removed" => "M::gone",
          "flipped" => "M::flip",
          "unchanged" => "M::same"
        },
        annotate: [["changed"], ["added"], ["removed"], ["flipped"], ["unchanged"]]
      )
    end

    TestLens.action "compute the diff and render it to a self-contained HTML document" do
      diff = Diff.compute(base, head)
      html = DiffViewer.render(diff)
    end

    TestLens.verify "the embedded payload carries each category's rows with their values" do
      # Rendered structure: a real document carrying the payload the rows draw from.
      assert html =~ "<!doctype html>"
      assert html =~ ~s(<script id="data" type="application/json">)

      payload = ViewerCase.data_payload(html)

      assert payload["counts"] == %{
               "added" => 1,
               "removed" => 1,
               "flipped" => 1,
               "changed" => 1,
               "unchanged" => 1
             }

      # added row: the HEAD-only case, with its full identity for the row label.
      assert [%{"module" => "M", "name" => "fresh"}] = payload["added"]

      # removed row: the BASE-only case.
      assert [%{"module" => "M", "name" => "gone"}] = payload["removed"]

      # flipped row: both sides, so the row can render passed -> failed.
      assert [flip] = payload["flipped"]
      assert flip["id"] == "M::flip"
      assert flip["base"]["status"] == "passed"
      assert flip["head"]["status"] == "failed"

      # changed row: the content summary plus both full cases, so the panel can
      # draw the extra capture value on the HEAD side.
      assert [changed] = payload["changed"]
      assert changed["id"] == "M::kept"
      assert changed["summary"]["captures"] == %{"base" => 1, "head" => 2}
      assert "+ verify/extra" in changed["summary"]["capture_changes"]

      head_values =
        changed["head"]["captures"] |> Enum.map(& &1["value"]) |> Enum.sort()

      assert head_values == ["200", "z"]

      # The verified outcome: the per-category counts plus the concrete row values
      # the HTML embeds for each bucket.
      TestLens.capture(
        "embedded rows",
        %{
          "counts" => payload["counts"],
          "added" => "M::fresh",
          "removed" => "M::gone",
          "flipped" => "M::flip (passed -> failed)",
          "changed" => %{"id" => "M::kept", "head_capture_values" => head_values}
        },
        annotate: [["counts"], ["changed", "head_capture_values"]]
      )
    end
  end

  test "respects an explicit --out path for the html and writes diff.json beside it" do
    TestLens.setup "a trivial one-test diff and an explicit --out under root/reports/run.html" do
      root = tmp_dir()
      base = write_run(Path.join(root, "base"), [mk_case("M", "t", "passed")])
      head = write_run(Path.join(root, "head"), [mk_case("M", "t", "passed")])
      out = Path.join(root, "reports/run.html")

      TestLens.capture("requested --out path", %{"out" => out}, annotate: [["out"]])
    end

    TestLens.action "build the diff with the explicit --out" do
      assert {:ok, html, json, _diff} = Diff.build(base: base, head: head, out: out)
    end

    TestLens.verify "the HTML honors --out; diff.json is written in the same directory" do
      assert html == Path.expand(out)
      assert json == Path.join(Path.expand(Path.join(root, "reports")), "diff.json")
      assert File.exists?(html)
      assert File.exists?(json)

      # The verified outcome: HTML at the requested path, JSON beside it.
      TestLens.capture(
        "written locations",
        %{"html" => html, "json_beside" => json},
        annotate: [["html"], ["json_beside"]]
      )
    end
  end

  test "handles a run with no meta.json by deriving it from the cases" do
    TestLens.setup "both runs written with meta: :none, so meta.json is absent on disk" do
      root = tmp_dir()
      base = write_run(Path.join(root, "base"), [mk_case("M", "t", "passed")], meta: :none)
      head = write_run(Path.join(root, "head"), [mk_case("M", "t", "failed")], meta: :none)

      TestLens.capture(
        "runs on disk",
        %{
          "meta_json" => "absent (meta: :none)",
          "case_fields" => %{"project" => "p", "cases" => 1}
        },
        annotate: [["meta_json"]]
      )
    end

    TestLens.action "compute the diff, forcing meta to be derived from the case files" do
      diff = Diff.compute(base, head)
    end

    TestLens.verify "meta is reconstructed (project, case_count) from the cases; the flip is still found" do
      assert diff.base.meta["project"] == "p"
      assert diff.base.meta["case_count"] == 1
      assert [%{id: "M::t"}] = diff.flipped

      summary = Diff.summary(diff)
      assert summary["base"]["project"] == "p"
      assert summary["counts"]["base_total"] == 1

      # The verified outcome: the meta values derived from the case files.
      TestLens.capture(
        "derived base meta",
        %{
          "project" => diff.base.meta["project"],
          "case_count" => diff.base.meta["case_count"],
          "base_total" => summary["counts"]["base_total"]
        },
        annotate: [["project"], ["case_count"]]
      )
    end
  end

  test "handles empty runs and a base with no merge_base" do
    TestLens.setup "a one-test BASE whose git.merge_base is nil, against a HEAD with zero tests" do
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
            "git" => %{
              "branch" => "main",
              "commit" => "c",
              "base_ref" => nil,
              "merge_base" => nil
            }
          }
        )

      empty = write_run(Path.join(root, "empty"), [])

      TestLens.capture(
        "edge-case inputs",
        %{"base_tests" => ["M::t"], "head_tests" => [], "base_merge_base" => nil},
        annotate: [["head_tests"], ["base_merge_base"]]
      )
    end

    TestLens.action "compute the diff, then build the artifacts against the empty HEAD" do
      # head empty -> the base test reads as removed; no crash on nil merge_base.
      diff = Diff.compute(base, empty)
    end

    TestLens.verify "the base test reads as removed; build succeeds; nil merge_base survives to diff.json" do
      assert Enum.map(diff.removed, &Diff.identity/1) == ["M::t"]
      assert diff.added == []

      assert {:ok, html, json, _} = Diff.build(base: base, head: empty)
      assert File.exists?(html)
      assert File.exists?(json)
      assert File.read!(json) |> Jason.decode!() |> get_in(["base", "git", "merge_base"]) == nil

      # The verified outcome: no crash, the base test removed, merge_base still nil.
      TestLens.capture(
        "graceful result",
        %{
          "removed" => Enum.map(diff.removed, &Diff.identity/1),
          "added" => diff.added,
          "base_merge_base" => nil
        },
        annotate: [["removed"], ["base_merge_base"]]
      )
    end
  end
end
