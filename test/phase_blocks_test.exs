defmodule TestLens.PhaseBlocksTest do
  @moduledoc """
  Verifies the setup/action/verify block macros copy each block's source verbatim
  into the case file and the HTML, carry the action description, and still run the
  wrapped code (variables a block binds stay in scope). Real Recorder and Viewer,
  same pattern as annotate_test.
  """
  use ExUnit.Case, async: false
  require TestLens

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

    assert {:ok, path} = Recorder.finish(module, name, "passed", 500)

    # Build against only this case: the copied source and the description must be
    # in the payload the "source" renderer draws from. ("phase-src" is a CSS
    # class + JS constant, present even in an empty viewer — asserting on it
    # proved nothing about this test.)
    html = ViewerCase.build_isolated([path])
    assert [c] = ViewerCase.data_payload(html)
    assert [source] = c["captures"]

    assert source["kind"] == "source"
    assert source["stage"] == "action"
    assert source["label"] == "compute the answer"
    assert String.contains?(source["value"], "6 * 7")
  end
end
