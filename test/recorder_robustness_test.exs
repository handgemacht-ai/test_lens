defmodule TestLens.RecorderRobustnessTest do
  @moduledoc """
  Recorder robustness and run lifecycle:

    * a poison capture (or a failed write) drops that one case and the recorder
      keeps recording the rest of the run;
    * booting without recording creates no run directory and does not repoint
      `runs/latest`;
    * a real run writes cases + `meta.json` and `latest` points to it;
    * casts from an unresolvable pid are counted and surfaced in `meta.json`.

  Each test drives its own isolated, unnamed Recorder pointed at a throwaway
  output dir, so the suite's shared Recorder under `test_lens_out/` is untouched.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and captures the decisive values — the
  seeded pointer, the written `meta.json`, the poison payload, the drop counter —
  so each test's *own* rendered page reads as input → action → result. The
  recorder *under test* is addressed directly by its `pid`; the dogfood
  `TestLens.capture` calls go to the shared named Recorder keyed by `self()`, so
  recording never touches what is being verified.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.{JSON, Recorder}

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "test_lens_robust_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # Start an isolated, unnamed recorder torn down after the test. Git is passed
  # in so no test shells out to `git`.
  defp start_recorder(dir, overrides \\ []) do
    git = %{branch: nil, commit: nil, base_ref: nil, merge_base: nil}
    opts = Keyword.merge([project: "rob", dir: dir, name: nil, git: git], overrides)

    start_supervised!(%{
      id: {:recorder, System.unique_integer([:positive])},
      start: {Recorder, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp begin(pid, module, name) do
    GenServer.cast(
      pid,
      {:begin, %{module: module, name: name, pid: self(), file: __ENV__.file, line: 1, tags: []}}
    )
  end

  defp latest_path(dir), do: Path.join([dir, "runs", "latest"])

  defp run_dirs(dir),
    do: Path.wildcard(Path.join([dir, "runs", "*"])) |> Enum.filter(&File.dir?/1)

  describe "empty-run lifecycle" do
    test "booting without recording creates no run dir and does not repoint latest" do
      TestLens.setup "a dir already carrying a runs/latest pointer to a prior run" do
        dir = tmp_dir()
        # Seed a pre-existing pointer to prove an empty boot never clobbers it.
        File.mkdir_p!(Path.join(dir, "runs"))
        File.write!(latest_path(dir), "previous-run")

        # The pointer an empty boot must leave exactly as it found it.
        TestLens.capture("latest pointer before boot", File.read!(latest_path(dir)))
      end

      TestLens.action "boot a recorder and finalize without ever writing a case" do
        pid = start_recorder(dir)

        # No case is ever written. Finalize must leave nothing behind.
        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)

        # The run identity the recorder holds in memory — but must NOT materialize.
        TestLens.capture("in-memory run_dir (never written to disk)", run_dir)
      end

      TestLens.verify "no run dir, no meta.json, and latest still points to the prior run" do
        assert run_dirs(dir) == []
        refute File.exists?(run_dir)
        refute File.exists?(Path.join(run_dir, "meta.json"))
        assert File.read!(latest_path(dir)) == "previous-run"

        # The verified outcome: nothing materialized and the pointer is untouched.
        TestLens.capture(
          "after an empty boot",
          %{run_dirs: run_dirs(dir), latest: File.read!(latest_path(dir))},
          annotate: [[:run_dirs], [:latest]]
        )
      end
    end

    test "a real run writes cases + meta.json and latest points to it" do
      TestLens.setup "a fresh recorder with one passing test about to be recorded" do
        dir = tmp_dir()
        pid = start_recorder(dir)
        begin(pid, Rob.Real, :"records something")

        # The one case this run will record.
        TestLens.capture(
          "case to record",
          %{module: "Rob.Real", name: "records something", status: "passed"}
        )
      end

      TestLens.action "finish the case, then finalize the run" do
        assert {:ok, case_path} =
                 GenServer.call(
                   pid,
                   {:finish, Rob.Real, :"records something", "passed", 1_000, %{}}
                 )

        assert File.exists?(case_path)

        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir, run_id: run_id} = GenServer.call(pid, :run_info)

        # The file the recorder wrote for that case.
        TestLens.capture("written case file", Path.basename(case_path))
      end

      TestLens.verify "meta.json tallies one passed case and latest points to the run" do
        assert [^run_dir] = run_dirs(dir)

        case_files =
          Path.wildcard(Path.join(run_dir, "cases/*.json")) |> Enum.map(&Path.basename/1)

        assert case_files != []

        meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
        assert meta["case_count"] == 1
        assert meta["status_counts"] == %{"passed" => 1}

        assert File.read!(latest_path(dir)) == run_id

        # The verified outcome: what the run's meta.json actually recorded...
        TestLens.capture("meta.json", meta, annotate: [["case_count"], ["status_counts"]])

        # ...the case files on disk, and the latest pointer now holding this run_id.
        TestLens.capture(
          "run on disk",
          %{cases: case_files, latest: File.read!(latest_path(dir)), run_id: run_id},
          annotate: [[:cases], [:latest]]
        )
      end
    end
  end

  describe "never-die recorder" do
    test "survives a poison capture and later captures still record" do
      TestLens.setup "a fresh recorder and a poison payload it will choke on" do
        dir = tmp_dir()
        pid = start_recorder(dir)

        # The poison: a raw reference cast straight in, bypassing the caller-side
        # sanitize, so `write_case`'s `Jason.encode!` raises on it.
        TestLens.capture(
          "poison payload",
          %{label: "boom", kind: "json", value: "a raw Reference — not JSON-encodable"}
        )
      end

      TestLens.action "record a poison case (dropped), then a healthy case (recorded)" do
        # A capture holding a non-JSON-encodable value (a reference), cast directly
        # so it bypasses the caller-side sanitize and lands raw in the accumulator.
        # write_case's Jason.encode! then raises — that one case must be dropped,
        # not fatal.
        begin(pid, Rob.Poison, :"poison case")
        GenServer.cast(pid, {:capture, self(), "boom", "json", make_ref(), "action", []})

        assert {:error, :write_failed} =
                 GenServer.call(pid, {:finish, Rob.Poison, :"poison case", "passed", 1_000, %{}})

        # The recorder is still alive and still recording.
        assert Process.alive?(pid)

        # Direct cast (the isolated recorder is unnamed, so the named-target public
        # add_capture/5 can't reach it) with a caller-sanitized value, exactly the
        # shape add_capture would produce.
        begin(pid, Rob.Healthy, :"healthy case")

        GenServer.cast(
          pid,
          {:capture, self(), "ok", "json", JSON.sanitize(%{hello: "world"}), "action", []}
        )

        assert {:ok, good_path} =
                 GenServer.call(pid, {:finish, Rob.Healthy, :"healthy case", "passed", 500, %{}})

        TestLens.capture(
          "finish outcomes",
          %{poison: "{:error, :write_failed}", healthy: "{:ok, path}"}
        )
      end

      TestLens.verify "the healthy case is on disk intact and meta counts only the survivor" do
        data = good_path |> File.read!() |> Jason.decode!()
        assert data["name"] == "healthy case"
        assert [cap] = data["captures"]
        assert cap["value"] == %{"hello" => "world"}

        # Exactly the healthy case counts; the poison one is gone from meta.
        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
        assert meta["case_count"] == 1

        # The healthy capture that landed after the poison one was dropped.
        TestLens.capture("healthy case (recorded after poison)", data,
          annotate: [["name"], ["captures", 0, "value"]]
        )

        # meta.json counts exactly one case — the poison one left no trace.
        TestLens.capture("meta.json — poison dropped, one survivor", meta,
          annotate: [["case_count"]]
        )
      end
    end
  end

  describe "off-pid drop counter" do
    test "casts from an unresolvable pid are counted in meta.json" do
      TestLens.setup "a recorder plus a stranger pid that was never begin-ed" do
        dir = tmp_dir()
        pid = start_recorder(dir)

        # A pid that was never `begin`-ed for any test — its casts can't resolve.
        stranger = spawn(fn -> :ok end)

        TestLens.capture("stranger pid (unresolvable)", inspect(stranger))
      end

      TestLens.action "cast two messages from the stranger, then record one real case" do
        GenServer.cast(pid, {:capture, stranger, "orphan", "json", "v", "action", []})
        GenServer.cast(pid, {:db_event, stranger, %{op: "INSERT", sql: "INSERT ...", params: []}})

        # A real case so the run materializes and meta.json is written.
        begin(pid, Rob.Drop, :"real case")

        assert {:ok, _} =
                 GenServer.call(pid, {:finish, Rob.Drop, :"real case", "passed", 1_000, %{}})

        # The two off-pid casts that should be dropped-but-counted.
        TestLens.capture(
          "off-pid casts sent",
          %{capture: "orphan", db_event: "INSERT ..."}
        )
      end

      TestLens.verify "meta.json counts 2 dropped off-pid casts and 1 recorded case" do
        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

        assert meta["dropped_off_pid"] == 2
        assert meta["case_count"] == 1

        # The verified outcome: the drops were counted, not silently lost.
        TestLens.capture("meta.json", meta, annotate: [["dropped_off_pid"], ["case_count"]])
      end
    end
  end
end
