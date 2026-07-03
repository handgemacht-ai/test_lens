defmodule TestLens.RunIdentityTest do
  @moduledoc """
  Covers the run-identity foundation: a stable run_id, an ISO-8601 run_at, the
  best-effort git context, a run-level meta.json with correct counts, and the
  non-overwriting per-run storage layout. Drives isolated, unnamed Recorder
  instances (each with its own tmp output dir) so the suite's shared Recorder is
  untouched.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and annotates the decisive values, so
  each test's *own* rendered page reads as input → action → result with the
  concrete run_id/run_at/git/meta data it produced. The block macros and
  `capture/3` route to the suite's *named* Recorder, while the subject under test
  is a separate *unnamed* Recorder reached only by pid — so recording this test's
  own page never touches the recorder it is exercising.
  """
  use ExUnit.Case, async: false
  use TestLens.Case
  require TestLens

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
    pid =
      TestLens.setup "one isolated recorder standing in for a single test run" do
        dir = tmp_dir()
        start_recorder(dir)
      end

    {data, data2} =
      TestLens.action "record two separate cases (RID.A t1, then t2) into that one run" do
        data = write_case(pid, RID.A, :t1, "passed") |> File.read!() |> Jason.decode!()
        data2 = write_case(pid, RID.A, :t2, "passed") |> File.read!() |> Jason.decode!()
        {data, data2}
      end

    TestLens.verify "both cases carry the same run_id and an ISO-8601 run_at" do
      assert is_binary(data["run_id"]) and data["run_id"] != ""
      assert {:ok, _dt, _off} = DateTime.from_iso8601(data["run_at"])

      assert data2["run_id"] == data["run_id"]
      assert data2["run_at"] == data["run_at"]

      # Spotlight the actual identity every case in the run carries, and the fact
      # that the second case reproduces it unchanged.
      TestLens.capture(
        "run identity carried on every case",
        %{
          run_id: data["run_id"],
          run_at: data["run_at"],
          second_case_run_id: data2["run_id"],
          second_case_run_at: data2["run_at"],
          stable_across_cases:
            data2["run_id"] == data["run_id"] and data2["run_at"] == data["run_at"]
        },
        annotate: [["run_id"], ["run_at"], ["stable_across_cases"]]
      )
    end
  end

  test "git context has real fields inside a repo and is all-nil outside one" do
    nongit =
      TestLens.setup "two locations to probe: this git worktree, and a fresh non-git dir" do
        path =
          Path.join(System.tmp_dir!(), "test_lens_nongit_#{System.unique_integer([:positive])}")

        File.mkdir_p!(path)
        on_exit(fn -> File.rm_rf(path) end)
        path
      end

    {here, outside} =
      TestLens.action "read the git context of each location" do
        {Git.context(File.cwd!()), Git.context(nongit)}
      end

    TestLens.verify "inside a repo the fields are real strings; outside every field is nil" do
      assert is_binary(here.branch)
      assert is_binary(here.commit)

      assert outside == %{branch: nil, commit: nil, base_ref: nil, merge_base: nil}

      # The decisive contrast: a real branch/commit inside the repo versus the
      # all-nil map outside it.
      TestLens.capture(
        "git context inside vs outside a repo",
        %{
          inside_repo: %{
            branch: here.branch,
            commit: here.commit,
            base_ref: here.base_ref,
            merge_base: here.merge_base
          },
          outside_repo: outside
        },
        annotate: [["inside_repo", "branch"], ["inside_repo", "commit"], ["outside_repo"]]
      )
    end
  end

  test "meta.json is written with the run's counts and git context" do
    {pid, git} =
      TestLens.setup "a recorder seeded with an explicit git context for the run" do
        dir = tmp_dir()

        git = %{
          branch: "feature/x",
          commit: "abc123",
          base_ref: "origin/main",
          merge_base: "def456"
        }

        # The git context injected into the run — meta.json must echo it back.
        TestLens.capture("git context injected into the run", git,
          annotate: [["branch"], ["commit"]]
        )

        {start_recorder(dir, git: git), git}
      end

    run_dir =
      TestLens.action "record three cases (2 passed, 1 failed), then finalize the run" do
        write_case(pid, RID.M, :"ok one", "passed")
        write_case(pid, RID.M, :"ok two", "passed")
        write_case(pid, RID.M, :"bad one", "failed")

        :ok = GenServer.call(pid, :finalize)
        %{run_dir: run_dir} = GenServer.call(pid, :run_info)
        run_dir
      end

    TestLens.verify "meta.json summarizes the run: counts, status split, and git" do
      meta = Path.join(run_dir, "meta.json") |> File.read!() |> Jason.decode!()

      assert meta["schema"] == "test_lens_run/v1"
      assert meta["project"] == "rid"
      assert meta["case_count"] == 3
      assert meta["status_counts"] == %{"passed" => 2, "failed" => 1}
      assert meta["git"]["branch"] == git.branch
      assert {:ok, _dt, _off} = DateTime.from_iso8601(meta["run_at"])

      # The written summary itself: the case_count, the pass/fail split, and the
      # git context carried into the file.
      TestLens.capture("meta.json written for the run", meta,
        annotate: [["case_count"], ["status_counts"], ["git", "branch"]]
      )
    end
  end

  test "two consecutive runs land in distinct directories and do not overwrite" do
    dir =
      TestLens.setup "one output root that two runs will both write into" do
        tmp_dir()
      end

    {run_a, run_b, path_a, path_b} =
      TestLens.action "run twice, each recording a case with the *same* identity" do
        pid_a = start_recorder(dir)
        path_a = write_case(pid_a, RID.Same, :"identical name", "passed")
        %{run_dir: run_a} = GenServer.call(pid_a, :run_info)

        pid_b = start_recorder(dir)
        path_b = write_case(pid_b, RID.Same, :"identical name", "passed")
        %{run_dir: run_b} = GenServer.call(pid_b, :run_info)

        {run_a, run_b, path_a, path_b}
      end

    TestLens.verify "the two runs get distinct dirs and both case files survive side by side" do
      assert run_a != run_b
      assert path_a != path_b
      assert File.exists?(path_a)
      assert File.exists?(path_b)

      run_dirs = Path.wildcard(Path.join([dir, "runs", "*"])) |> Enum.filter(&File.dir?/1)
      assert run_a in run_dirs
      assert run_b in run_dirs

      # The proof the reader needs: two distinct run dirs on disk, and both case
      # files present even though the case identity was identical.
      TestLens.capture(
        "same identity, two runs, no overwrite",
        %{
          run_a: run_a,
          run_b: run_b,
          distinct_run_dirs: run_a != run_b,
          run_dirs_on_disk: Enum.sort(run_dirs),
          case_a: path_a,
          case_b: path_b,
          both_files_exist: File.exists?(path_a) and File.exists?(path_b)
        },
        annotate: [["distinct_run_dirs"], ["run_dirs_on_disk"], ["both_files_exist"]]
      )
    end
  end
end
