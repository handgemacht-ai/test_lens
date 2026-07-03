defmodule TestLens.ViewerRenderTest do
  @moduledoc """
  Renders the viewer from small synthetic on-disk runs (written straight to disk
  in the real case format, like run_diff_test) and asserts on the payload the
  page actually renders from:

    * a case present in both the run's `cases/` and a legacy flat `cases/` is
      deduped by identity so it renders once (the run copy winning);
    * a corrupt case file is skipped leniently — the build still succeeds and the
      skip is counted into the page;
    * a case value that literally contains a template placeholder survives
      rendering intact (the data is injected last, after every static
      substitution).

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive values — the
  synthetic run going in, and the deduped/skip-counted/verbatim payload coming
  out — so every test's *own* rendered page reads as input → action → result with
  the concrete files and values it asserts on. The viewer under test is always
  built from an isolated temp `root`, never from this test's live recording, so
  the annotations cannot distort what is verified.
  """
  use ExUnit.Case, async: false
  use TestLens.Case
  require TestLens

  alias TestLens.{Viewer, ViewerCase}

  defp mk_case(module, name, opts \\ []) do
    %{
      "schema" => "test_lens/v1.1",
      "run_id" => opts[:run_id] || "run",
      "run_at" => "2026-06-26T00:00:00.000000Z",
      "project" => opts[:project] || "p",
      "module" => module,
      "name" => name,
      "file" => "test/sample_test.exs",
      "line" => 1,
      "status" => opts[:status] || "passed",
      "tags" => [],
      "duration_us" => 1000,
      "captures" => opts[:captures] || [],
      "db_events" => []
    }
  end

  defp write_json(dir, filename, term) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), Jason.encode!(term))
  end

  test "a case shared by the run and a legacy flat cases/ dir renders once (run copy wins)" do
    TestLens.setup "M::shared written to BOTH the run's cases/ and a legacy flat cases/, each with a different capture value; a run-only M::runonly rounds out the run" do
      root = ViewerCase.tmp_dir("test_lens_dedupe")
      run_id = "20260626T000000Z-1"
      run_cases = Path.join([root, "runs", run_id, "cases"])
      legacy_cases = Path.join(root, "cases")

      # Same identity in both places, different capture value.
      run_copy = mk_case("M", "shared", captures: [cap("action", "which", "from-run")])
      legacy_copy = mk_case("M", "shared", captures: [cap("action", "which", "from-legacy")])

      write_json(run_cases, "shared.json", run_copy)
      write_json(legacy_cases, "shared.json", legacy_copy)
      # a second, run-only case, so the payload is more than one identity
      write_json(run_cases, "only.json", mk_case("M", "runonly"))
      File.write!(Path.join([root, "runs", "latest"]), run_id)

      # The duplicated identity and the two competing copies the build must reconcile.
      TestLens.capture(
        "the duplicated identity and its two competing copies",
        %{
          "identity" => "M::shared",
          "run_copy_value" => "from-run",
          "legacy_copy_value" => "from-legacy",
          "run_only_identity" => "M::runonly"
        },
        annotate: [["identity"], ["run_copy_value"], ["legacy_copy_value"]]
      )
    end

    TestLens.action "build the viewer over the run (dedupes by identity)" do
      {:ok, html_path, count} = Viewer.build(dir: root)
    end

    TestLens.verify "M::shared renders once carrying the run copy's value ('from-run'); count is 2" do
      assert count == 2

      payload = ViewerCase.data_payload(File.read!(html_path))
      ids = Enum.map(payload, &(&1["module"] <> "::" <> &1["name"]))
      assert Enum.sort(ids) == ["M::runonly", "M::shared"]

      shared = Enum.find(payload, &(&1["name"] == "shared"))
      assert [%{"value" => "from-run"}] = shared["captures"]

      # The verified outcome: one row per identity, and the run copy's value won.
      TestLens.capture(
        "what rendered: one row per identity, run copy wins",
        %{
          "rendered_ids" => Enum.sort(ids),
          "shared_value" => hd(shared["captures"])["value"],
          "count" => count
        },
        annotate: [["rendered_ids"], ["shared_value"], ["count"]]
      )
    end
  end

  test "one corrupt case file is skipped leniently: the build succeeds and the skip is counted" do
    TestLens.setup "two valid case files (M::a, M::b) plus one truncated, invalid-JSON file in the run's cases/" do
      root = ViewerCase.tmp_dir("test_lens_corrupt")
      run_id = "20260626T000000Z-2"
      run_cases = Path.join([root, "runs", run_id, "cases"])

      write_json(run_cases, "good_a.json", mk_case("M", "a"))
      write_json(run_cases, "good_b.json", mk_case("M", "b"))
      # a half-written / truncated file: invalid JSON
      corrupt = ~s({"schema": "test_lens/v1.1", "modu)
      File.write!(Path.join(run_cases, "broken.json"), corrupt)
      File.write!(Path.join([root, "runs", "latest"]), run_id)

      # Two valid files and one unparseable one — the build must tolerate the latter.
      TestLens.capture(
        "the run's files: two valid, one truncated",
        %{
          "valid_files" => ["good_a.json", "good_b.json"],
          "corrupt_file" => "broken.json",
          "corrupt_content" => corrupt
        },
        annotate: [["corrupt_file"], ["corrupt_content"]]
      )
    end

    TestLens.action "build the viewer over the run" do
      {:ok, html_path, count} = Viewer.build(dir: root)
      html = File.read!(html_path)
    end

    TestLens.verify "build succeeds, the two valid cases render, and the corrupt one is counted as 1 skip" do
      # Two good cases rendered; the corrupt one dropped, not fatal.
      assert count == 2
      assert length(ViewerCase.data_payload(html)) == 2
      # the skipped count is threaded into the page for the "unreadable" warning
      assert String.contains?(html, ~s(data-skipped="1"))

      # The verified outcome: valid cases rendered, one file skipped (not fatal).
      TestLens.capture(
        "outcome: valid cases rendered, corrupt file skipped",
        %{"rendered_count" => count, "skipped" => 1, "build" => "succeeded"},
        annotate: [["rendered_count"], ["skipped"], ["build"]]
      )
    end
  end

  test "a case value containing a template placeholder survives rendering intact" do
    TestLens.setup "a recorded value that literally contains the builder's own template tokens (__SKIPPED__, __CASES_JSON__, __SHARED_CSS__, __SHARED_JS__)" do
      root = ViewerCase.tmp_dir("test_lens_placeholder")
      run_id = "20260626T000000Z-3"
      run_cases = Path.join([root, "runs", run_id, "cases"])

      # These are the literal template tokens the builder substitutes. If the data
      # were injected before the static substitutions (the bug the order fix
      # closed), these would be clobbered.
      poison = "count=__SKIPPED__ data=__CASES_JSON__ css=__SHARED_CSS__ js=__SHARED_JS__"

      write_json(
        run_cases,
        "poison.json",
        mk_case("M", "poison", captures: [cap("action", "raw", poison)])
      )

      File.write!(Path.join([root, "runs", "latest"]), run_id)

      # The recorded value is made entirely of the builder's own template tokens.
      TestLens.capture(
        "the recorded value, made of the builder's own template tokens",
        %{"recorded_value" => poison},
        annotate: [["recorded_value"]]
      )
    end

    TestLens.action "build the viewer over the run" do
      {:ok, html_path, _count} = Viewer.build(dir: root)
      html = File.read!(html_path)
    end

    TestLens.verify "the real __SKIPPED__ token substituted to 0, yet the identical tokens inside the value came through verbatim" do
      # The real placeholder was substituted (zero unreadable files)...
      assert String.contains?(html, ~s(data-skipped="0"))
      refute String.contains?(html, ~s(data-skipped="__SKIPPED__"))

      # ...yet the identical tokens inside the recorded value came through verbatim.
      assert [c] = ViewerCase.data_payload(html)
      assert [%{"value" => ^poison}] = c["captures"]

      # The verified outcome: the page's own token substituted, the value untouched.
      TestLens.capture(
        "outcome: template substituted (skipped=0) but the value survived intact",
        %{"data_skipped_marker" => "0", "rendered_value" => hd(c["captures"])["value"]},
        annotate: [["data_skipped_marker"], ["rendered_value"]]
      )
    end
  end

  defp cap(stage, label, value) do
    %{"stage" => stage, "label" => label, "kind" => "text", "value" => value, "seq" => 0}
  end
end
