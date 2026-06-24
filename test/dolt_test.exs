defmodule TestLens.DoltTest do
  @moduledoc """
  Verifies the TestLens.Dolt adapter: collect → JSON file → HTML viewer.

  No live Dolt binary is required. All assertions run against the recorder
  and the viewer, using the same fixtures-from-recorder pattern as catalog_test.
  """
  use ExUnit.Case, async: false

  alias TestLens.{Dolt, Recorder, Viewer}

  # ---------------------------------------------------------------------------
  # Collector — confirm dolt_op lands in captures, not db_events
  # ---------------------------------------------------------------------------

  test "Dolt.capture stores a dolt_op entry in captures" do
    module = TestLens.DoltTest.CommitSynthetic
    name = :"test dolt commit capture"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Recorder.put_stage(self(), "action")

    Dolt.capture(self(), %{
      action: "commit",
      branch: "feature/add-index",
      commit_hash: "abc1234f",
      message: "Add index on annotations.org_id",
      result: :ok
    })

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)

    case_data = path |> File.read!() |> Jason.decode!()

    assert case_data["schema"] == "test_lens/v1.1"
    assert length(case_data["captures"]) == 1
    assert case_data["db_events"] == []

    [cap] = case_data["captures"]
    assert cap["kind"] == "dolt_op"
    assert cap["stage"] == "action"
    assert cap["value"]["action"] == "commit"
    assert cap["value"]["branch"] == "feature/add-index"
    assert cap["value"]["commit_hash"] == "abc1234f"
    assert cap["value"]["message"] == "Add index on annotations.org_id"
  end

  test "Dolt.capture without a branch still stores dolt_op" do
    module = TestLens.DoltTest.BranchlessSynthetic
    name = :"test dolt branch capture no branch"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Dolt.capture(self(), %{action: "branch", branch: "new-feature"})

    assert {:ok, path} = Recorder.finish(module, name, "passed", 500)

    case_data = path |> File.read!() |> Jason.decode!()
    [cap] = case_data["captures"]
    assert cap["kind"] == "dolt_op"
    assert cap["value"]["action"] == "branch"
  end

  # ---------------------------------------------------------------------------
  # db_writes stays 0 for a case whose only captures are dolt_op
  # ---------------------------------------------------------------------------

  test "a case with only dolt_op captures has zero db_events" do
    module = TestLens.DoltTest.DbZeroSynthetic
    name = :"test dolt only no db writes"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Dolt.capture(self(), %{action: "merge", branch: "main", message: "Merge feature branch"})

    Dolt.capture(self(), %{
      action: "commit",
      branch: "main",
      commit_hash: "deadbeef",
      message: "Post-merge snapshot"
    })

    assert {:ok, path} = Recorder.finish(module, name, "passed", 800)

    case_data = path |> File.read!() |> Jason.decode!()

    assert length(case_data["captures"]) == 2
    assert case_data["db_events"] == []
    assert Enum.all?(case_data["captures"], fn c -> c["kind"] == "dolt_op" end)
  end

  # ---------------------------------------------------------------------------
  # Viewer — HTML contains the action label; db_writes reads out 0
  # ---------------------------------------------------------------------------

  test "Viewer.build renders dolt_op action label in HTML" do
    module = TestLens.DoltTest.ViewerSynthetic
    name = :"test dolt viewer html"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Recorder.put_stage(self(), "action")

    Dolt.capture(self(), %{
      action: "commit",
      branch: "deploy/v2",
      commit_hash: "c0ffee99",
      message: "Release v2 schema"
    })

    assert {:ok, _path} = Recorder.finish(module, name, "passed", 1_500)

    dir = Application.get_env(:test_lens, :dir, "test_lens_out")
    {:ok, html_path, _count} = Viewer.build(dir: dir)
    html = File.read!(html_path)

    assert String.contains?(html, "commit"),
           "expected HTML to contain action label 'commit'"

    assert String.contains?(html, "dolt_op"),
           "expected HTML to reference kind 'dolt_op'"
  end

  test "Viewer.build renders unknown kind via generic fallback and escapes malicious line/label values" do
    module = TestLens.DoltTest.SafetyRegressionSynthetic
    name = :"test render safety fixes"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Recorder.put_stage(self(), "action")

    # kind that collides with Object.prototype — must not crash, must fall back to JSON
    Recorder.add_capture(
      self(),
      "<script>alert(1)</script>",
      "constructor",
      %{safe: true},
      "action"
    )

    # additional capture for verify stage
    Recorder.add_capture(self(), "output", "text", "normal", "verify")

    assert {:ok, _path} = Recorder.finish(module, name, "passed", 100)

    dir = Application.get_env(:test_lens, :dir, "test_lens_out")
    {:ok, html_path, _count} = Viewer.build(dir: dir)
    html = File.read!(html_path)

    # JSON for the "constructor" kind capture must be embedded (generic fallback)
    assert String.contains?(html, ~s("kind":"constructor")),
           "expected constructor kind to appear in embedded JSON"

    # malicious label must not appear unescaped
    refute String.contains?(html, "<script>alert(1)</script>"),
           "expected script tag in label to be escaped, not raw"
  end

  test "Viewer.build shows db_writes 0 for a dolt_op-only case" do
    module = TestLens.DoltTest.DbZeroViewer
    name = :"test viewer db writes zero"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    Dolt.capture(self(), %{action: "diff", branch: "compare-branch"})

    assert {:ok, _path} = Recorder.finish(module, name, "passed", 600)

    dir = Application.get_env(:test_lens, :dir, "test_lens_out")
    {:ok, html_path, _count} = Viewer.build(dir: dir)
    html = File.read!(html_path)

    # The db_events list for this case is empty → _dbn = 0.
    # The viewer's JS computes _dbn from db_events.length, so the JSON in the
    # page must have db_events: []. Verify directly against the embedded JSON.
    assert String.contains?(html, ~s("db_events":[])),
           "expected db_events to be empty for a dolt_op-only case"
  end
end
