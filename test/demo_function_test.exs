defmodule TestLens.DemoFunctionTest do
  @moduledoc """
  Demonstrates the function-call test shape (ash_knowledge_graph style): a plain
  call that returns {:ok, _} / {:error, _}. No database, no sandbox.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.Sample

  test "create_branch accepts a clean name" do
    TestLens.stage(:setup)
    TestLens.capture("candidate name", "feature_login")

    result = TestLens.action("Sample.create_branch/1", Sample.create_branch("feature_login"))

    TestLens.output("returns", result)
    assert {:ok, %{created: true}} = result
  end

  test "create_branch rejects a protected name" do
    TestLens.stage(:setup)
    TestLens.capture("candidate name", "main")

    result = TestLens.action("Sample.create_branch/1", Sample.create_branch("main"))

    TestLens.output("returns", result)
    assert {:error, {:protected_branch, "main"}} = result
  end
end
