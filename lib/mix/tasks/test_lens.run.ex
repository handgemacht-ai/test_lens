defmodule Mix.Tasks.TestLens.Run do
  @shortdoc "Run the ExUnit suite (with the Test Lens formatter), then build the viewer for that run"

  @moduledoc """
  One normalized command to run a project's tests and build the Test Lens viewer
  for the run they produced.

      mix test_lens.run                  # runs `mix test`, then builds the latest run
      mix test_lens.run --dir my_out     # use a non-default output root
      mix test_lens.run test/foo_test.exs --max-failures 1  # extra args pass through

  It exports `TEST_LENS_DIR=<abs dir>` and then invokes `mix test` in-process, so
  your `test/test_helper.exs` wiring (`TestLens.start/1` + `TestLens.Formatter`)
  records *this run's* cases under `<dir>` — not wherever `test_helper.exs` would
  otherwise default. It then resolves the newest run under `<dir>/runs` and
  writes its `index.html`, printing the path.

  Because the env wins over a hardcoded `dir:` in `test_helper.exs`, `--dir`
  reliably drives **both** where cases are written and where the viewer is built,
  in one invocation, with no manual relocation. `--dir` defaults to
  `test_lens_out`; all other arguments are forwarded to `mix test`.
  """

  use Mix.Task

  @switches [dir: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    dir = Path.expand(opts[:dir] || "test_lens_out")
    System.put_env("TEST_LENS_DIR", dir)
    forwarded = drop_dir(argv)

    Mix.Task.run("test", forwarded)

    case TestLens.Viewer.latest_run(dir) do
      nil ->
        Mix.shell().error(
          "test_lens: no run found under #{Path.join(dir, "runs")} — " <>
            "is TestLens.start/1 wired in test/test_helper.exs?"
        )

      run_dir ->
        {:ok, out, count} = TestLens.Viewer.build(dir: run_dir)
        meta = Path.join(run_dir, "meta.json")
        Mix.shell().info("")
        Mix.shell().info("test_lens: #{count} cases  ->  #{out}")
        if File.exists?(meta), do: Mix.shell().info("test_lens: run meta    ->  #{meta}")
    end
  end

  # Strip --dir (and --dir=...) from argv so everything else forwards to `mix test`.
  defp drop_dir([]), do: []
  defp drop_dir(["--dir", _val | rest]), do: drop_dir(rest)
  defp drop_dir(["--dir=" <> _ | rest]), do: drop_dir(rest)
  defp drop_dir([arg | rest]), do: [arg | drop_dir(rest)]
end
