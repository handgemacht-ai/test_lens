defmodule TestLens.AnnotateTest do
  @moduledoc """
  Verifies the explicit annotation API and highlight rendering end to end:
  capture → JSON case file → HTML viewer. No mocking — the real Recorder and
  Viewer write and read actual files, same pattern as dolt_test.
  """
  use ExUnit.Case, async: false

  alias TestLens.{Recorder, Viewer}

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

  defp build_html do
    dir = Application.get_env(:test_lens, :dir, "test_lens_out")
    {:ok, html_path, _count} = Viewer.build(dir: dir)
    File.read!(html_path)
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

    html = build_html()

    assert String.contains?(html, ~s("paths":[["data","creator"]])),
           "expected the annotation path embedded for the readout"

    assert String.contains?(html, "alice"), "expected the resolved value in the HTML"

    assert String.contains?(html, "function annoHtml"),
           "expected the viewer to carry the annotation readout renderer"
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

    html = build_html()
    assert String.contains?(html, "world")
  end

  test "an old-style v1 case with no paths key still builds" do
    dir = Application.get_env(:test_lens, :dir, "test_lens_out")
    cases_dir = Path.join(dir, "cases")
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

    html = build_html()
    assert String.contains?(html, "old v1 case")
    assert String.contains?(html, "test_lens/v1")
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

    html = build_html()

    assert String.contains?(html, ~s("paths":[["data","nonexistent"]])),
           "expected the unresolved annotation path embedded for rendering"

    assert String.contains?(html, "annotation matched no value"),
           "expected the matched-no-value marker renderer in the viewer"
  end
end
