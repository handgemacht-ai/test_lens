defmodule Mix.Tasks.TestLens.Diff do
  @shortdoc "Diff two Test Lens runs into a self-contained HTML report (+ diff.json)"

  @moduledoc """
  Compare two Test Lens runs — a BASE and a HEAD — and write a self-contained
  HTML diff plus a machine-readable `diff.json`.

      mix test_lens.diff --base <run_dir> --head <run_dir> [--out <file.html>]

  Each `<run_dir>` is a `runs/<run_id>/` directory (the one holding `meta.json`
  and `cases/`). The HTML is written to `--out` (default `<head_run_dir>/diff.html`)
  and a `diff.json` summary is always written next to it. The absolute HTML path
  is printed on stdout; the command exits 0 on success.

  Tests are matched across runs by identity (`module::name`) and grouped into
  added / removed / status-flips / changed. See `docs/diff-format.md` for the
  `diff.json` schema.

  Missing `meta.json`, empty runs, identical runs, and a base with no merge_base
  are all handled gracefully.
  """

  use Mix.Task

  @switches [base: :string, head: :string, out: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    base = require_opt(opts, :base)
    head = require_opt(opts, :head)
    require_run_dir!(base, "--base")
    require_run_dir!(head, "--head")

    {:ok, html, json, diff} = TestLens.Diff.build(base: base, head: head, out: opts[:out])

    c = diff
    Mix.shell().info("")

    Mix.shell().info(
      "test_lens diff: " <>
        "+#{length(c.added)} added  " <>
        "-#{length(c.removed)} removed  " <>
        "#{length(c.flipped)} flips  " <>
        "~#{length(c.changed)} changed  " <>
        "=#{c.unchanged} unchanged"
    )

    Mix.shell().info("test_lens diff: summary ->  #{json}")
    Mix.shell().info(html)
  end

  defp require_opt(opts, key) do
    opts[key] ||
      Mix.raise(
        "test_lens.diff: --#{key} <run_dir> is required.\n" <>
          "    Usage: mix test_lens.diff --base <run_dir> --head <run_dir> [--out <file.html>]"
      )
  end

  defp require_run_dir!(dir, flag) do
    unless File.dir?(dir) do
      Mix.raise("test_lens.diff: #{flag} #{dir} is not a directory")
    end
  end
end
