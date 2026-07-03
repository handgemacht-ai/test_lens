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
  """
  use ExUnit.Case, async: true

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

    {:ok, html_path, count} = Viewer.build(dir: root)
    assert count == 2

    payload = ViewerCase.data_payload(File.read!(html_path))
    ids = Enum.map(payload, &(&1["module"] <> "::" <> &1["name"]))
    assert Enum.sort(ids) == ["M::runonly", "M::shared"]

    shared = Enum.find(payload, &(&1["name"] == "shared"))
    assert [%{"value" => "from-run"}] = shared["captures"]
  end

  test "one corrupt case file is skipped leniently: the build succeeds and the skip is counted" do
    root = ViewerCase.tmp_dir("test_lens_corrupt")
    run_id = "20260626T000000Z-2"
    run_cases = Path.join([root, "runs", run_id, "cases"])

    write_json(run_cases, "good_a.json", mk_case("M", "a"))
    write_json(run_cases, "good_b.json", mk_case("M", "b"))
    # a half-written / truncated file: invalid JSON
    File.write!(Path.join(run_cases, "broken.json"), ~s({"schema": "test_lens/v1.1", "modu))
    File.write!(Path.join([root, "runs", "latest"]), run_id)

    {:ok, html_path, count} = Viewer.build(dir: root)
    html = File.read!(html_path)

    # Two good cases rendered; the corrupt one dropped, not fatal.
    assert count == 2
    assert length(ViewerCase.data_payload(html)) == 2
    # the skipped count is threaded into the page for the "unreadable" warning
    assert String.contains?(html, ~s(data-skipped="1"))
  end

  test "a case value containing a template placeholder survives rendering intact" do
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

    {:ok, html_path, _count} = Viewer.build(dir: root)
    html = File.read!(html_path)

    # The real placeholder was substituted (zero unreadable files)...
    assert String.contains?(html, ~s(data-skipped="0"))
    refute String.contains?(html, ~s(data-skipped="__SKIPPED__"))

    # ...yet the identical tokens inside the recorded value came through verbatim.
    assert [c] = ViewerCase.data_payload(html)
    assert [%{"value" => ^poison}] = c["captures"]
  end

  defp cap(stage, label, value) do
    %{"stage" => stage, "label" => label, "kind" => "text", "value" => value, "seq" => 0}
  end
end
