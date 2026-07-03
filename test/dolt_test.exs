defmodule TestLens.DoltTest do
  @moduledoc """
  Verifies the TestLens.Dolt adapter: collect → JSON file → HTML viewer.

  No live Dolt binary is required. All assertions run against the recorder
  and the viewer, using the same fixtures-from-recorder pattern as catalog_test.
  """
  use ExUnit.Case, async: false

  alias TestLens.{Dolt, Recorder, ViewerCase}

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

  test "Viewer.build embeds the dolt_op capture payload the renderer draws from" do
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

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_500)

    # Build against an isolated copy of only this case, so the assertions below
    # cannot be satisfied by another test's data — and so they fail on the empty
    # viewer that "commit"/"dolt_op" (CSS classes + JS constants) would pass.
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)
    assert [dolt] = c["captures"]

    assert dolt["kind"] == "dolt_op"
    assert dolt["stage"] == "action"
    assert dolt["value"]["action"] == "commit"
    assert dolt["value"]["branch"] == "deploy/v2"
    assert dolt["value"]["commit_hash"] == "c0ffee99"
    assert dolt["value"]["message"] == "Release v2 schema"

    # The exact bytes the JS reads for the badge/hash/message must be present.
    assert String.contains?(html, ~s("kind":"dolt_op"))
    assert String.contains?(html, ~s("commit_hash":"c0ffee99"))
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

    assert {:ok, path} = Recorder.finish(module, name, "passed", 100)

    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)

    # The Object.prototype-colliding kind falls back to the generic JSON block:
    # it must be embedded verbatim (proving no crash swallowed the capture).
    constructor = Enum.find(c["captures"], &(&1["kind"] == "constructor"))
    assert constructor, "expected the constructor-kind capture in the payload"
    assert constructor["value"] == %{"safe" => true}
    assert String.contains?(html, ~s("kind":"constructor"))

    # malicious label must not appear as a live tag — the </ is neutralized so
    # the browser reads it as JSON text, not markup.
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

    assert {:ok, path} = Recorder.finish(module, name, "passed", 600)

    # The viewer's JS computes the db-writes counter from db_events.length, so
    # a dolt_op-only case must embed db_events: []. Assert on this case alone.
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)

    assert c["db_events"] == []
    assert [%{"kind" => "dolt_op"}] = c["captures"]
  end
end
