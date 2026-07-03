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
  """
  use ExUnit.Case, async: false

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
      dir = tmp_dir()

      # Seed a pre-existing pointer to prove an empty boot never clobbers it.
      File.mkdir_p!(Path.join(dir, "runs"))
      File.write!(latest_path(dir), "previous-run")

      pid = start_recorder(dir)

      # No case is ever written. Finalize + terminate must leave nothing behind.
      :ok = GenServer.call(pid, :finalize)
      %{run_dir: run_dir} = GenServer.call(pid, :run_info)

      assert run_dirs(dir) == []
      refute File.exists?(run_dir)
      refute File.exists?(Path.join(run_dir, "meta.json"))
      assert File.read!(latest_path(dir)) == "previous-run"
    end

    test "a real run writes cases + meta.json and latest points to it" do
      dir = tmp_dir()
      pid = start_recorder(dir)

      begin(pid, Rob.Real, :"records something")

      assert {:ok, case_path} =
               GenServer.call(
                 pid,
                 {:finish, Rob.Real, :"records something", "passed", 1_000, %{}}
               )

      assert File.exists?(case_path)

      :ok = GenServer.call(pid, :finalize)
      %{run_dir: run_dir, run_id: run_id} = GenServer.call(pid, :run_info)

      assert [^run_dir] = run_dirs(dir)
      assert Path.wildcard(Path.join(run_dir, "cases/*.json")) != []

      meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
      assert meta["case_count"] == 1
      assert meta["status_counts"] == %{"passed" => 1}

      assert File.read!(latest_path(dir)) == run_id
    end
  end

  describe "never-die recorder" do
    test "survives a poison capture and later captures still record" do
      dir = tmp_dir()
      pid = start_recorder(dir)

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

      data = good_path |> File.read!() |> Jason.decode!()
      assert data["name"] == "healthy case"
      assert [cap] = data["captures"]
      assert cap["value"] == %{"hello" => "world"}

      # Exactly the healthy case counts; the poison one is gone from meta.
      :ok = GenServer.call(pid, :finalize)
      %{run_dir: run_dir} = GenServer.call(pid, :run_info)
      meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
      assert meta["case_count"] == 1
    end
  end

  describe "off-pid drop counter" do
    test "casts from an unresolvable pid are counted in meta.json" do
      dir = tmp_dir()
      pid = start_recorder(dir)

      # A pid that was never `begin`-ed for any test — its casts can't resolve.
      stranger = spawn(fn -> :ok end)
      GenServer.cast(pid, {:capture, stranger, "orphan", "json", "v", "action", []})
      GenServer.cast(pid, {:db_event, stranger, %{op: "INSERT", sql: "INSERT ...", params: []}})

      # A real case so the run materializes and meta.json is written.
      begin(pid, Rob.Drop, :"real case")

      assert {:ok, _} =
               GenServer.call(pid, {:finish, Rob.Drop, :"real case", "passed", 1_000, %{}})

      :ok = GenServer.call(pid, :finalize)
      %{run_dir: run_dir} = GenServer.call(pid, :run_info)
      meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

      assert meta["dropped_off_pid"] == 2
      assert meta["case_count"] == 1
    end
  end
end
