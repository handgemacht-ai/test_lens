defmodule TestLens.Phoenix do
  @moduledoc """
  Optional HTTP-capture layer for Phoenix. Attaches to the endpoint's telemetry
  and records the request (method, path, params) and the response (status, body)
  onto whichever test is running in the dispatch process — so controller and
  integration tests render as input → action → result with no per-test changes.

  In `Phoenix.ConnTest` the request is dispatched synchronously in the test
  process, so the handler runs there and captures land on the right test. Call
  once from `test/test_helper.exs`, after `TestLens.start/1`:

      TestLens.Phoenix.attach()

  There is no compile-time dependency on Phoenix — this only listens for the
  standard `[:phoenix, :endpoint, :stop]` event by name and reads plain `conn`
  fields. Values under obviously sensitive keys (password, token, secret,
  authorization, api key) are redacted before they are recorded.
  """

  alias TestLens.{JSON, Recorder}

  @event [:phoenix, :endpoint, :stop]
  @max_body 8_000
  @redact ~r/pass|token|secret|authorization|api[_-]?key|credential/i

  @doc """
  Attach to Phoenix endpoint telemetry. Pass a custom event list if your endpoint
  emits under a different prefix (defaults to `[:phoenix, :endpoint, :stop]`).
  """
  def attach(event \\ @event) when is_list(event) do
    handler_id = {__MODULE__, event}
    :telemetry.detach(handler_id)
    :telemetry.attach(handler_id, event, &__MODULE__.handle/4, nil)
  end

  @doc false
  def handle(_event, _measurements, %{conn: conn}, _config), do: record(conn)
  def handle(_event, _measurements, _metadata, _config), do: :ok

  # A raise here would make :telemetry detach the handler for the rest of the
  # run, so one odd conn must never take the whole suite's capture down with it.
  defp record(conn) do
    do_record(conn)
  rescue
    _ -> :ok
  end

  defp do_record(conn) do
    pid = self()

    request = %{
      method: Map.get(conn, :method),
      path: Map.get(conn, :request_path),
      body: redact(Map.get(conn, :params))
    }

    request =
      case Map.get(conn, :query_string) do
        q when is_binary(q) and q != "" -> Map.put(request, :path, "#{request.path}?#{q}")
        _ -> request
      end

    Recorder.add_capture(pid, label(conn), "http_request", request, :action)

    response = %{
      status: Map.get(conn, :status),
      body: redact(response_body(conn))
    }

    Recorder.add_capture(pid, "response", "http_response", response, :verify)
  end

  defp label(conn), do: "#{Map.get(conn, :method)} #{Map.get(conn, :request_path)}"

  # Parse the response body as JSON when it looks like JSON; otherwise keep a
  # bounded string so a large HTML page can't bloat the render. resp_body is
  # iodata and is frequently an improper iolist (binary tail) for rendered
  # pages, so flatten it to a binary first rather than walking it as a list.
  defp response_body(conn) do
    case Map.get(conn, :resp_body) do
      nil ->
        nil

      body ->
        trimmed = body |> to_binary() |> String.slice(0, @max_body)

        case Jason.decode(trimmed) do
          {:ok, decoded} -> decoded
          _ -> trimmed
        end
    end
  end

  defp to_binary(body) when is_binary(body), do: body

  defp to_binary(body) do
    IO.iodata_to_binary(body)
  rescue
    _ -> inspect(body)
  end

  # Recursively blank out values whose key looks sensitive. Runs before
  # JSON.sanitize, which handles everything else (structs, tuples, atoms…).
  defp redact(value), do: value |> do_redact() |> JSON.sanitize()

  defp do_redact(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if sensitive?(k), do: {k, "[redacted]"}, else: {k, do_redact(v)}
    end)
  end

  defp do_redact(list) when is_list(list), do: Enum.map(list, &do_redact/1)
  defp do_redact(other), do: other

  defp sensitive?(key) when is_atom(key), do: sensitive?(Atom.to_string(key))
  defp sensitive?(key) when is_binary(key), do: Regex.match?(@redact, key)
  defp sensitive?(_), do: false
end
