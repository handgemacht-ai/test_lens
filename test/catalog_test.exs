defmodule TestLens.CatalogTest do
  @moduledoc """
  This module deliberately omits `use TestLens.Case`, so it never calls begin/1.
  The formatter still writes a status-only case from the test's own metadata,
  which is what lets a suite with no shared case module render as a catalog from
  the test_helper wiring alone.
  """
  use ExUnit.Case, async: false

  alias TestLens.Recorder

  test "finish/5 writes a status-only case when begin/1 never ran" do
    module = TestLens.CatalogTest.Synthetic
    name = :"test catalog only"

    assert {:ok, path} =
             Recorder.finish(module, name, "passed", 4_200, %{
               file: __ENV__.file,
               line: 99,
               tags: ["smoke"]
             })

    case_data = path |> File.read!() |> Jason.decode!()

    assert case_data["status"] == "passed"
    assert case_data["captures"] == []
    assert case_data["db_events"] == []
    assert case_data["tags"] == ["smoke"]
    assert case_data["line"] == 99
  end
end
