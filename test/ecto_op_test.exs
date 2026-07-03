defmodule TestLens.EctoOpTest do
  @moduledoc """
  Covers the Ecto telemetry handler: SQL is classified as INSERT/UPDATE/DELETE
  (ignoring leading whitespace and case), non-mutations are dropped, and a query
  that makes the handler raise is rescued so :telemetry never detaches it and DB
  capture keeps working for the rest of the run. Drives the real Recorder and
  reads the written case, same pattern as annotate_test.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive values (the
  SQL fed in, the op each query classified as, the rescued return value), so each
  test's *own* rendered page reads as input → action → result. The synthetic case
  that the Ecto handler records `db_events` onto is driven on a separate pid (see
  `record_off_pid/5`) so it never hijacks this test's own recording — the handler
  records via `self()`, and this test's page is routed by `self()` too.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

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

  # Drive a synthetic case's lifecycle (begin → body → finish) on a *separate*
  # pid. The Ecto handler records `db_events` onto whichever pid it runs in, so
  # running the synthetic case on the test's own pid would hijack the pid→case
  # mapping that `use TestLens.Case` set up for THIS test's setup/action/verify
  # page. Doing it in a Task keeps `self()` bound to this test throughout.
  # Returns `{finish_result, body_result}` so the caller can assert on the body's
  # value (e.g. the handler's rescued return) outside the Task. `Recorder.finish/4`
  # is a synchronous call from the Task, so it lands after the body's own casts
  # (same-pid FIFO). Duplicated in spirit from annotate_test.exs — see concerns.
  defp record_off_pid(module, name, status, duration_us, body_fun) do
    Task.async(fn ->
      begin(module, name)
      body_result = body_fun.()
      {Recorder.finish(module, name, status, duration_us), body_result}
    end)
    |> Task.await()
  end

  test "op/1 classifies mutations and ignores everything else, whitespace and case included" do
    module = TestLens.EctoOpTest.Classify
    name = :"test op classification"

    TestLens.setup "eight raw SQL strings: three canonical mutations, two with leading whitespace/lowercase, three non-mutations" do
      queries = [
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
      ]

      TestLens.capture("SQL strings fed to the handler", queries)
    end

    TestLens.action "run each query through the telemetry handler on a side pid, then read back the recorded db_events" do
      assert {{:ok, path}, _} =
               record_off_pid(module, name, "passed", 1_000, fn ->
                 Recorder.put_stage(self(), "action")

                 for sql <- queries do
                   Ecto.handle([:demo, :repo, :query], %{total_time: 1}, meta(sql), nil)
                 end
               end)

      events = db_events(path)
      ops = Enum.map(events, & &1["op"])
    end

    TestLens.verify "only the five mutations are recorded, in order; the three non-mutations are dropped" do
      assert ops == ["INSERT", "UPDATE", "DELETE", "INSERT", "UPDATE"]
      # sanitized params ride along with each recorded mutation
      assert Enum.all?(events, &(&1["params"] == ["a", "b"]))

      # Spotlight what each recorded query classified as: the op per query is the
      # subject under test. (Eight went in; only these five come back.)
      classified = Enum.map(events, &Map.take(&1, ["sql", "op", "params"]))

      TestLens.capture("recorded mutations (sql → op)", classified,
        annotate: Enum.map(0..(length(classified) - 1), &[&1, "op"])
      )
    end
  end

  test "a query that makes the handler raise is rescued and never propagates" do
    TestLens.setup "metadata that is not a map, so Map.get/3 inside the handler raises" do
      # Non-map metadata makes `Map.get/3` raise inside the handler; without the
      # rescue this call blows up (and under :telemetry would detach the handler).
      bad_metadata = :not_a_map
      TestLens.capture("handler metadata (non-map, poison input)", bad_metadata)
    end

    TestLens.action "invoke the telemetry handler with the poison metadata" do
      result = Ecto.handle([:demo, :repo, :query], %{}, bad_metadata, nil)
    end

    TestLens.verify "the raise is rescued: the handler returns :ok and nothing propagates" do
      assert result == :ok
      TestLens.capture("handler return value (rescued, never raised)", result)
    end
  end

  test "capture keeps working after a raising query — the handler is not left broken" do
    module = TestLens.EctoOpTest.Continues
    name = :"test handler continues"

    TestLens.setup "a raising call (non-map metadata) followed by a valid INSERT" do
      bad_metadata = :not_a_map
      good_insert = ~s|INSERT INTO "t" VALUES ($1)|

      TestLens.capture("1. poison metadata that makes the handler raise", bad_metadata)
      TestLens.capture("2. valid mutation issued right after", good_insert)
    end

    TestLens.action "feed both to the handler on a side pid, in order, then read back what was recorded" do
      assert {{:ok, path}, rescued} =
               record_off_pid(module, name, "passed", 1_000, fn ->
                 Recorder.put_stage(self(), "action")

                 # A raising call is swallowed...
                 rescued = Ecto.handle([:demo, :repo, :query], %{}, bad_metadata, nil)

                 # ...and the very next valid mutation is still captured.
                 Ecto.handle(
                   [:demo, :repo, :query],
                   %{total_time: 1},
                   meta(good_insert),
                   nil
                 )

                 rescued
               end)

      events = db_events(path)
    end

    TestLens.verify "the raising call left no event; the following INSERT was still captured" do
      assert rescued == :ok
      assert length(events) == 1
      assert hd(events)["op"] == "INSERT"

      # Before/after evidence: the failure recorded nothing, yet exactly one
      # INSERT survived — proof the handler was not left detached or broken.
      recorded = Enum.map(events, &Map.take(&1, ["op", "sql"]))

      TestLens.capture("db_events recorded after the rescued failure", recorded,
        annotate: [[0, "op"]]
      )
    end
  end

  test "through real telemetry the handler stays attached and keeps recording mutations" do
    module = TestLens.EctoOpTest.Telemetry
    name = :"test telemetry stays attached"

    TestLens.setup "attach the real :telemetry handler; two events will flow through it — one mutation, one read" do
      prefix = [:ecto_op_test, :repo]
      event = prefix ++ [:query]
      handler_id = {TestLens.Ecto, prefix}

      Ecto.attach(prefix)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      insert_sql = ~s|INSERT INTO "t" VALUES ($1)|
      select_sql = ~s|SELECT * FROM "t"|

      TestLens.capture("telemetry event name", event)

      TestLens.capture("queries executed through the handler", [
        %{sql: insert_sql, kind: "mutation"},
        %{sql: select_sql, kind: "read"}
      ])
    end

    TestLens.action "fire both events through real :telemetry on a side pid, then read back the recorded db_events" do
      assert {{:ok, path}, _} =
               record_off_pid(module, name, "passed", 1_000, fn ->
                 Recorder.put_stage(self(), "action")

                 :telemetry.execute(event, %{total_time: 1}, meta(insert_sql))
                 # a non-mutation flows through the same handler without detaching it
                 :telemetry.execute(event, %{total_time: 1}, %{query: select_sql})
               end)

      events = db_events(path)
      still_attached = Enum.any?(:telemetry.list_handlers(event), &(&1.id == handler_id))
    end

    TestLens.verify "the handler is still attached and recorded the one mutation, ignoring the read" do
      assert still_attached, "the handler detached itself"
      assert length(events) == 1
      assert hd(events)["op"] == "INSERT"

      # The verified outcome: after two live events the handler is still attached,
      # and exactly the mutation (not the read) was recorded.
      TestLens.capture(
        "handler survived + what it recorded",
        %{
          handler_still_attached: still_attached,
          recorded_mutations: Enum.map(events, &Map.take(&1, ["op", "sql"]))
        },
        annotate: [["handler_still_attached"], ["recorded_mutations", 0, "op"]]
      )
    end
  end
end
