defmodule TestLens.Formatter do
  @moduledoc """
  ExUnit formatter that flushes each finished test to a JSON case, tagging it
  with the real pass/fail status ExUnit assigns. On `:suite_finished` it asks
  the recorder to flush the run-level `meta.json`. Add it alongside the default:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])
  """
  use GenServer

  alias TestLens.Recorder

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_finished, test}, state) do
    Recorder.finish(test.module, test.name, status(test.state), test.time, meta(test))
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _times}, state) do
    Recorder.finalize()
    {:noreply, state}
  end

  def handle_cast({:suite_finished, _run_us, _load_us}, state) do
    Recorder.finalize()
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # What the formatter knows even when the test never called begin/1 — enough to
  # write a status-only case for suites with no shared case module.
  defp meta(test) do
    tags = test.tags || %{}

    %{
      file: tags[:file],
      line: tags[:line],
      tags: tags |> Map.get(:registered, %{}) |> Map.keys() |> Enum.map(&to_string/1)
    }
  end

  defp status(nil), do: "passed"
  defp status({:failed, _}), do: "failed"
  defp status({:skipped, _}), do: "skipped"
  defp status({:excluded, _}), do: "excluded"
  defp status({:invalid, _}), do: "invalid"
  defp status(_), do: "unknown"
end
