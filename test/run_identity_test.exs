defmodule TestLens.RunIdentityTest do
  @moduledoc """
  Covers the run-identity foundation: a stable run_id, an ISO-8601 run_at, the
  best-effort git context, a run-level meta.json with correct counts, and the
  non-overwriting per-run storage layout. Drives isolated, unnamed Recorder
  instances (each with its own tmp output dir) so the suite's shared Recorder is
  untouched.
  """
  use ExUnit.Case, async: false

  alias TestLens.{Git, Recorder}

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "test_lens_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # Start an isolated, unnamed recorder under ExUnit's supervisor so it is torn
  # down after the test without coupling to the test process lifecycle.
  defp start_recorder(dir, overrides \\ []) do
    opts = Keyword.merge([project: "rid", dir: dir, name: nil, git_dir: dir], overrides)

    start_supervised!(%{
      id: {:recorder, System.unique_integer([:positive])},
      start: {Recorder, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp write_case(pid, module, name, status) do
    GenServer.cast(
      pid,
      {:begin, %{module: module, name: name, pid: self(), file: __ENV__.file, line: 1, tags: []}}
    )

    {:ok, path} = GenServer.call(pid, {:finish, module, name, status, 1_000, %{}})
    path
  end

  test "each case carries an ISO-8601 run_at and a run_id stable across the run" do
    dir = tmp_dir()
    pid = start_recorder(dir)

    data = write_case(pid, RID.A, :t1, "passed") |> File.read!() |> Jason.decode!()

    assert is_binary(data["run_id"]) and data["run_id"] != ""
    assert {:ok, _dt, _off} = DateTime.from_iso8601(data["run_at"])

    data2 = write_case(pid, RID.A, :t2, "passed") |> File.read!() |> Jason.decode!()
    assert data2["run_id"] == data["run_id"]
    assert data2["run_at"] == data["run_at"]
  end

  test "git context has real fields inside a repo and is all-nil outside one" do
    here = Git.context(File.cwd!())
    assert is_binary(here.branch)
    assert is_binary(here.commit)

    nongit =
      Path.join(System.tmp_dir!(), "test_lens_nongit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(nongit)
    on_exit(fn -> File.rm_rf(nongit) end)

    assert Git.context(nongit) == %{branch: nil, commit: nil, base_ref: nil, merge_base: nil}
  end

  test "meta.json is written with the run's counts and git context" do
    dir = tmp_dir()
    git = %{branch: "feature/x", commit: "abc123", base_ref: "origin/main", merge_base: "def456"}
    pid = start_recorder(dir, git: git)

    write_case(pid, RID.M, :"ok one", "passed")
    write_case(pid, RID.M, :"ok two", "passed")
    write_case(pid, RID.M, :"bad one", "failed")

    :ok = GenServer.call(pid, :finalize)

    %{run_dir: run_dir} = GenServer.call(pid, :run_info)
    meta = Path.join(run_dir, "meta.json") |> File.read!() |> Jason.decode!()

    assert meta["schema"] == "test_lens_run/v1"
    assert meta["project"] == "rid"
    assert meta["case_count"] == 3
    assert meta["status_counts"] == %{"passed" => 2, "failed" => 1}
    assert meta["git"]["branch"] == "feature/x"
    assert {:ok, _dt, _off} = DateTime.from_iso8601(meta["run_at"])
  end

  test "two consecutive runs land in distinct directories and do not overwrite" do
    dir = tmp_dir()

    pid_a = start_recorder(dir)
    path_a = write_case(pid_a, RID.Same, :"identical name", "passed")
    %{run_dir: run_a} = GenServer.call(pid_a, :run_info)

    pid_b = start_recorder(dir)
    path_b = write_case(pid_b, RID.Same, :"identical name", "passed")
    %{run_dir: run_b} = GenServer.call(pid_b, :run_info)

    assert run_a != run_b
    assert path_a != path_b
    assert File.exists?(path_a)
    assert File.exists?(path_b)

    run_dirs = Path.wildcard(Path.join([dir, "runs", "*"])) |> Enum.filter(&File.dir?/1)
    assert run_a in run_dirs
    assert run_b in run_dirs
  end
end
