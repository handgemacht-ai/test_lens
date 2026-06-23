defmodule TestLens.Formatter do
  @moduledoc """
  ExUnit formatter that flushes each finished test to a JSON case, tagging it
  with the real pass/fail status ExUnit assigns. Add it alongside the default:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])
  """
  use GenServer

  alias TestLens.Recorder

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_finished, test}, state) do
    Recorder.finish(test.module, test.name, status(test.state), test.time)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp status(nil), do: "passed"
  defp status({:failed, _}), do: "failed"
  defp status({:skipped, _}), do: "skipped"
  defp status({:excluded, _}), do: "excluded"
  defp status({:invalid, _}), do: "invalid"
  defp status(_), do: "unknown"
end
