defmodule TestLens.DemoFunctionTest do
  @moduledoc """
  Demonstrates the function-call test shape (ash_knowledge_graph style): a plain
  call that returns {:ok, _} / {:error, _}. No database, no sandbox.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.Sample

  test "create_branch accepts a clean name" do
    TestLens.setup do
      name = "feature_login"
    end

    TestLens.action "Sample.create_branch/1" do
      result = Sample.create_branch(name)
    end

    TestLens.verify do
      assert {:ok, %{created: true}} = result
    end
  end

  test "create_branch rejects a protected name" do
    TestLens.setup do
      name = "main"
    end

    TestLens.action "Sample.create_branch/1" do
      result = Sample.create_branch(name)
    end

    TestLens.verify do
      assert {:error, {:protected_branch, "main"}} = result
    end
  end
end
