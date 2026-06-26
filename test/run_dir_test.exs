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
  """
  use ExUnit.Case, async: false

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
    mix = System.find_executable("mix") || flunk("mix not found on PATH")

    out_dir = tmp("rundir_out")
    fixture = tmp("rundir_fixture") <> "_test.exs"
    File.write!(fixture, @fixture)

    {output, status} =
      System.cmd(mix, ["test_lens.run", "--dir", out_dir, fixture],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

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
      System.put_env("TEST_LENS_DIR", "/from/env")
      assert TestLens.resolve_dir(dir: "test_lens_out") == "/from/env"
    end

    test "falls back to the explicit dir: opt when env is unset" do
      System.delete_env("TEST_LENS_DIR")
      assert TestLens.resolve_dir(dir: "custom_out") == "custom_out"
    end

    test "defaults to test_lens_out with no env and no opt" do
      System.delete_env("TEST_LENS_DIR")
      assert TestLens.resolve_dir([]) == "test_lens_out"
    end

    test "a blank TEST_LENS_DIR is treated as unset" do
      System.put_env("TEST_LENS_DIR", "")
      assert TestLens.resolve_dir(dir: "custom_out") == "custom_out"
    end
  end
end
