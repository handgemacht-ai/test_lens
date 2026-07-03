defmodule TestLens.RedactionTest do
  @moduledoc """
  Proves the Phoenix capture layer redacts secrets in the *written* case JSON
  after the reorder that runs redaction on the sanitized (plain) tree. Sanitize
  flattens structs to maps and tuples to lists, so a secret-named field carried
  inside a struct or a tuple — which the pre-sanitize walk skipped — is now
  blanked. Atom and string keys are both covered because sanitize stringifies
  every key. Drives the real Recorder + telemetry handler and reads the file.
  """
  use ExUnit.Case, async: false

  alias TestLens.Recorder

  defmodule Credentials do
    @moduledoc false
    defstruct [:api_key, :user]
  end

  defp write_conn(module, name, conn) do
    Recorder.begin(%{
      module: module,
      name: name,
      pid: self(),
      file: __ENV__.file,
      line: __ENV__.line,
      tags: []
    })

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})

    assert {:ok, path} = Recorder.finish(module, name, "passed", 1_000)
    json = File.read!(path)
    {json, Jason.decode!(json)}
  end

  defp request_body(data) do
    data["captures"]
    |> Enum.find(&(&1["kind"] == "http_request"))
    |> get_in(["value", "body"])
  end

  test "secrets in structs, tuples, deep maps, and atom/string keys are all redacted" do
    conn = %{
      method: "POST",
      request_path: "/api/things",
      query_string: "",
      params: %{
        # struct-valued param carrying a secret-named field (flattened by sanitize)
        "creds" => %Credentials{api_key: "sk-live-SECRET", user: "alice"},
        # tuple-carrying param: the tuple wraps a map that holds a secret
        "signed" => {:ok, %{"password" => "hunter2"}},
        # deeply nested maps with a secret at the bottom
        "deep" => %{"a" => %{"b" => %{"c" => %{"token" => "deep-jwt"}}}},
        # string-keyed secret
        "authorization" => "Bearer plain-token",
        # a non-secret that must survive untouched
        "email" => "alice@example.com",
        # atom-keyed secret (keyword entries must come last in a map literal)
        secret: "atom-secret-val"
      },
      status: 201,
      resp_body: ~s|{"ok":true}|
    }

    {json, data} = write_conn(TestLens.RedactionTest.Mixed, :"test mixed redaction", conn)

    # No secret literal survives anywhere in the serialized case.
    for secret <- ["sk-live-SECRET", "hunter2", "deep-jwt", "atom-secret-val", "plain-token"] do
      refute String.contains?(json, secret), "secret #{inspect(secret)} leaked into the case"
    end

    assert String.contains?(json, "[redacted]")

    body = request_body(data)

    # struct field: secret blanked, non-secret field and struct tag preserved
    assert body["creds"]["api_key"] == "[redacted]"
    assert body["creds"]["user"] == "alice"
    assert body["creds"]["__struct__"] == inspect(Credentials)

    # tuple → list; the map inside keeps its keys so the secret is reachable/blanked
    assert body["signed"] == ["ok", %{"password" => "[redacted]"}]

    # deep nesting is walked to the bottom
    assert body["deep"]["a"]["b"]["c"]["token"] == "[redacted]"

    # atom-keyed and string-keyed secrets are both blanked
    assert body["secret"] == "[redacted]"
    assert body["authorization"] == "[redacted]"

    # a non-sensitive value is left exactly as-is
    assert body["email"] == "alice@example.com"
  end

  test "sensitive keys in tuple / keyword-list positions are redacted, not walked as data" do
    # These are the shapes JSON.sanitize flattens to a bare [key, value] list,
    # destroying the key position redaction keys off of. This is exactly the
    # req_headers shape ([{"authorization", "Bearer …"}, …]) the capture layer
    # is about to start reading, so the secret must never reach disk.
    conn = %{
      method: "POST",
      request_path: "/api/things",
      query_string: "",
      params: %{
        # bare {key, value} tuple, e.g. a single header pair
        "auth_header" => {"authorization", "Bearer tuple-SECRET"},
        # list of header-shaped tuples
        "headers" => [
          {"authorization", "Bearer list-SECRET"},
          {"content-type", "application/json"}
        ],
        # keyword list carrying a secret-named key
        "opts" => [api_key: "kw-SECRET", timeout: 5000]
      },
      status: 200,
      resp_body: nil
    }

    {json, data} = write_conn(TestLens.RedactionTest.Tuples, :"test tuple redaction", conn)

    for secret <- ["Bearer tuple-SECRET", "Bearer list-SECRET", "kw-SECRET"] do
      refute String.contains?(json, secret), "secret #{inspect(secret)} leaked into the case"
    end

    body = request_body(data)

    # bare tuple → [key, value]: value blanked, non-sensitive key preserved
    assert body["auth_header"] == ["authorization", "[redacted]"]

    # header list: the authorization pair is blanked, the innocent pair survives
    assert body["headers"] == [
             ["authorization", "[redacted]"],
             ["content-type", "application/json"]
           ]

    # keyword list: api_key blanked, non-sensitive entry left intact
    assert body["opts"] == [["api_key", "[redacted]"], ["timeout", 5000]]
  end

  test "a bare secret string is not blanked (redaction is key-driven, not value-scanning)" do
    conn = %{
      method: "POST",
      request_path: "/api/things",
      query_string: "",
      params: %{"note" => "my password is hunter2"},
      status: 200,
      resp_body: nil
    }

    {_json, data} = write_conn(TestLens.RedactionTest.KeyDriven, :"test key driven", conn)

    # The key "note" is not sensitive, so its value is preserved verbatim — this
    # pins the intended behavior: redaction keys off field names, not contents.
    assert request_body(data)["note"] == "my password is hunter2"
  end
end
