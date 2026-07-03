defmodule TestLens.RecorderRobustnessTest do
  @moduledoc """
  Recorder robustness and run lifecycle:

    * a Reference/pid/function smuggled into a capture or into begin metadata is
      coerced to its safe string form and the case is written, not dropped;
    * a genuinely unwritable case (a failing `File.write!`) drops that one case,
      is logged once, and the recorder keeps recording the rest of the run;
    * booting without recording creates no run directory and does not repoint
      `runs/latest`;
    * a real run writes cases + `meta.json` and `latest` points to it;
    * casts from an unresolvable pid are counted and surfaced in `meta.json`.

  Each test drives its own isolated, unnamed Recorder pointed at a throwaway
  output dir, so the suite's shared Recorder under `test_lens_out/` is untouched.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and captures the decisive values — the
  seeded pointer, the written `meta.json`, the coerced exotics, the drop counter —
  so each test's *own* rendered page reads as input → action → result. The
  recorder *under test* is addressed directly by its `pid`; the dogfood
  `TestLens.capture` calls go to the shared named Recorder keyed by `self()`, so
  recording never touches what is being verified.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  import ExUnit.CaptureLog

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
    test "coerces a Reference/pid/function in a capture or metadata instead of dropping" do
      TestLens.setup "a recorder plus the three non-JSON-encodable types to smuggle in" do
        dir = tmp_dir()
        pid = start_recorder(dir)

        ref = make_ref()
        test_pid = self()
        fun = fn x -> x end

        # The exotics that must reach disk as their inspect strings — not drop the
        # case the way a raw Reference would if it hit Jason.encode! unsanitized.
        TestLens.capture(
          "smuggled reference-type values",
          %{ref: inspect(ref), pid: inspect(test_pid), fun: "a function"}
        )
      end

      TestLens.action "cast raw exotics into a capture AND into begin tags, bypassing the caller-side sanitize" do
        # A begin whose metadata tags carry raw exotics (as unflattened ExUnit
        # context tags could), cast directly so it skips Recorder.begin's sanitize.
        GenServer.cast(
          pid,
          {:begin,
           %{
             module: Rob.Coerce,
             name: :"coerces exotics",
             pid: test_pid,
             file: __ENV__.file,
             line: 1,
             tags: [ref, test_pid]
           }}
        )

        # A capture holding raw exotics, cast directly so it lands unsanitized in
        # the accumulator — exactly what a future unsanitized path would produce.
        GenServer.cast(
          pid,
          {:capture, test_pid, "exotics", "json", %{ref: ref, pid: test_pid, fun: fun}, "action",
           []}
        )

        assert {:ok, path} =
                 GenServer.call(
                   pid,
                   {:finish, Rob.Coerce, :"coerces exotics", "passed", 1_000, %{}}
                 )

        assert File.exists?(path)
        data = path |> File.read!() |> Jason.decode!()

        TestLens.capture("finish outcome (the case was written, not dropped)", "{:ok, path}")
      end

      TestLens.verify "the exotics are written as their safe inspect strings and the case survives" do
        cap = hd(data["captures"])
        assert cap["value"]["ref"] == inspect(ref)
        assert cap["value"]["pid"] == inspect(test_pid)
        assert String.starts_with?(cap["value"]["fun"], "#Function<")

        # The metadata tags carried exotics too, and were coerced the same way.
        assert inspect(ref) in data["tags"]
        assert inspect(test_pid) in data["tags"]

        # It counts as a real recorded case — proof it was coerced, not dropped.
        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
        assert meta["case_count"] == 1

        TestLens.capture(
          "coerced exotics written to the case",
          %{capture_value: cap["value"], tags: data["tags"], case_count: meta["case_count"]},
          annotate: [["capture_value", "ref"], ["tags"], ["case_count"]]
        )
      end
    end

    test "a genuinely unwritable case is dropped-and-logged and the recorder keeps recording" do
      TestLens.setup "a recorder whose next case cannot be written to disk" do
        dir = tmp_dir()
        pid = start_recorder(dir)
        begin(pid, Rob.Unwritable, :"cannot be written")

        # Plant a *file* where the run's cases directory must go, so write_case's
        # File.mkdir_p! raises — a failure sanitizing cannot fix, leaving the
        # drop-and-log rescue as the only thing that can keep the run alive.
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        File.mkdir_p!(run_dir)
        File.write!(Path.join(run_dir, "cases"), "not a directory")

        TestLens.capture(
          "blocker planted at the cases path",
          "a file where the cases dir must go"
        )
      end

      TestLens.action "finish the unwritable case (dropped, logged once), then record a healthy one" do
        # capture_log keeps the expected warning out of the suite's own output
        # while still letting us assert it was emitted.
        log =
          capture_log(fn ->
            assert {:error, :write_failed} =
                     GenServer.call(
                       pid,
                       {:finish, Rob.Unwritable, :"cannot be written", "passed", 1_000, %{}}
                     )
          end)

        # The recorder shrugged off the write failure and is still recording.
        assert Process.alive?(pid)

        # Clear the blocker; the very next case must still record cleanly.
        File.rm!(Path.join(run_dir, "cases"))
        begin(pid, Rob.Healthy, :"records after the drop")

        GenServer.cast(
          pid,
          {:capture, self(), "ok", "json", JSON.sanitize(%{hello: "world"}), "action", []}
        )

        assert {:ok, good_path} =
                 GenServer.call(
                   pid,
                   {:finish, Rob.Healthy, :"records after the drop", "passed", 500, %{}}
                 )

        TestLens.capture(
          "backstop outcome",
          %{drop: "{:error, :write_failed}", recovery: "{:ok, path}"}
        )
      end

      TestLens.verify "the drop was logged once, the recorder survived, and the next case recorded" do
        assert String.contains?(log, "dropped a write_case")
        assert Process.alive?(pid)

        data = good_path |> File.read!() |> Jason.decode!()
        assert data["name"] == "records after the drop"
        assert [cap] = data["captures"]
        assert cap["value"] == %{"hello" => "world"}

        # Only the survivor is counted — the dropped case left no trace.
        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
        assert meta["case_count"] == 1

        TestLens.capture(
          "drop-and-log backstop held",
          %{
            recorder_alive: Process.alive?(pid),
            logged: String.contains?(log, "dropped a write_case"),
            survivor: data["name"],
            case_count: meta["case_count"]
          },
          annotate: [["recorder_alive"], ["logged"], ["case_count"]]
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
