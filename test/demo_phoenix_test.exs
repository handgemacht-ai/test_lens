defmodule TestLens.DemoPhoenixTest do
  @moduledoc """
  Demonstrates the zero-touch Phoenix path: the test body makes no TestLens calls
  at all. In a real suite, dispatching through `Phoenix.ConnTest` emits the
  standard `[:phoenix, :endpoint, :stop]` telemetry, which `TestLens.Phoenix`
  turns into the request/response captures. Here the event is emitted by hand so
  the demo needs no running endpoint. Sensitive fields (password, token) are
  redacted before they are recorded.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  test "POST /api/sessions signs a user in" do
    conn = %{
      method: "POST",
      request_path: "/api/sessions",
      query_string: "",
      params: %{"email" => "team-member@example.com", "password" => "hunter2"},
      status: 201,
      resp_body:
        ~s|{"data":{"token":"jwt-abc","user":{"id":"usr_1","email":"team-member@example.com"}}}|
    }

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_200_000}, %{conn: conn})

    assert conn.status == 201
  end
end
