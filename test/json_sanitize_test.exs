defmodule TestLens.JSONSanitizeTest do
  @moduledoc """
  Direct unit tests for `TestLens.JSON.sanitize/1` — the coercion that makes any
  captured test value JSON-encodable before the recorder ever touches it. Every
  case also asserts the result actually round-trips through `Jason.encode!/1`,
  since JSON-safety is the whole contract.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive value, so a
  newcomer can read what is sanitized and how straight off the rendered page.
  The *input* is captured via `inspect/1` on purpose: the recorder would sanitize
  a raw term and erase exactly the Elixir-specific shape under test (atom colons,
  tuple braces, `#PID<>`), so the input panel would otherwise show the answer.
  """
  use ExUnit.Case, async: true
  use TestLens.Case

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
    TestLens.setup "one value per JSON-relevant scalar type, plus an atom" do
      scalars = [nil, true, false, 42, 1.5, "hi", :ok]
      TestLens.capture("scalar inputs (as Elixir)", inspect(scalars))
    end

    TestLens.action "sanitize each and pair input -> output" do
      table =
        Enum.map(scalars, fn v -> %{"input" => inspect(v), "output" => JSON.sanitize(v)} end)

      TestLens.capture("input -> sanitized", table, annotate: [[6, "output"]])
    end

    TestLens.verify "scalars pass through byte-identical; the atom :ok became \"ok\"" do
      assert JSON.sanitize(nil) == nil
      assert JSON.sanitize(true) == true
      assert JSON.sanitize(false) == false
      assert JSON.sanitize(42) == 42
      assert JSON.sanitize(1.5) == 1.5
      assert JSON.sanitize("hi") == "hi"
      assert JSON.sanitize(:ok) == "ok"
    end
  end

  test "a struct becomes a map tagged with its module, __meta__ dropped" do
    TestLens.setup "an Ecto-like struct carrying id, name and a __meta__ field" do
      sample = %Sample{id: 7, name: "widget", __meta__: :loaded}
      TestLens.capture("struct input (as Elixir)", inspect(sample))
    end

    TestLens.action "JSON.sanitize/1 the struct" do
      result = JSON.sanitize(sample) |> encodable!()
      TestLens.capture("sanitized map", result, annotate: [["__struct__"]])
    end

    TestLens.verify "the module is tagged as __struct__ and __meta__ is gone" do
      assert result["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
      assert result["id"] == 7
      assert result["name"] == "widget"
      refute Map.has_key?(result, "__meta__")
      refute Map.has_key?(result, :__meta__)
    end
  end

  test "nested structs are tagged recursively" do
    TestLens.setup "a Sample struct whose name field is itself a Sample struct" do
      outer = %Sample{id: 1, name: %Sample{id: 2, name: "inner", __meta__: :x}, __meta__: :y}
      TestLens.capture("nested struct input (as Elixir)", inspect(outer))
    end

    TestLens.action "JSON.sanitize/1 the nested struct" do
      result = JSON.sanitize(outer) |> encodable!()

      TestLens.capture("sanitized (both levels tagged, __meta__ dropped)", result,
        annotate: [["name", "__struct__"]]
      )
    end

    TestLens.verify "the inner struct is tagged too and its __meta__ is gone" do
      assert result["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
      assert result["name"]["__struct__"] == "TestLens.JSONSanitizeTest.Sample"
      assert result["name"]["name"] == "inner"
      refute Map.has_key?(result["name"], "__meta__")
    end
  end

  test "tuples become lists, recursively" do
    TestLens.setup "a flat tuple, a nested tuple, and a tuple nested inside a map" do
      flat = {1, :two, "three"}
      nested = {:ok, {:nested, 2}}
      in_map = %{result: {:error, :nope}}
      TestLens.capture("tuple inputs (as Elixir)", inspect([flat, nested, in_map]))
    end

    TestLens.action "sanitize each tuple form" do
      flat_out = JSON.sanitize(flat) |> encodable!()
      nested_out = JSON.sanitize(nested) |> encodable!()
      in_map_out = JSON.sanitize(in_map) |> encodable!()

      TestLens.capture(
        "sanitized (every tuple is now a list)",
        %{"flat" => flat_out, "nested" => nested_out, "in_map" => in_map_out},
        annotate: [["nested"]]
      )
    end

    TestLens.verify "each tuple — even one nested inside another — became a JSON list" do
      assert flat_out == [1, "two", "three"]
      assert nested_out == ["ok", ["nested", 2]]

      assert in_map_out == %{
               "result" => ["error", "nope"]
             }
    end
  end

  test "map keys that are not atoms or strings fall back to inspect" do
    TestLens.setup "a map keyed by an integer and a map keyed by a tuple" do
      int_key = %{1 => :a}
      tuple_key = %{{:composite, :key} => "v"}
      TestLens.capture("map inputs (as Elixir)", inspect([int_key, tuple_key]))
    end

    TestLens.action "sanitize; non-string/atom keys fall back to their inspect string" do
      int_out = JSON.sanitize(int_key) |> encodable!()
      tuple_out = JSON.sanitize(tuple_key) |> encodable!()

      TestLens.capture(
        "sanitized (keys stringified)",
        %{"from_integer_key" => int_out, "from_tuple_key" => tuple_out},
        annotate: [["from_tuple_key", "{:composite, :key}"]]
      )
    end

    TestLens.verify "the integer key became \"1\"; the tuple key became its inspect string" do
      assert int_out == %{"1" => "a"}

      assert tuple_out == %{
               "{:composite, :key}" => "v"
             }
    end
  end

  test "pids, refs and functions fall back to their inspect string" do
    TestLens.setup "the three non-JSON reference types: a pid, a ref, a function" do
      pid = self()
      ref = make_ref()
      fun = fn x -> x end

      TestLens.capture(
        "reference-type inputs (as Elixir)",
        inspect(%{pid: pid, ref: ref, fun: fun})
      )
    end

    TestLens.action "sanitize each reference value" do
      pid_out = JSON.sanitize(pid) |> encodable!()
      ref_out = JSON.sanitize(ref) |> encodable!()
      fun_out = JSON.sanitize(fun) |> encodable!()

      TestLens.capture(
        "sanitized (each is now its inspect string)",
        %{"pid" => pid_out, "ref" => ref_out, "fun" => fun_out},
        annotate: [["pid"]]
      )
    end

    TestLens.verify "each became a string equal to its inspect representation" do
      assert pid_out == inspect(pid)
      assert ref_out == inspect(ref)
      assert is_binary(fun_out)
      assert String.starts_with?(fun_out, "#Function<")
    end
  end

  test "exotic values survive even nested inside maps, lists and tuples" do
    TestLens.setup "a pid, a ref and a tuple-wrapped pid buried in a map and a list" do
      value = %{pid: self(), items: [make_ref(), {:tuple, self()}]}
      TestLens.capture("nested exotic input (as Elixir)", inspect(value))
    end

    TestLens.action "sanitize the whole nested structure at once" do
      result = JSON.sanitize(value) |> encodable!()

      TestLens.capture("sanitized (exotics stringified in place)", result,
        annotate: [["pid"], ["items"]]
      )
    end

    TestLens.verify "the pid, the ref and the tuple-nested pid all survive as strings/lists" do
      assert result["pid"] == inspect(self())
      assert [ref_str, ["tuple", pid_str]] = result["items"]
      assert String.starts_with?(ref_str, "#Reference<")
      assert pid_str == inspect(self())
    end
  end

  test "a non-UTF-8 binary is rendered via inspect rather than emitted raw" do
    TestLens.setup "a three-byte binary that is not valid UTF-8" do
      bad = <<0xFF, 0xFE, 0x00>>
      refute String.valid?(bad)
      TestLens.capture("binary input (as Elixir)", inspect(bad))
    end

    TestLens.action "sanitize the invalid binary" do
      result = JSON.sanitize(bad) |> encodable!()
      TestLens.capture("sanitized (rendered via inspect, not raw bytes)", result)
    end

    TestLens.verify "the result is a valid-UTF-8 string equal to inspect(bad)" do
      assert result == inspect(bad)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  test "elides values past the max nesting depth with a marker" do
    TestLens.setup "a map nested 30 levels deep — well past the sanitizer's max depth" do
      depth = 30
      deep = Enum.reduce(1..depth, "bottom", fn _, acc -> %{"k" => acc} end)
      # Walk down the "k" chain until we hit whatever is no longer a map.
      walk = fn f, v -> if is_map(v), do: f.(f, v["k"]), else: v end

      TestLens.capture("nesting facts", %{"depth" => depth, "leaf_value" => "bottom"},
        annotate: [["depth"]]
      )
    end

    TestLens.action "sanitize; the subtree past max depth collapses to a marker" do
      result = JSON.sanitize(deep) |> encodable!()
      marker = walk.(walk, result)
      TestLens.capture("value found at the bottom of the sanitized chain", marker)
    end

    TestLens.verify "the deep subtree collapsed to the ellipsis marker; \"bottom\" never appears" do
      # rather than recursing forever or blowing up the encoder.
      assert marker == "…"
      refute inspect(result) =~ "bottom"
    end
  end
end
