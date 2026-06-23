defmodule TestLens.DemoRequestTest do
  @moduledoc """
  Demonstrates the request/response + DB-delta shape (havi style): an HTTP call
  that returns a response and writes a row. The row insert is delivered through
  the same Ecto query telemetry the real wiring listens to — here emitted by
  hand so the demo needs no database.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  test "POST /api/annotations creates an annotation" do
    TestLens.stage(:setup)
    TestLens.capture("signed-in user", %{email: "team-member@example.com", org_id: "org_123"})

    request = %{
      method: "POST",
      path: "/api/annotations",
      headers: %{"authorization" => "Bearer <jwt>", "x-havi-workspace-id" => "org_123"},
      body: %{"annotation" => %{"type" => "Annotation", "body" => "Looks great — ship it"}}
    }

    TestLens.stage(:action)
    TestLens.capture("request", request, kind: :http_request)

    :telemetry.execute(
      [:demo, :repo, :query],
      %{total_time: 1_200_000},
      %{
        query:
          ~s|INSERT INTO "annotations" ("id","org_id","creator","state") VALUES ($1,$2,$3,$4)|,
        source: "annotations",
        params: ["ann_456", "org_123", "team-member@example.com", "open"]
      }
    )

    response = %{
      status: 201,
      headers: %{"content-type" => "application/json"},
      body: %{
        "data" => %{"id" => "ann_456", "state" => "open", "creator" => "team-member@example.com"}
      }
    }

    TestLens.stage(:verify)
    TestLens.capture("response", response, kind: :http_response)
    assert response.status == 201
  end
end
