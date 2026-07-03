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

  alias TestLens.Recorder

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

  test "the written case redacts the request password and response token" do
    module = TestLens.DemoPhoenixTest.RedactionSynthetic
    name = :"test written case is redacted"

    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

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

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    json = File.read!(path)

    assert String.contains?(json, "[redacted]"),
           "expected the redaction marker in the written case"

    refute String.contains?(json, "hunter2"),
           "the request password leaked into the written case"

    refute String.contains?(json, "jwt-abc"),
           "the response token leaked into the written case"

    data = Jason.decode!(json)
    request = Enum.find(data["captures"], &(&1["kind"] == "http_request"))
    response = Enum.find(data["captures"], &(&1["kind"] == "http_response"))

    assert request["value"]["body"]["password"] == "[redacted]"
    assert request["value"]["body"]["email"] == "team-member@example.com"
    assert response["value"]["body"]["data"]["token"] == "[redacted]"
  end

  test "a rendered page (improper iolist body) does not detach the handler" do
    handler_id = {TestLens.Phoenix, [:phoenix, :endpoint, :stop]}

    conn = %{
      method: "GET",
      request_path: "/pricing",
      query_string: "",
      params: %{},
      status: 200,
      # Plug hands rendered pages an improper iolist (binary tail), the shape
      # that previously crashed the handler and silenced capture for the run.
      resp_body: ["<h1>", "Plans" | "&#39;s</h1>"]
    }

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 900_000}, %{conn: conn})

    assert Enum.any?(
             :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
             &(&1.id == handler_id)
           )
  end
end
