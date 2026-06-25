defmodule TestLens do
  @moduledoc """
  Capture what a test actually does — its input, action and result — and write
  it out as a structured "case" that a viewer can render as input → action →
  output, without rewriting the test.

  Two projects can share this one library. The portable core is value capture at
  stage boundaries (`stage/1` + `capture/3`). An optional database-delta layer
  (`TestLens.Ecto`) enriches cases for projects that run on a clean Ecto repo.

  ## Wiring (in `test/test_helper.exs`)

      TestLens.start(project: "havi", dir: "test_lens_out")
      ExUnit.start(formatters: [ExUnit.CLIFormatter, TestLens.Formatter])

  ## Using it in a test

      use TestLens.Case   # auto-begins a capture per test

      test "creates an annotation", ctx do
        TestLens.setup do
          user = sign_in()
        end

        TestLens.action "POST /api/annotations" do
          conn = post(conn, ~p"/api/annotations", params)
        end

        TestLens.verify do
          assert conn.status == 201
          TestLens.capture("response", json(conn), annotate: [["data", "id"]])
        end
      end

  Each `setup`/`action`/`verify` block runs as written — it just also copies its
  own source into the matching channel so the viewer shows *what the test does*.
  Variables a block binds stay in scope for the rest of the test. Reach for
  `capture/3` (with `annotate:`) when one specific value is the subject under
  test.
  """

  alias TestLens.Recorder

  @doc "Start the capture recorder. Call once from test_helper.exs before ExUnit.start/1."
  def start(opts \\ []) do
    Recorder.start_link(opts)
  end

  @doc "Begin capturing for the current test. Driven by `use TestLens.Case`."
  def begin(context) do
    Recorder.begin(%{
      module: context.module,
      name: context.test,
      pid: self(),
      file: context[:file],
      line: context[:line],
      tags: collect_tags(context)
    })
  end

  @doc "Mark the current stage. Subsequent captures are filed under it."
  def stage(stage) when is_atom(stage) or is_binary(stage) do
    Recorder.put_stage(self(), to_string(stage))
  end

  @doc """
  Record a value at the current stage.

  `kind` controls how the viewer renders it: `:json`, `:text`, `:table`,
  `:http_request`, `:http_response`. Auto-detected from the value when omitted.

  `annotate` takes a list of paths to highlight on render; each path is a list
  of keys (atoms or strings) and/or integer indices resolved against the
  sanitized value, e.g. `annotate: [["data", "creator"]]`.
  """
  def capture(label, value, opts \\ []) do
    kind = opts[:kind] || detect_kind(value)
    paths = opts[:annotate] || []
    Recorder.add_capture(self(), to_string(label), to_string(kind), value, opts[:stage], paths)
    value
  end

  @doc "Sugar: capture a value as input (no stage change)."
  def input(label, value, opts \\ []), do: capture(label, value, opts)

  @doc "Sugar: switch to the verify stage and capture the result value."
  def output(label, value, opts \\ []) do
    stage(:verify)
    capture(label, value, opts)
  end

  @doc """
  Wrap the test's setup in a block. The viewer shows the block's source verbatim
  in the INPUT channel; the code still runs and any variables it binds stay in
  scope for the rest of the test.

      TestLens.setup do
        user = insert(:user)
      end
  """
  defmacro setup(description \\ nil, do: block), do: phase(:setup, description, block)

  @doc """
  Wrap the test's action in a block. The viewer shows the block's source verbatim
  in the ACTION channel. Pass an optional one-line description of what it does.

      TestLens.action "mint a guest workspace" do
        conn = post(conn, ~p"/api/guests", params)
      end
  """
  defmacro action(description \\ nil, do: block), do: phase(:action, description, block)

  @doc """
  Wrap the test's checks in a block. The viewer shows the block's source verbatim
  in the RESULT channel. Capture the subject under test inside or after it.

      TestLens.verify do
        assert conn.status == 201
      end
  """
  defmacro verify(description \\ nil, do: block), do: phase(:verify, description, block)

  defp phase(stage, description, block) do
    source = Macro.to_string(block)

    quote do
      TestLens.__phase__(unquote(to_string(stage)), unquote(description), unquote(source))
      unquote(block)
    end
  end

  @doc false
  def __phase__(stage, description, source) do
    Recorder.put_stage(self(), stage)
    Recorder.add_capture(self(), description || "", "source", source, stage, [])
  end

  defp detect_kind(value) when is_binary(value), do: :text
  defp detect_kind(value) when is_map(value) or is_list(value), do: :json
  defp detect_kind(_), do: :json

  defp collect_tags(context) do
    context
    |> Map.get(:registered, %{})
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end
end
