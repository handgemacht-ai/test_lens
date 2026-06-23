defmodule TestLens.Ecto do
  @moduledoc """
  Optional database-delta layer. Attaches to a repo's Ecto query telemetry and
  records mutations (INSERT/UPDATE/DELETE) onto whichever test is running in the
  query's process. Reads (SELECT) are ignored to keep the signal clean.

  Call once from test_helper.exs, after `TestLens.start/1`:

      TestLens.Ecto.attach([:havi, :repo])
  """

  alias TestLens.{JSON, Recorder}

  @doc "Attach to `<prefix> ++ [:query]` telemetry events for one repo."
  def attach(repo_prefix) when is_list(repo_prefix) do
    event = repo_prefix ++ [:query]
    handler_id = {__MODULE__, repo_prefix}
    :telemetry.detach(handler_id)
    :telemetry.attach(handler_id, event, &__MODULE__.handle/4, nil)
  end

  @doc false
  def handle(_event, _measurements, metadata, _config) do
    sql = Map.get(metadata, :query, "")

    case op(sql) do
      nil ->
        :ok

      op ->
        Recorder.add_db_event(self(), %{
          op: op,
          source: Map.get(metadata, :source),
          sql: sql,
          params: JSON.sanitize(Map.get(metadata, :params))
        })
    end
  end

  defp op(sql) when is_binary(sql) do
    case sql |> String.trim_leading() |> String.upcase() do
      "INSERT" <> _ -> "INSERT"
      "UPDATE" <> _ -> "UPDATE"
      "DELETE" <> _ -> "DELETE"
      _ -> nil
    end
  end

  defp op(_), do: nil
end
