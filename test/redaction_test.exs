defmodule TestLens.RedactionTest do
  @moduledoc """
  Proves the Phoenix capture layer redacts secrets in the *written* case JSON
  after the reorder that runs redaction on the sanitized (plain) tree. Sanitize
  flattens structs to maps and tuples to lists, so a secret-named field carried
  inside a struct or a tuple — which the pre-sanitize walk skipped — is now
  blanked. Atom and string keys are both covered because sanitize stringifies
  every key. Drives the real Recorder + telemetry handler and reads the file.

  This file also dogfoods TestLens on itself, so a newcomer can read each test's
  rendered page as input → action → result. The subtlety: `write_conn` drives a
  *synthetic* case (begin/finish) whose `begin` would otherwise steal `self()`
  and whose `finish` forgets it — dropping any of this test's own readouts. So
  `write_conn` runs that synthetic flow in an isolated `Task` (a separate pid).
  The redaction under test (`JSON.sanitize` + key-driven blanking) is pure and
  process-independent, so isolating the driver pid changes nothing about the
  written case — it only keeps this test's own `setup`/`action`/`verify` blocks
  and its before/after captures recorded on the test pid.
  """
  use ExUnit.Case, async: false
  use TestLens.Case

  alias TestLens.Recorder

  defmodule Credentials do
    @moduledoc false
    defstruct [:api_key, :user]
  end

  defp write_conn(module, name, conn) do
    # Drive the synthetic case's begin → telemetry → finish in a separate process
    # so it claims *that* pid. The synthetic `finish` forgets its own pid, so on
    # the test pid this module's `use TestLens.Case` recording survives intact.
    finish =
      Task.async(fn ->
        Recorder.begin(%{
          module: module,
          name: name,
          pid: self(),
          file: __ENV__.file,
          line: __ENV__.line,
          tags: []
        })

        :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000_000}, %{conn: conn})

        Recorder.finish(module, name, "passed", 1_000)
      end)
      |> Task.await()

    assert {:ok, path} = finish
    json = File.read!(path)
    {json, Jason.decode!(json)}
  end

  defp request_body(data) do
    data["captures"]
    |> Enum.find(&(&1["kind"] == "http_request"))
    |> get_in(["value", "body"])
  end

  test "secrets in structs, tuples, deep maps, and atom/string keys are all redacted" do
    TestLens.setup "a POST whose params hide secrets in a struct, a tuple, a deep map, and under both atom and string keys" do
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
    end

    # BEFORE: the concrete secret in every shape sanitize flattens (struct field,
    # tuple element, deep-map leaf, atom key, string key). Gold readouts point at
    # each secret's location so the reader sees exactly what goes in.
    TestLens.capture("request params before redaction (a secret in every shape)", conn.params,
      annotate: [
        ["creds", "api_key"],
        ["signed", 1, "password"],
        ["deep", "a", "b", "c", "token"],
        ["authorization"],
        ["secret"]
      ]
    )

    TestLens.action "record the conn through the real Recorder + Phoenix telemetry handler, then read the written case JSON back" do
      {json, data} = write_conn(TestLens.RedactionTest.Mixed, :"test mixed redaction", conn)
    end

    TestLens.verify do
      # No secret literal survives anywhere in the serialized case.
      for secret <- ["sk-live-SECRET", "hunter2", "deep-jwt", "atom-secret-val", "plain-token"] do
        refute String.contains?(json, secret), "secret #{inspect(secret)} leaked into the case"
      end

      assert String.contains?(json, "[redacted]")

      body = request_body(data)

      # AFTER: the same locations now read [redacted]; the non-secret survives.
      # Same annotate paths as the before-readout, so the reader can line up each
      # secret against its blanked result.
      TestLens.capture("redacted request body written to the case (after redaction)", body,
        annotate: [
          ["creds", "api_key"],
          ["signed", 1, "password"],
          ["deep", "a", "b", "c", "token"],
          ["authorization"],
          ["secret"]
        ]
      )

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
  end

  test "sensitive keys in tuple / keyword-list positions are redacted, not walked as data" do
    TestLens.setup "params whose secrets sit in [key, value] positions sanitize flattens tuples and keyword lists to — the exact req_headers shape (an authorization pair)" do
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
    end

    # BEFORE: each secret sits in the value slot of a flattened [key, value] pair.
    # Readouts point at the value position that must be recognized as a key-driven
    # secret, not walked as plain list data.
    TestLens.capture(
      "request params before redaction (secrets in tuple / keyword-list positions)",
      conn.params,
      annotate: [
        ["auth_header", 1],
        ["headers", 0, 1],
        ["opts", 0, 1]
      ]
    )

    TestLens.action "record the conn through the real Recorder + Phoenix telemetry handler, then read the written case JSON back" do
      {json, data} = write_conn(TestLens.RedactionTest.Tuples, :"test tuple redaction", conn)
    end

    TestLens.verify do
      for secret <- ["Bearer tuple-SECRET", "Bearer list-SECRET", "kw-SECRET"] do
        refute String.contains?(json, secret), "secret #{inspect(secret)} leaked into the case"
      end

      body = request_body(data)

      # AFTER: the value in each sensitive pair is blanked, while the non-sensitive
      # key names and the innocent content-type / timeout pairs survive untouched.
      TestLens.capture("redacted request body written to the case (after redaction)", body,
        annotate: [
          ["auth_header", 1],
          ["headers", 0, 1],
          ["opts", 0, 1]
        ]
      )

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
  end

  test "a bare secret string is not blanked (redaction is key-driven, not value-scanning)" do
    TestLens.setup "a param under a non-sensitive key whose *value* mentions a password" do
      conn = %{
        method: "POST",
        request_path: "/api/things",
        query_string: "",
        params: %{"note" => "my password is hunter2"},
        status: 200,
        resp_body: nil
      }
    end

    # BEFORE: the secret-looking text lives under the innocuous key "note".
    TestLens.capture(
      "request params before redaction (secret-looking text under a non-sensitive key)",
      conn.params,
      annotate: [["note"]]
    )

    TestLens.action "record the conn through the real Recorder + Phoenix telemetry handler, then read the written case JSON back" do
      {_json, data} = write_conn(TestLens.RedactionTest.KeyDriven, :"test key driven", conn)
    end

    TestLens.verify do
      body = request_body(data)

      # AFTER: the value is carried through verbatim — redaction keyed off the key
      # name, which is not sensitive, so the string content was never scanned.
      TestLens.capture("request body written to the case (value preserved verbatim)", body,
        annotate: [["note"]]
      )

      # The key "note" is not sensitive, so its value is preserved verbatim — this
      # pins the intended behavior: redaction keys off field names, not contents.
      assert body["note"] == "my password is hunter2"
    end
  end
end
