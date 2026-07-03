defmodule TestLens.JSONSanitizeTest do
  @moduledoc """
  Direct unit tests for `TestLens.JSON.sanitize/1` — the coercion that makes any
  captured test value JSON-encodable before the recorder ever touches it. Every
  case also asserts the result actually round-trips through `Jason.encode!/1`,
  since JSON-safety is the whole contract.
  """
  use ExUnit.Case, async: true

  alias TestLens.JSON

  defmodule Sample do
    @moduledoc false
    defstruct [:id, :name, :__meta__]
  end

  defp encodable!(term) do
    # sanitize's promise: whatever comes out must encode without a protocol error
    assert {:ok, _} = Jason.encode(term)
    term
  end

  test "scalars pass through untouched, atoms become strings" do
    assert JSON.sanitize(nil) == nil
    assert JSON.sanitize(true) == true
    assert JSON.sanitize(false) == false
    assert JSON.sanitize(42) == 42
    assert JSON.sanitize(1.5) == 1.5
    assert JSON.sanitize("hi") == "hi"
    assert JSON.sanitize(:ok) == "ok"
  end

  test "a struct becomes a map tagged with its module, __meta__ dropped" do
    result = JSON.sanitize(%Sample{id: 7, name: "widget", __meta__: :loaded}) |> encodable!()

    assert result["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
    assert result["id"] == 7
    assert result["name"] == "widget"
    refute Map.has_key?(result, "__meta__")
    refute Map.has_key?(result, :__meta__)
  end

  test "nested structs are tagged recursively" do
    outer = %Sample{id: 1, name: %Sample{id: 2, name: "inner", __meta__: :x}, __meta__: :y}
    result = JSON.sanitize(outer) |> encodable!()

    assert result["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
    assert result["name"]["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
    assert result["name"]["name"] == "inner"
    refute Map.has_key?(result["name"], "__meta__")
  end

  test "tuples become lists, recursively" do
    assert JSON.sanitize({1, :two, "three"}) |> encodable!() == [1, "two", "three"]
    assert JSON.sanitize({:ok, {:nested, 2}}) |> encodable!() == ["ok", ["nested", 2]]

    assert JSON.sanitize(%{result: {:error, :nope}}) |> encodable!() == %{
             "result" => ["error", "nope"]
           }
  end

  test "map keys that are not atoms or strings fall back to inspect" do
    assert JSON.sanitize(%{1 => :a}) |> encodable!() == %{"1" => "a"}

    assert JSON.sanitize(%{{:composite, :key} => "v"}) |> encodable!() == %{
             "{:composite, :key}" => "v"
           }
  end

  test "pids, refs and functions fall back to their inspect string" do
    pid = self()
    assert JSON.sanitize(pid) |> encodable!() == inspect(pid)

    ref = make_ref()
    assert JSON.sanitize(ref) |> encodable!() == inspect(ref)

    fun = fn x -> x end
    rendered = JSON.sanitize(fun) |> encodable!()
    assert is_binary(rendered)
    assert String.starts_with?(rendered, "#Function<")
  end

  test "exotic values survive even nested inside maps, lists and tuples" do
    value = %{pid: self(), items: [make_ref(), {:tuple, self()}]}
    result = JSON.sanitize(value) |> encodable!()

    assert result["pid"] == inspect(self())
    assert [ref_str, ["tuple", pid_str]] = result["items"]
    assert String.starts_with?(ref_str, "#Reference<")
    assert pid_str == inspect(self())
  end

  test "a non-UTF-8 binary is rendered via inspect rather than emitted raw" do
    bad = <<0xFF, 0xFE, 0x00>>
    refute String.valid?(bad)

    result = JSON.sanitize(bad) |> encodable!()
    assert result == inspect(bad)
    assert is_binary(result)
    assert String.valid?(result)
  end

  test "elides values past the max nesting depth with a marker" do
    deep = Enum.reduce(1..30, "bottom", fn _, acc -> %{"k" => acc} end)
    result = JSON.sanitize(deep) |> encodable!()

    # Walk down the chain; the deep subtree collapses to the ellipsis marker
    # rather than recursing forever or blowing up the encoder.
    walk = fn f, v -> if is_map(v), do: f.(f, v["k"]), else: v end
    assert walk.(walk, result) == "…"
    refute inspect(result) =~ "bottom"
  end
end
