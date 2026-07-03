defmodule TestLens.PhaseBlocksTest do
  @moduledoc """
  Verifies the setup/action/verify block macros copy each block's source verbatim
  into the case file and the HTML, carry the action description, and still run the
  wrapped code (variables a block binds stay in scope). Real Recorder and Viewer,
  same pattern as annotate_test.

  This file also dogfoods TestLens on itself: each test wraps its own flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive value, so each
  test's *own* rendered page reads as input → action → result. The
  subject-under-test case (the synthetic case whose block macros are being
  checked) is driven on a separate pid (`Task`) so it never hijacks the
  pid→case mapping that `use TestLens.Case` set up for this test's own page.
  """
  use ExUnit.Case, async: false
  use TestLens.Case
  require TestLens

  alias TestLens.{Recorder, ViewerCase}

  # Begin a recording for a synthetic case identity, on whatever pid calls it.
  # Used only inside the off-test `Task`s below to drive the subject-under-test
  # case; this test's own page is begun by `use TestLens.Case` on the test pid.
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
    TestLens.setup "a synthetic test built from one setup, one action, one verify block" do
      module = TestLens.PhaseBlocksTest.Synthetic
      name = :"test phase blocks copy source and run"
      # The identity of the case whose block macros are the subject under test.
      TestLens.capture("synthetic case under test", %{
        module: inspect(module),
        name: to_string(name)
      })
    end

    TestLens.action "drive the three block macros on a separate pid, then read the recorded case" do
      # The block macros route captures by the *calling* pid, so drive the
      # synthetic lifecycle in a Task — otherwise it would hijack this test's own
      # page. seed=20 → double → assert 40 exercises "the wrapped code still runs".
      {:ok, path} =
        Task.async(fn ->
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

          Recorder.finish(module, name, "passed", 1_000)
        end)
        |> Task.await()

      case_data = path |> File.read!() |> Jason.decode!()
      sources = Enum.filter(case_data["captures"], &(&1["kind"] == "source"))
    end

    TestLens.verify "each block landed as a source capture in its own channel, verbatim" do
      assert Enum.map(sources, & &1["stage"]) |> Enum.sort() == ["action", "setup", "verify"]

      action = Enum.find(sources, &(&1["stage"] == "action"))
      assert action["label"] == "double the seed"
      assert String.contains?(action["value"], "seed * 2")

      setup = Enum.find(sources, &(&1["stage"] == "setup"))
      assert setup["label"] == ""
      assert String.contains?(setup["value"], "seed = 20")

      # The verified outcome, spotlit: the three channels the blocks filed under,
      # and the action channel's copied description (label) + verbatim source.
      TestLens.capture(
        "source channels the blocks produced",
        %{
          stages: Enum.map(sources, & &1["stage"]) |> Enum.sort(),
          action_label: action["label"],
          action_source: action["value"],
          setup_source: setup["value"]
        },
        annotate: [["stages"], ["action_label"], ["action_source"], ["setup_source"]]
      )
    end
  end

  test "the copied source and the action description reach the rendered HTML" do
    TestLens.setup "a synthetic case whose only step is one described action block" do
      module = TestLens.PhaseBlocksTest.RenderSynthetic
      name = :"test phase blocks reach the html"

      TestLens.capture("synthetic case under test", %{
        module: inspect(module),
        name: to_string(name)
      })
    end

    TestLens.action "record the action block off-pid, then build an isolated viewer from just that case" do
      # Drive the action block on a separate pid (see the module doc) so it
      # records onto the synthetic case, then build the viewer from *only* that
      # case so the payload is exactly this subject's data.
      {:ok, path} =
        Task.async(fn ->
          begin(module, name)

          TestLens.action "compute the answer" do
            _answer = 6 * 7
          end

          Recorder.finish(module, name, "passed", 500)
        end)
        |> Task.await()

      html = ViewerCase.build_isolated([path])
      payload = ViewerCase.data_payload(html)
    end

    TestLens.verify "the copied source and its description reach the viewer payload the source renderer draws from" do
      # Assert on the embedded payload the "source" renderer draws from — not on
      # the bare "phase-src" CSS class/JS constant, which is present even in an
      # empty viewer and would prove nothing about this case.
      assert [c] = payload
      assert [source] = c["captures"]

      assert source["kind"] == "source"
      assert source["stage"] == "action"
      assert source["label"] == "compute the answer"
      assert String.contains?(source["value"], "6 * 7")

      # The verified outcome, spotlit: the source capture the viewer embedded —
      # its channel (stage), the action's description (label), and the copied code.
      TestLens.capture("action source embedded in the viewer", source,
        annotate: [["stage"], ["label"], ["value"]]
      )
    end
  end
end
