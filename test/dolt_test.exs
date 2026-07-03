defmodule TestLens.DoltTest do
  @moduledoc """
  Verifies the TestLens.Dolt adapter: collect → JSON file → HTML viewer.

  No live Dolt binary is required. All assertions run against the recorder
  and the viewer, using the same fixtures-from-recorder pattern as catalog_test.

  This file also dogfoods TestLens on itself. Each test drives the recorder for a
  *synthetic* case keyed to `self()`, and the synthetic `finish` forgets `self()`
  — so the dogfood readouts below (the input op, the acted-on thing, the verified
  outcome) are recorded onto *this* test's own case in the window before the
  synthetic `Recorder.begin` steals the pid. `use TestLens.Case` registers that
  real case; the `TestLens.action` block copies the recording step's source into
  the ACTION channel. A `TestLens.verify` block would be dropped (the synthetic
  `finish` already forgot the pid by then), so the verified outcome is recorded as
  a `stage: "verify"` readout instead. See concerns in the handoff for detail.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.{Dolt, Recorder, ViewerCase}

  # ---------------------------------------------------------------------------
  # Collector — confirm dolt_op lands in captures, not db_events
  # ---------------------------------------------------------------------------

  test "Dolt.capture stores a dolt_op entry in captures" do
    op = %{
      action: "commit",
      branch: "feature/add-index",
      commit_hash: "abc1234f",
      message: "Add index on annotations.org_id",
      result: :ok
    }

    module = TestLens.DoltTest.CommitSynthetic
    name = :"test dolt commit capture"

    TestLens.capture("dolt op fed to Dolt.capture/2", op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["branch"], ["commit_hash"]]
    )

    TestLens.capture(
      "verified: the op lands as one dolt_op capture at the action stage, no db writes",
      %{lands_in: "captures", kind: "dolt_op", stage: "action", captures: 1, db_events: 0},
      stage: "verify",
      annotate: [["kind"], ["captures"], ["db_events"]]
    )

    TestLens.action "record the op through the recorder and flush it to a case file" do
      Recorder.begin(%{
        module: module,
        name: name,
        pid: self(),
        file: __ENV__.file,
        line: __ENV__.line,
        tags: []
      })

      Recorder.put_stage(self(), "action")
      Dolt.capture(self(), op)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    end

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

  test "Dolt.capture stores a dolt_op for a branch op with no commit hash or message" do
    op = %{action: "branch", branch: "new-feature"}

    module = TestLens.DoltTest.BranchlessSynthetic
    name = :"test dolt branch capture minimal op"

    TestLens.capture("minimal dolt op: a branch creation, no commit hash or message", op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["branch"]]
    )

    TestLens.capture(
      "verified: still stored as a dolt_op; commit_hash and message keys are simply absent",
      %{kind: "dolt_op", action: "branch", has_commit_hash: false, has_message: false},
      stage: "verify",
      annotate: [["kind"], ["action"]]
    )

    TestLens.action "record the minimal op and flush it to a case file" do
      Recorder.begin(%{
        module: module,
        name: name,
        pid: self(),
        file: __ENV__.file,
        line: __ENV__.line,
        tags: []
      })

      Dolt.capture(self(), op)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 500)
    end

    case_data = path |> File.read!() |> Jason.decode!()
    [cap] = case_data["captures"]
    assert cap["kind"] == "dolt_op"
    assert cap["value"]["action"] == "branch"
    # a minimal op stores exactly the keys it carried — nothing is defaulted in.
    refute Map.has_key?(cap["value"], "commit_hash")
    refute Map.has_key?(cap["value"], "message")
  end

  # ---------------------------------------------------------------------------
  # db_writes stays 0 for a case whose only captures are dolt_op
  # ---------------------------------------------------------------------------

  test "a case with only dolt_op captures has zero db_events" do
    merge_op = %{action: "merge", branch: "main", message: "Merge feature branch"}

    commit_op = %{
      action: "commit",
      branch: "main",
      commit_hash: "deadbeef",
      message: "Post-merge snapshot"
    }

    module = TestLens.DoltTest.DbZeroSynthetic
    name = :"test dolt only no db writes"

    TestLens.capture("first dolt op: a merge onto main", merge_op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["branch"]]
    )

    TestLens.capture("second dolt op: the post-merge commit", commit_op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["commit_hash"]]
    )

    TestLens.capture(
      "verified: both ops land in captures as dolt_op; db_events stays empty",
      %{captures: 2, all_kind: "dolt_op", db_events: 0},
      stage: "verify",
      annotate: [["captures"], ["db_events"]]
    )

    TestLens.action "record both dolt ops and flush the case" do
      Recorder.begin(%{
        module: module,
        name: name,
        pid: self(),
        file: __ENV__.file,
        line: __ENV__.line,
        tags: []
      })

      Dolt.capture(self(), merge_op)
      Dolt.capture(self(), commit_op)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 800)
    end

    case_data = path |> File.read!() |> Jason.decode!()

    assert length(case_data["captures"]) == 2
    assert case_data["db_events"] == []
    assert Enum.all?(case_data["captures"], fn c -> c["kind"] == "dolt_op" end)
  end

  # ---------------------------------------------------------------------------
  # Viewer — HTML embeds the payload; db_writes reads out 0
  # ---------------------------------------------------------------------------

  test "Viewer.build embeds the dolt_op capture payload the renderer draws from" do
    op = %{
      action: "commit",
      branch: "deploy/v2",
      commit_hash: "c0ffee99",
      message: "Release v2 schema"
    }

    module = TestLens.DoltTest.ViewerSynthetic
    name = :"test dolt viewer html"

    TestLens.capture("dolt op recorded, then built into the viewer", op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["branch"], ["commit_hash"]]
    )

    TestLens.capture(
      "verified: the built HTML embeds this dolt_op payload verbatim for the JS renderer",
      %{
        embedded_kind: "dolt_op",
        embedded_stage: "action",
        embedded_commit_hash: "c0ffee99",
        exact_bytes_present: [~s("kind":"dolt_op"), ~s("commit_hash":"c0ffee99")]
      },
      stage: "verify",
      annotate: [["embedded_kind"], ["embedded_commit_hash"]]
    )

    TestLens.action "record the op, then build an isolated viewer over just this case" do
      Recorder.begin(%{
        module: module,
        name: name,
        pid: self(),
        file: __ENV__.file,
        line: __ENV__.line,
        tags: []
      })

      Recorder.put_stage(self(), "action")
      Dolt.capture(self(), op)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 1_500)
    end

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

    TestLens.capture(
      "hostile capture: a prototype-colliding kind and a script-tag label",
      %{kind: "constructor", label: "<script>alert(1)</script>", value: %{safe: true}},
      stage: "setup",
      annotate: [["kind"], ["label"]]
    )

    TestLens.capture(
      "verified: stored via the generic JSON fallback (no crash), script tag neutralized to text",
      %{
        rendered_via: "generic JSON fallback",
        stored_kind: "constructor",
        stored_value: %{safe: true},
        script_label_escaped: true
      },
      stage: "verify",
      annotate: [["stored_kind"], ["script_label_escaped"]]
    )

    TestLens.action "record the hostile capture, then build an isolated viewer from it" do
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
    end

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
    op = %{action: "diff", branch: "compare-branch"}

    module = TestLens.DoltTest.DbZeroViewer
    name = :"test viewer db writes zero"

    TestLens.capture("dolt diff op — the case's only capture", op,
      kind: :dolt_op,
      stage: "setup",
      annotate: [["action"], ["branch"]]
    )

    TestLens.capture(
      "verified: a dolt_op-only case carries zero db_events, so the viewer's db-writes counter reads 0",
      %{captures: ["dolt_op"], db_events: 0, db_writes: 0},
      stage: "verify",
      annotate: [["db_writes"], ["db_events"]]
    )

    TestLens.action "record only a dolt op, then build the viewer over just this case" do
      Recorder.begin(%{
        module: module,
        name: name,
        pid: self(),
        file: __ENV__.file,
        line: __ENV__.line,
        tags: []
      })

      Dolt.capture(self(), op)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 600)
    end

    # The viewer's JS computes the db-writes counter from db_events.length, so
    # a dolt_op-only case must embed db_events: []. Assert on this case alone.
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)

    assert c["db_events"] == []
    assert [%{"kind" => "dolt_op"}] = c["captures"]
  end
end
