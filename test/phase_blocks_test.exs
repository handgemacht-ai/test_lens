defmodule TestLens.PhaseBlocksTest do
  @moduledoc """
  Verifies the setup/action/verify block macros copy each block's source verbatim
  into the case file and the HTML, carry the action description, and still run the
  wrapped code (variables a block binds stay in scope). Real Recorder and Viewer,
  same pattern as annotate_test.
  """
  use ExUnit.Case, async: false
  require TestLens

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

  test "each block files its source under its own channel and runs the code" do
    module = TestLens.PhaseBlocksTest.Synthetic
    name = :"test phase blocks copy source and run"

    begin(module, name)

    TestLens.setup do
      seed = 20
    end

    doubled =
      TestLens.action "double the seed" do
        seed * 2
      end

    TestLens.verify do
      assert doubled == 40
    end

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)

    case_data = path |> File.read!() |> Jason.decode!()
    sources = Enum.filter(case_data["captures"], &(&1["kind"] == "source"))

    assert Enum.map(sources, & &1["stage"]) |> Enum.sort() == ["action", "setup", "verify"]

    action = Enum.find(sources, &(&1["stage"] == "action"))
    assert action["label"] == "double the seed"
    assert String.contains?(action["value"], "seed * 2")

    setup = Enum.find(sources, &(&1["stage"] == "setup"))
    assert setup["label"] == ""
    assert String.contains?(setup["value"], "seed = 20")
  end

  test "the copied source and the action description reach the rendered HTML" do
    module = TestLens.PhaseBlocksTest.RenderSynthetic
    name = :"test phase blocks reach the html"

    begin(module, name)

    TestLens.action "compute the answer" do
      _answer = 6 * 7
    end

    assert {:ok, _path} = Recorder.finish(module, name, "passed", 500)

    html = build_html()
    assert String.contains?(html, "6 * 7"), "expected the copied action source in the HTML"
    assert String.contains?(html, "compute the answer"), "expected the description in the HTML"
    assert String.contains?(html, "phase-src"), "expected the source renderer in the viewer"
  end
end
