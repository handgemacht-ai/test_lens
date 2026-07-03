defmodule TestLens.EctoOpTest do
  @moduledoc """
  Covers the Ecto telemetry handler: SQL is classified as INSERT/UPDATE/DELETE
  (ignoring leading whitespace and case), non-mutations are dropped, and a query
  that makes the handler raise is rescued so :telemetry never detaches it and DB
  capture keeps working for the rest of the run. Drives the real Recorder and
  reads the written case, same pattern as annotate_test.
  """
  use ExUnit.Case, async: false

  alias TestLens.{Ecto, Recorder}

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

  defp db_events(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("db_events")

  defp meta(sql), do: %{query: sql, source: "t", params: ["a", "b"]}

  test "op/1 classifies mutations and ignores everything else, whitespace and case included" do
    module = TestLens.EctoOpTest.Classify
    name = :"test op classification"
    begin(module, name)

    for sql <- [
          ~s|INSERT INTO "t" ("x") VALUES ($1)|,
          ~s|UPDATE "t" SET "x" = $1|,
          ~s|DELETE FROM "t" WHERE "id" = $1|,
          # leading whitespace + lowercase still classify
          "   insert into t values (1)",
          "\n\t  update t set y = 2",
          # non-mutations produce no db_event
          ~s|SELECT * FROM "t"|,
          "BEGIN",
          "commit"
        ] do
      Ecto.handle([:demo, :repo, :query], %{total_time: 1}, meta(sql), nil)
    end

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    events = db_events(path)

    assert Enum.map(events, & &1["op"]) == ["INSERT", "UPDATE", "DELETE", "INSERT", "UPDATE"]
    # sanitized params ride along with each recorded mutation
    assert Enum.all?(events, &(&1["params"] == ["a", "b"]))
  end

  test "a query that makes the handler raise is rescued and never propagates" do
    # Non-map metadata makes `Map.get/3` raise inside the handler; without the
    # rescue this call blows up (and under :telemetry would detach the handler).
    assert Ecto.handle([:demo, :repo, :query], %{}, :not_a_map, nil) == :ok
  end

  test "capture keeps working after a raising query — the handler is not left broken" do
    module = TestLens.EctoOpTest.Continues
    name = :"test handler continues"
    begin(module, name)

    # A raising call is swallowed...
    assert Ecto.handle([:demo, :repo, :query], %{}, :not_a_map, nil) == :ok

    # ...and the very next valid mutation is still captured.
    Ecto.handle(
      [:demo, :repo, :query],
      %{total_time: 1},
      meta(~s|INSERT INTO "t" VALUES ($1)|),
      nil
    )

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    events = db_events(path)

    assert length(events) == 1
    assert hd(events)["op"] == "INSERT"
  end

  test "through real telemetry the handler stays attached and keeps recording mutations" do
    prefix = [:ecto_op_test, :repo]
    event = prefix ++ [:query]
    handler_id = {TestLens.Ecto, prefix}

    Ecto.attach(prefix)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    module = TestLens.EctoOpTest.Telemetry
    name = :"test telemetry stays attached"
    begin(module, name)

    :telemetry.execute(event, %{total_time: 1}, meta(~s|INSERT INTO "t" VALUES ($1)|))
    # a non-mutation flows through the same handler without detaching it
    :telemetry.execute(event, %{total_time: 1}, %{query: ~s|SELECT * FROM "t"|})

    assert Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler_id)),
           "the handler detached itself"

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    events = db_events(path)

    assert length(events) == 1
    assert hd(events)["op"] == "INSERT"
  end
end
