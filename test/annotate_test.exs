defmodule TestLens.AnnotateTest do
  @moduledoc """
  Verifies the explicit annotation API and highlight rendering end to end:
  capture → JSON case file → HTML viewer. No mocking — the real Recorder and
  Viewer write and read actual files, same pattern as dolt_test.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive value, so
  each test's *own* rendered page reads as input → action → result. The case
  that is the subject under test is recorded on a separate pid (see
  `record_off_pid/5`) so it never hijacks this test's own recording.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.{Recorder, ViewerCase}

  defp begin(module, name) do
    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })
  end

  # Drive a synthetic case's full lifecycle (begin → capture → flush) on a
  # separate pid. The recorder routes captures by the *calling* pid, so running
  # this on the test's own pid would hijack the pid→case mapping that
  # `use TestLens.Case` set up for THIS test's setup/action/verify page — and
  # `finish/4` would then drop it. Doing it in a Task keeps `self()` bound to
  # this test throughout. `Recorder.finish/4` is a synchronous call from the
  # Task, so it lands after the Task's own capture casts (same-pid FIFO).
  defp record_off_pid(module, name, status, duration_us, capture_fun) do
    Task.async(fn ->
      begin(module, name)
      capture_fun.()
      Recorder.finish(module, name, status, duration_us)
    end)
    |> Task.await()
  end

  test "annotate writes the path into the case and the HTML highlights the resolved value" do
    module = TestLens.AnnotateTest.MatchSynthetic
    name = :"test annotate resolves a path"

    TestLens.setup "a response whose subject under test is data.creator" do
      response = %{data: %{creator: "alice"}}
      annotate = [["data", "creator"]]
      # Spotlight the one field the checks are really about; this page renders it
      # as a gold `data.creator = "alice"` readout over the value.
      TestLens.capture("response under test", response, annotate: annotate)
    end

    TestLens.action "record the annotated capture, flush the case, rebuild the viewer" do
      {:ok, path} =
        record_off_pid(module, name, "passed", 1_000, fn ->
          Recorder.put_stage(self(), "verify")
          TestLens.capture("response", response, stage: "verify", annotate: annotate)
        end)

      case_data = path |> File.read!() |> Jason.decode!()
      html = ViewerCase.build_isolated([path])
    end

    TestLens.verify "the annotate path and its resolved value reach the viewer payload" do
      assert case_data["schema"] == "test_lens/v1.1"

      [cap] = case_data["captures"]
      assert cap["paths"] == [["data", "creator"]]
      assert cap["value"]["data"]["creator"] == "alice"

      # Build against only this case: the annotation path and its resolved value
      # must reach the payload the readout renderer draws from. (The bare presence
      # of the annoHtml function proved nothing — it is in the shared JS even for
      # an empty viewer.)
      assert [c] = ViewerCase.data_payload(html)
      assert [embedded] = c["captures"]

      assert embedded["paths"] == [["data", "creator"]]
      assert embedded["value"]["data"]["creator"] == "alice"
      assert String.contains?(html, ~s("paths":[["data","creator"]]))

      # The verified outcome, spotlit: the recorded path and the value the viewer
      # highlights, keyed by path.
      TestLens.capture("viewer-embedded capture", embedded,
        annotate: [["paths"], ["value", "data", "creator"]]
      )
    end
  end

  test "a capture with no annotate renders normally and omits the paths key" do
    module = TestLens.AnnotateTest.NoAnnotateSynthetic
    name = :"test no annotate stays back-compatible"

    TestLens.setup "a plain capture with no single subject to spotlight" do
      value = %{hello: "world"}
      # No annotate: a plain/round-trip value has no one decisive field, so this
      # page highlights nothing (a highlight is a claim about what matters).
      TestLens.capture("plain value", value)
    end

    TestLens.action "record the un-annotated capture, flush the case, rebuild the viewer" do
      {:ok, path} =
        record_off_pid(module, name, "passed", 500, fn ->
          Recorder.put_stage(self(), "action")
          TestLens.capture("plain", value, stage: "action")
        end)

      case_data = path |> File.read!() |> Jason.decode!()
      html = ViewerCase.build_isolated([path])
    end

    TestLens.verify "the case and the viewer payload both omit the paths key" do
      [cap] = case_data["captures"]
      refute Map.has_key?(cap, "paths")
      assert cap["value"]["hello"] == "world"

      assert [c] = ViewerCase.data_payload(html)
      assert [embedded] = c["captures"]
      refute Map.has_key?(embedded, "paths")
      assert embedded["value"]["hello"] == "world"

      # The verified value carries no `paths` key — shown plainly, no highlight.
      TestLens.capture("un-annotated capture in payload", embedded)
    end
  end

  test "an old-style v1 case with no paths key still builds" do
    TestLens.setup "an on-disk case in the older test_lens/v1 shape (no paths key)" do
      run = ViewerCase.tmp_dir("test_lens_legacy")
      cases_dir = Path.join(run, "cases")
      File.mkdir_p!(cases_dir)

      legacy = %{
        "schema" => "test_lens/v1",
        "project" => "legacy",
        "module" => "TestLens.AnnotateTest.LegacySynthetic",
        "name" => "old v1 case",
        "file" => "test/legacy.exs",
        "line" => 1,
        "status" => "passed",
        "tags" => [],
        "duration_us" => 100,
        "captures" => [
          %{
            "stage" => "verify",
            "label" => "out",
            "kind" => "json",
            "value" => %{"ok" => true},
            "seq" => 0
          }
        ],
        "db_events" => []
      }

      # The `schema` tag is what makes this a pre-annotate v1 case; spotlight it.
      TestLens.capture("legacy v1 case on disk", legacy, annotate: [["schema"]])
      File.write!(Path.join(cases_dir, "legacy-v1-case.json"), Jason.encode!(legacy))
    end

    TestLens.action "build the viewer from the legacy run directory" do
      {:ok, html_path, count} = TestLens.Viewer.build(dir: run)
      html = File.read!(html_path)
    end

    TestLens.verify "the v1 case builds and lands in the payload with no paths key" do
      assert count == 1

      assert [c] = ViewerCase.data_payload(html)
      assert c["schema"] == "test_lens/v1"
      assert c["name"] == "old v1 case"
      # the v1 capture carries no `paths` key and still lands in the payload
      assert [cap] = c["captures"]
      refute Map.has_key?(cap, "paths")

      # The verified outcome: the rebuilt v1 case, still tagged test_lens/v1.
      TestLens.capture("rebuilt v1 case in payload", c, annotate: [["schema"]])
    end
  end

  test "an annotate path that matches nothing renders the matched-no-value marker" do
    module = TestLens.AnnotateTest.MissSynthetic
    name = :"test annotate miss marker"

    TestLens.setup "a response annotated with a path that resolves to nothing" do
      response = %{data: %{creator: "alice"}}
      missing = [["data", "nonexistent"]]
      # The path points at a key the value does not have; on this very page it
      # renders the visible "annotation matched no value" miss marker.
      TestLens.capture("response with a drifted annotate path", response, annotate: missing)
    end

    TestLens.action "record the miss-annotated capture, flush the case, rebuild the viewer" do
      {:ok, path} =
        record_off_pid(module, name, "passed", 700, fn ->
          Recorder.put_stage(self(), "verify")
          TestLens.capture("response", response, stage: "verify", annotate: missing)
        end)

      case_data = path |> File.read!() |> Jason.decode!()
      html = ViewerCase.build_isolated([path])
    end

    TestLens.verify "the unresolved path reaches the payload so the viewer draws the miss marker" do
      [cap] = case_data["captures"]
      assert cap["paths"] == [["data", "nonexistent"]]
      refute Map.has_key?(cap["value"]["data"], "nonexistent")

      # The unresolved path must reach the payload so the client renders the
      # miss marker for it. ("annotation matched no value" is a JS string literal
      # present even in an empty viewer, so asserting on it proved nothing.)
      assert [c] = ViewerCase.data_payload(html)
      assert [embedded] = c["captures"]

      assert embedded["paths"] == [["data", "nonexistent"]]
      refute Map.has_key?(embedded["value"]["data"], "nonexistent")
      assert String.contains?(html, ~s("paths":[["data","nonexistent"]]))

      # The verified outcome: the drifted path that resolves to nothing.
      TestLens.capture("miss-annotated capture in payload", embedded, annotate: [["paths"]])
    end
  end
end
