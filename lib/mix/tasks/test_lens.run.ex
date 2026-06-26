defmodule Mix.Tasks.TestLens.Run do
  @shortdoc "Run the ExUnit suite (with the Test Lens formatter), then build the viewer for that run"

  @moduledoc """
  One normalized command to run a project's tests and build the Test Lens viewer
  for the run they produced.

      mix test_lens.run                  # runs `mix test`, then builds the latest run
      mix test_lens.run --dir my_out     # use a non-default output root
      mix test_lens.run test/foo_test.exs --max-failures 1  # extra args pass through

  It invokes `mix test` (so your `test/test_helper.exs` wiring — `TestLens.start/1`
  plus the `TestLens.Formatter` — drives capture as usual), then resolves the
  newest run under `<dir>/runs` and writes its `index.html`, printing the path.

  `--dir` must match the `dir:` you pass to `TestLens.start/1` (default
  `test_lens_out`). All other arguments are forwarded to `mix test`.
  """

  use Mix.Task

  @switches [dir: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    dir = opts[:dir] || "test_lens_out"
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
