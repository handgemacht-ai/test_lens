defmodule TestLens.CatalogTest do
  @moduledoc """
  Verifies the "catalog" path: a test that never called begin/1 (no shared
  `use TestLens.Case`) is still written by the formatter as a *status-only*
  case — `captures` and `db_events` empty, but `status`/`tags`/`line` carried
  through from the metadata the formatter already knows. That is what lets a
  suite with no shared case module still render as a catalog from the
  test_helper wiring alone.

  The check drives `Recorder.finish/5` directly with a *synthetic* test identity
  that never began, so the assertion stays about the no-begin case. This module
  itself uses `TestLens.Case`, so its own page narrates the check as
  input → action → result, while the synthetic case it writes shows up as a bare
  status-only catalog entry.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.Recorder

  test "finish/5 writes a status-only case when begin/1 never ran" do
    TestLens.setup do
      module = TestLens.CatalogTest.Synthetic
      name = :"test catalog only"
      status = "passed"
      duration_us = 4_200
      meta = %{file: __ENV__.file, line: 99, tags: ["smoke"]}
    end

    TestLens.capture(
      "finish/5 inputs (this identity never called begin/1)",
      %{
        module: inspect(module),
        name: to_string(name),
        status: status,
        duration_us: duration_us,
        meta: %{line: meta.line, tags: meta.tags}
      },
      annotate: [["status"], ["meta", "line"], ["meta", "tags"]]
    )

    TestLens.action "Recorder.finish/5 with no prior begin/1" do
      assert {:ok, path} = Recorder.finish(module, name, status, duration_us, meta)
    end

    TestLens.capture("case file written", Path.basename(path), kind: :text)

    TestLens.verify do
      case_data = path |> File.read!() |> Jason.decode!()

      assert case_data["status"] == "passed"
      assert case_data["captures"] == []
      assert case_data["db_events"] == []
      assert case_data["tags"] == ["smoke"]
      assert case_data["line"] == 99
    end

    TestLens.capture(
      "status-only case on disk",
      case_data,
      annotate: [["status"], ["captures"], ["db_events"], ["tags"], ["line"]]
    )
  end
end
