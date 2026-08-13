defmodule TestLens.CaseIdTest do
  use ExUnit.Case, async: true

  alias TestLens.CaseId

  test "to_string/1 emits the wire `module::name` format" do
    assert CaseId.to_string(%CaseId{module: "M", name: "t"}) == "M::t"
  end

  test "from_case/1 mirrors the former Diff.identity/1 derivation, coercing with to_string/1" do
    assert %CaseId{module: "M", name: "kept"} =
             CaseId.from_case(%{"module" => "M", "name" => "kept"})

    # A missing field reads as "" (to_string(nil)) rather than raising, matching
    # the lenient reader.
    assert %CaseId{module: "", name: "t"} = CaseId.from_case(%{"name" => "t"})
    assert %CaseId{module: "M", name: ""} = CaseId.from_case(%{"module" => "M"})

    assert CaseId.from_case(%{"module" => "M", "name" => "t"}) |> CaseId.to_string() ==
             "M::t"
  end

  test "parse/1 round-trips to_string/1, including a name that contains the delimiter" do
    id = %CaseId{module: "M", name: "t"}
    assert {:ok, ^id} = CaseId.parse("M::t")

    # The split is on the first "::", so "a::b" survives in the name.
    named = %CaseId{module: "M", name: "a::b"}
    assert {:ok, ^named} = CaseId.parse(CaseId.to_string(named))
    assert CaseId.to_string(named) == "M::a::b"
  end

  test "parse/1 is fail-closed on a malformed identity" do
    assert CaseId.parse("::t") == :error
    assert CaseId.parse("M::") == :error
    assert CaseId.parse("no-delimiter") == :error
    assert CaseId.parse("") == :error
    assert CaseId.parse(nil) == :error
  end
end
