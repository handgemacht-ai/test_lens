defmodule TestLens.DemoPhoenixTest do
  @moduledoc """
  Phoenix request/response tests, dogfooded so each rendered page explains itself.

  `TestLens.Phoenix.attach()` (wired once in test_helper) turns the standard
  `[:phoenix, :endpoint, :stop]` telemetry into request/response captures with no
  per-test code — so the HTTP request and response land on the page for free.
  These demos emit that event by hand, so no running endpoint is needed. On top
  of the free captures, each test adds only framing (setup/action/verify blocks)
  and a few annotations, so a newcomer can read what is set up, what happens, and
  what is checked — with which concrete data. Sensitive fields (password, token)
  are redacted before they are recorded.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.Recorder

  test "POST /api/sessions signs a user in" do
    TestLens.setup do
      # A team member is already provisioned. The sign-in must resolve to this
      # exact account (same id and email) — not just return any 201.
      account = %{id: "usr_1", email: "team-member@example.com"}
    end

    TestLens.capture("provisioned account", account, annotate: [[:id]])

    conn = %{
      method: "POST",
      request_path: "/api/sessions",
      query_string: "",
      params: %{"email" => account.email, "password" => "hunter2"},
      status: 201,
      resp_body:
        ~s|{"data":{"token":"jwt-abc","user":{"id":"usr_1","email":"team-member@example.com"}}}|
    }

    TestLens.action "POST /api/sessions with the account's credentials" do
      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_200_000}, %{conn: conn})
    end

    TestLens.verify do
      signed_in = Jason.decode!(conn.resp_body)["data"]["user"]

      assert conn.status == 201
      assert signed_in == %{"id" => account.id, "email" => account.email}
    end
  end

  test "the written case redacts the request password and response token" do
    module = TestLens.DemoPhoenixTest.RedactionSynthetic
    name = :"test written case is redacted"

    conn = %{
      method: "POST",
      request_path: "/api/sessions",
      query_string: "",
      params: %{"email" => "team-member@example.com", "password" => "hunter2"},
      status: 201,
      resp_body:
        ~s|{"data":{"token":"jwt-abc","user":{"id":"usr_1","email":"team-member@example.com"}}}|
    }

    TestLens.setup do
      # The plaintext secrets riding along in this request/response. The recorder
      # must never let these reach the written case.
      secrets = %{request_password: "hunter2", response_token: "jwt-abc"}
    end

    TestLens.capture("secrets in the request and response", secrets,
      annotate: [[:request_password], [:response_token]]
    )

    TestLens.action "record the case in a throwaway process, then read it from disk" do
      # Drive the recorder from a separate pid so recording this synthetic case
      # can't hijack THIS test's own capture — they would otherwise share a pid.
      task =
        Task.async(fn ->
          Recorder.begin(%{
            module: module,
            name: name,
            pid: self(),
            file: __ENV__.file,
            line: __ENV__.line,
            tags: []
          })

          :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_200_000}, %{conn: conn})
          :ok
        end)

      Task.await(task)

      assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
      json = File.read!(path)
    end

    TestLens.verify do
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

    TestLens.capture(
      "the same fields as written to disk",
      %{
        request_password: request["value"]["body"]["password"],
        request_email: request["value"]["body"]["email"],
        response_token: response["value"]["body"]["data"]["token"]
      },
      annotate: [[:request_password], [:response_token]]
    )
  end

  test "a rendered page (improper iolist body) does not detach the handler" do
    handler_id = {TestLens.Phoenix, [:phoenix, :endpoint, :stop]}

    TestLens.setup do
      # Plug hands rendered pages an improper iolist (binary tail) — the shape
      # that previously crashed the handler and silenced capture for the run.
      conn = %{
        method: "GET",
        request_path: "/pricing",
        query_string: "",
        params: %{},
        status: 200,
        resp_body: ["<h1>", "Plans" | "&#39;s</h1>"]
      }
    end

    TestLens.capture("improper iolist response body", %{resp_body: inspect(conn.resp_body)},
      annotate: [[:resp_body]]
    )

    TestLens.action "dispatch the odd response through the endpoint telemetry" do
      :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 900_000}, %{conn: conn})
    end

    TestLens.verify do
      still_attached =
        Enum.any?(
          :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
          &(&1.id == handler_id)
        )

      assert still_attached, "the odd response detached the capture handler"

      TestLens.capture(
        "capture handler after the odd response",
        %{handler: inspect(handler_id), still_attached: still_attached},
        annotate: [[:still_attached]]
      )
    end
  end
end
