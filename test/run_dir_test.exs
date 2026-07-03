defmodule TestLens.RunDirTest do
  @moduledoc """
  End-to-end proof that `mix test_lens.run --dir X` records *this run's* cases
  under `X` — not under whatever `dir:` `test/test_helper.exs` would otherwise
  default to. This repo's own `test_helper.exs` hardcodes `dir: "test_lens_out"`,
  so a green run here also proves the `TEST_LENS_DIR` env override beats a
  hardcoded `dir:`.

  Runs the real task in a child `mix` process pointed at a throwaway fixture
  file, so it exercises the whole `--dir` → `TEST_LENS_DIR` → recorder → viewer
  path without re-entering this suite.

  This file also dogfoods TestLens on itself: each test wraps its flow in the
  `setup`/`action`/`verify` block macros and captures the decisive values (the
  chosen dir `X`, the child exit status, the resolved dir), so each test's own
  rendered page reads as input → action → result with concrete data. Recording
  here is inert with respect to what is under test: captures cast to the suite
  recorder (booted at a fixed dir in `test_helper.exs`), and `resolve_dir/1` is a
  pure function — mutating `TEST_LENS_DIR` mid-test never redirects our own
  recording.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  @fixture """
  defmodule TestLensRunDirFixtureTest do
    use ExUnit.Case, async: false
    test "fixture passes", do: assert(1 + 1 == 2)
  end
  """

  defp tmp(name) do
    path = Path.join(System.tmp_dir!(), "test_lens_#{name}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "mix test_lens.run --dir X lands a complete run under X" do
    TestLens.setup "a throwaway fixture suite, and a fresh empty --dir target X" do
      mix = System.find_executable("mix") || flunk("mix not found on PATH")

      out_dir = tmp("rundir_out")
      fixture = tmp("rundir_fixture") <> "_test.exs"
      File.write!(fixture, @fixture)

      # X (`out_dir`) is the input under test: the dir the run must land under.
      TestLens.capture(
        "run inputs",
        %{dir_X: out_dir, fixture: Path.basename(fixture), fixture_source: @fixture},
        annotate: [["dir_X"]]
      )
    end

    TestLens.action "mix test_lens.run --dir X <fixture>  (a real child mix process)" do
      {output, status} =
        System.cmd(mix, ["test_lens.run", "--dir", out_dir, fixture],
          cd: File.cwd!(),
          stderr_to_stdout: true
        )

      # The acted-on thing: the child task and its exit status (0 == it ran).
      TestLens.capture(
        "child mix result",
        %{
          command: "mix test_lens.run --dir #{out_dir} #{fixture}",
          exit_status: status,
          output_tail:
            output
            |> String.trim_trailing()
            |> String.split("\n")
            |> Enum.take(-6)
            |> Enum.join("\n")
        },
        annotate: [["exit_status"]]
      )
    end

    TestLens.verify "a complete run landed under X: runs/latest → run_id → meta.json + index.html + cases" do
      assert status == 0, "mix test_lens.run failed (#{status}):\n#{output}"

      # cases were written under the chosen dir, not test_lens_out
      runs = Path.join(out_dir, "runs")
      assert File.dir?(runs), "no runs/ under chosen dir:\n#{output}"

      latest = Path.join(runs, "latest")
      assert File.regular?(latest), "no runs/latest pointer:\n#{output}"
      run_id = latest |> File.read!() |> String.trim()
      assert run_id != ""

      run_dir = Path.join(runs, run_id)
      assert File.exists?(Path.join(run_dir, "meta.json"))
      assert File.exists?(Path.join(run_dir, "index.html"))

      cases = Path.wildcard(Path.join(run_dir, "cases/*.json"))
      assert cases != [], "no case files under #{run_dir}:\n#{output}"

      meta = run_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
      assert meta["case_count"] >= 1

      # The verified outcome: what "complete" means here — a run_id under X with a
      # meta.json (case_count), a viewer, and ≥1 case file. Shows exactly which
      # files the child created, relative to X.
      TestLens.capture(
        "landed run under X",
        %{
          dir_X: out_dir,
          run_id: run_id,
          case_count: meta["case_count"],
          files:
            [latest, Path.join(run_dir, "meta.json"), Path.join(run_dir, "index.html") | cases]
            |> Enum.map(&Path.relative_to(&1, out_dir))
        },
        annotate: [["run_id"], ["case_count"]]
      )
    end
  end

  describe "resolve_dir/1 precedence" do
    setup do
      prior = System.get_env("TEST_LENS_DIR")

      on_exit(fn ->
        if prior,
          do: System.put_env("TEST_LENS_DIR", prior),
          else: System.delete_env("TEST_LENS_DIR")
      end)
    end

    test "TEST_LENS_DIR wins over a hardcoded dir: opt" do
      TestLens.setup "TEST_LENS_DIR set to /from/env, and an explicit dir: opt also present" do
        System.put_env("TEST_LENS_DIR", "/from/env")

        # Both inputs are present; the env var is the deciding one, so spotlight it.
        TestLens.capture(
          "resolve_dir inputs",
          %{TEST_LENS_DIR: System.get_env("TEST_LENS_DIR"), dir_opt: "test_lens_out"},
          annotate: [["TEST_LENS_DIR"]]
        )
      end

      TestLens.action "TestLens.resolve_dir/1 with both env and opt present" do
        resolved = TestLens.resolve_dir(dir: "test_lens_out")
      end

      TestLens.verify "the env var wins over the hardcoded opt" do
        assert resolved == "/from/env"
        # The verified outcome, shown verbatim: what resolve_dir/1 returned.
        TestLens.capture("resolved dir", resolved)
      end
    end

    test "falls back to the explicit dir: opt when env is unset" do
      TestLens.setup "TEST_LENS_DIR unset; only an explicit dir: opt is given" do
        System.delete_env("TEST_LENS_DIR")

        # With the env gone, the opt is the deciding input.
        TestLens.capture(
          "resolve_dir inputs",
          %{TEST_LENS_DIR: System.get_env("TEST_LENS_DIR"), dir_opt: "custom_out"},
          annotate: [["dir_opt"]]
        )
      end

      TestLens.action "TestLens.resolve_dir/1 with no env, one opt" do
        resolved = TestLens.resolve_dir(dir: "custom_out")
      end

      TestLens.verify "falls back to the explicit dir: opt" do
        assert resolved == "custom_out"
        TestLens.capture("resolved dir", resolved)
      end
    end

    test "defaults to test_lens_out with no env and no opt" do
      TestLens.setup "neither TEST_LENS_DIR nor a dir: opt is given" do
        System.delete_env("TEST_LENS_DIR")

        # No single decisive input here (both absent), so nothing is spotlit; the
        # returned default is the subject, shown below.
        TestLens.capture(
          "resolve_dir inputs",
          %{TEST_LENS_DIR: System.get_env("TEST_LENS_DIR"), dir_opt: nil}
        )
      end

      TestLens.action "TestLens.resolve_dir/1 with empty opts" do
        resolved = TestLens.resolve_dir([])
      end

      TestLens.verify "defaults to test_lens_out" do
        assert resolved == "test_lens_out"
        TestLens.capture("resolved dir", resolved)
      end
    end

    test "a blank TEST_LENS_DIR is treated as unset" do
      TestLens.setup "TEST_LENS_DIR set to a blank string, with an explicit dir: opt present" do
        System.put_env("TEST_LENS_DIR", "")

        # The blank env value is the edge case under test; spotlight it so the
        # readout shows `TEST_LENS_DIR = ""` (not an absent key).
        TestLens.capture(
          "resolve_dir inputs",
          %{TEST_LENS_DIR: System.get_env("TEST_LENS_DIR"), dir_opt: "custom_out"},
          annotate: [["TEST_LENS_DIR"]]
        )
      end

      TestLens.action "TestLens.resolve_dir/1 with a blank env and an opt" do
        resolved = TestLens.resolve_dir(dir: "custom_out")
      end

      TestLens.verify "a blank env is treated as unset, so the opt is used" do
        assert resolved == "custom_out"
        TestLens.capture("resolved dir", resolved)
      end
    end
  end
end
