defmodule TestLens.AnnotateTest do
  @moduledoc """
  Verifies the explicit annotation API and highlight rendering end to end:
  capture → JSON case file → HTML viewer. No mocking — the real Recorder and
  Viewer write and read actual files, same pattern as dolt_test.
  """
  use ExUnit.Case, async: false

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

  test "annotate writes the path into the case and the HTML highlights the resolved value" do
    module = TestLens.AnnotateTest.MatchSynthetic
    name = :"test annotate resolves a path"

    begin(module, name)
    Recorder.put_stage(self(), "verify")

    TestLens.capture("response", %{data: %{creator: "alice"}},
      stage: "verify",
      annotate: [["data", "creator"]]
    )

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)

    case_data = path |> File.read!() |> Jason.decode!()
    assert case_data["schema"] == "test_lens/v1.1"

    [cap] = case_data["captures"]
    assert cap["paths"] == [["data", "creator"]]
    assert cap["value"]["data"]["creator"] == "alice"

    # Build against only this case: the annotation path and its resolved value
    # must reach the payload the readout renderer draws from. (The bare presence
    # of the annoHtml function proved nothing — it is in the shared JS even for
    # an empty viewer.)
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)
    assert [embedded] = c["captures"]

    assert embedded["paths"] == [["data", "creator"]]
    assert embedded["value"]["data"]["creator"] == "alice"
    assert String.contains?(html, ~s("paths":[["data","creator"]]))
  end

  test "a capture with no annotate renders normally and omits the paths key" do
    module = TestLens.AnnotateTest.NoAnnotateSynthetic
    name = :"test no annotate stays back-compatible"

    begin(module, name)
    Recorder.put_stage(self(), "action")

    TestLens.capture("plain", %{hello: "world"}, stage: "action")

    assert {:ok, path} = Recorder.finish(module, name, "passed", 500)

    case_data = path |> File.read!() |> Jason.decode!()
    [cap] = case_data["captures"]
    refute Map.has_key?(cap, "paths")
    assert cap["value"]["hello"] == "world"

    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)
    assert [embedded] = c["captures"]
    refute Map.has_key?(embedded, "paths")
    assert embedded["value"]["hello"] == "world"
  end

  test "an old-style v1 case with no paths key still builds" do
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

    File.write!(Path.join(cases_dir, "legacy-v1-case.json"), Jason.encode!(legacy))

    {:ok, html_path, count} = TestLens.Viewer.build(dir: run)
    assert count == 1
    html = File.read!(html_path)

    assert [c] = ViewerCase.data_payload(html)
    assert c["schema"] == "test_lens/v1"
    assert c["name"] == "old v1 case"
    # the v1 capture carries no `paths` key and still lands in the payload
    assert [cap] = c["captures"]
    refute Map.has_key?(cap, "paths")
  end

  test "an annotate path that matches nothing renders the matched-no-value marker" do
    module = TestLens.AnnotateTest.MissSynthetic
    name = :"test annotate miss marker"

    begin(module, name)
    Recorder.put_stage(self(), "verify")

    TestLens.capture("response", %{data: %{creator: "alice"}},
      stage: "verify",
      annotate: [["data", "nonexistent"]]
    )

    assert {:ok, path} = Recorder.finish(module, name, "passed", 700)

    case_data = path |> File.read!() |> Jason.decode!()
    [cap] = case_data["captures"]
    assert cap["paths"] == [["data", "nonexistent"]]
    refute Map.has_key?(cap["value"]["data"], "nonexistent")

    # The unresolved path must reach the payload so the client renders the
    # miss marker for it. ("annotation matched no value" is a JS string literal
    # present even in an empty viewer, so asserting on it proved nothing.)
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)
    assert [embedded] = c["captures"]

    assert embedded["paths"] == [["data", "nonexistent"]]
    refute Map.has_key?(embedded["value"]["data"], "nonexistent")
    assert String.contains?(html, ~s("paths":[["data","nonexistent"]]))
  end
end
