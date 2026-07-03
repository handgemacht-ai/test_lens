defmodule TestLens.ViewerCase do
  @moduledoc """
  Test helpers for exercising the recorder and building an **isolated** viewer.

  The recorder is a suite-wide singleton pointed at the shared `test_lens_out`,
  so building the viewer straight from that dir folds in every other test's
  cases — an assertion on the rendered page could then be satisfied by a value
  some *other* test recorded, and `runs/` grows every invocation. These helpers
  copy the case file(s) a single test just recorded into a throwaway run
  directory and build the viewer from there, so the rendered page (and the JSON
  payload embedded in it) contains only this test's cases and is removed when
  the test finishes.
  """

  @doc "A unique tmp directory, removed when the calling test finishes."
  @spec tmp_dir(String.t()) :: String.t()
  def tmp_dir(tag \\ "test_lens") do
    path = Path.join(System.tmp_dir!(), "#{tag}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @doc """
  Build an isolated viewer from recorded case file paths (each the `{:ok, path}`
  payload of `TestLens.Recorder.finish/5`) and return the rendered HTML. The
  viewer sees only these cases, so its embedded payload is exactly this test's
  data.
  """
  @spec build_isolated([Path.t()]) :: String.t()
  def build_isolated([_ | _] = case_paths) do
    run = tmp_dir("test_lens_view")
    cases = Path.join(run, "cases")
    File.mkdir_p!(cases)

    Enum.each(case_paths, fn path ->
      File.cp!(path, Path.join(cases, Path.basename(path)))
    end)

    {:ok, html_path, _count} = TestLens.Viewer.build(dir: run)
    File.read!(html_path)
  end

  @doc """
  The decoded JSON payload embedded in a rendered viewer/diff page's
  `<script id="data">` block — exactly the data the page renders from. An empty
  viewer embeds `[]`, so asserting on this fails when nothing was rendered.
  """
  @spec data_payload(String.t()) :: term()
  def data_payload(html) do
    [_, json] =
      Regex.run(~r|<script id="data" type="application/json">(.*?)</script>|s, html)

    Jason.decode!(json)
  end
end
