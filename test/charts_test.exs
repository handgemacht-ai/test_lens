defmodule TestLens.ChartsTest do
  @moduledoc """
  Unit-tests the static, server-rendered SVG charts (`TestLens.Charts`) and their
  integration into the two reports. Covers the graceful edges the charts must
  survive — an empty run, a single test, many tests, all-passed vs with-failures,
  and long/hostile test names — plus the escaping discipline: test and module
  names come from arbitrary test code, so nothing user-derived may reach the SVG
  as live markup. The integration tests assert the built HTML actually carries
  the charts (no placeholder left behind).
  """
  use ExUnit.Case, async: true

  alias TestLens.{Charts, Diff, DiffViewer, Viewer}

  defp c(module, name, status, dur \\ 1000) do
    %{"module" => module, "name" => name, "status" => status, "duration_us" => dur}
  end

  describe "run_summary/1" do
    test "an empty run degrades to a zeroed legend and an empty track" do
      html = Charts.run_summary([])
      assert html =~ ~s(class="tl-bar-wrap")
      assert html =~ ~s(class="tl-track")
      assert html =~ "0 pass"
      assert html =~ "0 fail"
      refute html =~ "tl-seg-pass"
    end

    test "counts pass/fail/skip (skipped and excluded both skip) into segments" do
      html =
        Charts.run_summary([
          c("M", "a", "passed"),
          c("M", "b", "failed"),
          c("M", "c", "skipped"),
          c("M", "d", "excluded")
        ])

      assert html =~ "1 pass"
      assert html =~ "1 fail"
      assert html =~ "2 skip"
      assert html =~ "tl-seg-pass"
      assert html =~ "tl-seg-fail"
      assert html =~ "tl-seg-skip"
    end

    test "an all-passed run draws only a pass segment" do
      html = Charts.run_summary([c("M", "a", "passed"), c("M", "b", "passed")])
      assert html =~ "2 pass"
      assert html =~ "tl-seg-pass"
      refute html =~ "tl-seg-fail"
      refute html =~ "tl-seg-skip"
    end
  end

  describe "durations/2" do
    test "a run with no timing data degrades to a note" do
      assert Charts.durations([%{"module" => "M", "name" => "t", "status" => "passed"}]) =~
               "no timing data"
    end

    test "a single test renders one bar and its millisecond label" do
      html = Charts.durations([c("M", "t", "passed", 2500)])
      assert html =~ ~s(class="tl-chart")
      assert html =~ "2.5ms"
      assert html =~ "tl-bar pass"
    end

    test "orders slowest-first and caps at the top N" do
      cases = for i <- 1..20, do: c("M", "t#{i}", "passed", i * 1000)
      html = Charts.durations(cases, 5)

      assert html =~ "20.0ms"
      refute html =~ "1.0ms"
      assert (html |> String.split("<g>") |> length()) - 1 == 5
    end

    test "a failing test yields a fail-coloured bar" do
      assert Charts.durations([c("M", "t", "failed", 1000)]) =~ "tl-bar fail"
    end

    test "truncates a long name with an ellipsis but keeps the full name in the title" do
      long = String.duplicate("n", 120)
      html = Charts.durations([c("M", long, "passed", 1000)])
      assert html =~ "…"
      assert html =~ "<title>M › " <> long
    end

    test "escapes markup in the name and module (no raw injection)" do
      html = Charts.durations([c("M<x>", "a<script>alert(1)</script>", "passed", 1000)])
      refute html =~ "<script>alert"
      assert html =~ "a&lt;script&gt;"
      assert html =~ "M&lt;x&gt;"
    end
  end

  describe "modules/2" do
    test "an empty run degrades to a note" do
      assert Charts.modules([]) =~ "no modules"
    end

    test "groups by module with pass/fail counts and stacked segments" do
      html = Charts.modules([c("A", "1", "passed"), c("A", "2", "failed"), c("B", "1", "passed")])
      assert html =~ "tl-bar pass"
      assert html =~ "tl-bar fail"
      assert html =~ "1&#10007;"
      assert html =~ "1&#10003;"
    end

    test "sorts the module with the most failures first" do
      html =
        Charts.modules([
          c("Clean", "1", "passed"),
          c("Broken", "1", "failed"),
          c("Broken", "2", "failed")
        ])

      {broken, _} = :binary.match(html, "Broken")
      {clean, _} = :binary.match(html, "Clean")
      assert broken < clean
    end

    test "notes the modules beyond the cap" do
      cases = for i <- 1..15, do: c("Mod#{i}", "t", "passed")
      assert Charts.modules(cases, 12) =~ "+3 more modules"
    end

    test "escapes module names" do
      assert Charts.modules([c("M<b>&", "t", "passed")]) =~ "M&lt;b&gt;&amp;"
    end
  end

  describe "diff_summary/1" do
    test "no differences degrades to a note and an empty track" do
      html =
        Charts.diff_summary(%{
          "added" => 0,
          "removed" => 0,
          "flipped" => 0,
          "changed" => 0,
          "unchanged" => 7
        })

      assert html =~ "no differences"
      assert html =~ ~s(class="tl-track")
      assert html =~ "7 unchanged"
      refute html =~ "tl-seg-add"
    end

    test "emits a segment and a legend entry per non-zero category" do
      html =
        Charts.diff_summary(%{
          "added" => 2,
          "removed" => 1,
          "flipped" => 3,
          "changed" => 1,
          "unchanged" => 4
        })

      assert html =~ "tl-seg-add"
      assert html =~ "tl-seg-rem"
      assert html =~ "tl-seg-flip"
      assert html =~ "tl-seg-chg"
      assert html =~ "2 added"
      assert html =~ "3 flipped"
      refute html =~ "no differences"
    end

    test "tolerates an empty counts map" do
      assert Charts.diff_summary(%{}) =~ "no differences"
    end
  end

  describe "viewer and diff-viewer integration" do
    test "the built viewer HTML embeds the header summary and both overview charts" do
      root = write_workspace([c("M", "fast", "passed", 500), c("M", "slow", "failed", 9000)])
      {:ok, out, 2} = Viewer.build(dir: root)
      html = File.read!(out)

      assert html =~ ~s(class="run-chart")
      assert html =~ ~s(class="overview")
      assert html =~ "Slowest tests"
      assert html =~ "By module"
      assert html =~ ~s(aria-label="Test outcomes by module")
      assert html =~ "tl-bar fail"

      refute html =~ "__RUN_SUMMARY__"
      refute html =~ "__DURATION_CHART__"
      refute html =~ "__MODULE_CHART__"
    end

    test "the rendered diff HTML embeds the change-summary chart" do
      base =
        write_run([c("M", "kept", "passed"), c("M", "gone", "passed"), c("M", "flip", "passed")])

      head =
        write_run([c("M", "kept", "passed"), c("M", "flip", "failed"), c("M", "fresh", "passed")])

      html = DiffViewer.render(Diff.compute(base, head))

      assert html =~ ~s(class="diff-overview")
      assert html =~ "Change summary"
      assert html =~ ~s(class="tl-runsum tl-diffsum")
      assert html =~ "1 added"
      assert html =~ "1 removed"
      assert html =~ "1 flipped"
      assert html =~ "tl-seg-add"
      refute html =~ "__DIFF_SUMMARY__"
    end
  end

  defp doc(fields) do
    Map.merge(
      %{
        "schema" => "test_lens/v1.1",
        "run_id" => "run",
        "run_at" => "2026-01-01T00:00:00.000000Z",
        "git" => %{
          "branch" => "m",
          "commit" => "c",
          "base_ref" => "origin/main",
          "merge_base" => "mb"
        },
        "project" => "p",
        "file" => "t.exs",
        "line" => 1,
        "tags" => [],
        "captures" => [],
        "db_events" => []
      },
      fields
    )
  end

  # A flat run directory (cases/ only) for Diff.compute.
  defp write_run(cases) do
    dir = Path.join(System.tmp_dir!(), "tl_charts_run_#{System.unique_integer([:positive])}")
    cases_dir = Path.join(dir, "cases")
    File.mkdir_p!(cases_dir)
    write_cases(cases_dir, cases)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A workspace root (runs/<id>/cases) for Viewer.build.
  defp write_workspace(cases) do
    root = Path.join(System.tmp_dir!(), "tl_charts_ws_#{System.unique_integer([:positive])}")
    run_id = "20260101T000000Z-1"
    write_cases(Path.join([root, "runs", run_id, "cases"]), cases)
    File.write!(Path.join([root, "runs", "latest"]), run_id)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp write_cases(cases_dir, cases) do
    File.mkdir_p!(cases_dir)

    cases
    |> Enum.with_index()
    |> Enum.each(fn {fields, i} ->
      File.write!(Path.join(cases_dir, "c#{i}.json"), Jason.encode!(doc(fields)))
    end)
  end
end
