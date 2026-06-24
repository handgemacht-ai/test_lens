defmodule TestLens.Recorder do
  @moduledoc """
  Holds in-progress captures, keyed by `{module, test_name}`, and flushes each
  test to a JSON case file when the formatter reports it finished.

  Captures arrive from the test process (and from telemetry handlers running in
  that process); the flush is triggered from the ExUnit formatter process. A
  pid index bridges the two so callers never thread an id around by hand.
  """
  use GenServer

  alias TestLens.JSON

  @name __MODULE__

  def start_link(opts) do
    GenServer.start_link(@name, opts, name: @name)
  end

  def begin(meta), do: cast({:begin, meta})
  def put_stage(pid, stage), do: cast({:stage, pid, stage})

  def add_capture(pid, label, kind, value, stage, paths \\ []),
    do: cast({:capture, pid, label, kind, value, stage, paths})

  def add_db_event(pid, event), do: cast({:db_event, pid, event})

  @doc """
  Flush a finished test to disk. Returns {:ok, path} | :ignored.

  `meta` (`:file`, `:line`, `:tags`) lets a test that never called `begin/1`
  still be written as a status-only case, so a suite with no shared case module
  renders as a catalog from the test_helper wiring alone.
  """
  def finish(module, name, status, duration_us, meta \\ %{}) do
    if alive?(),
      do: GenServer.call(@name, {:finish, module, name, status, duration_us, meta}),
      else: :ignored
  end

  defp cast(msg), do: if(alive?(), do: GenServer.cast(@name, msg), else: :ok)
  defp alive?, do: is_pid(Process.whereis(@name))

  # --- server ---

  @impl true
  def init(opts) do
    project = opts[:project] || "unknown"
    dir = opts[:dir] || "test_lens_out"
    cases_dir = Path.join(dir, "cases")
    File.mkdir_p!(cases_dir)

    {:ok, %{project: project, dir: dir, cases_dir: cases_dir, by_key: %{}, pids: %{}, seq: 0}}
  end

  @impl true
  def handle_cast({:begin, meta}, state) do
    key = {meta.module, meta.name}

    acc = %{
      module: inspect(meta.module),
      name: to_string(meta.name),
      file: relative(meta.file),
      line: meta.line,
      tags: meta.tags,
      stage: "setup",
      captures: [],
      db_events: []
    }

    {:noreply,
     %{state | by_key: Map.put(state.by_key, key, acc), pids: Map.put(state.pids, meta.pid, key)}}
  end

  def handle_cast({:stage, pid, stage}, state) do
    {:noreply, update_acc(state, pid, &%{&1 | stage: stage})}
  end

  def handle_cast({:capture, pid, label, kind, value, stage_override, paths}, state) do
    {seq, state} = next_seq(state)

    state =
      update_acc(state, pid, fn acc ->
        entry = %{
          stage: (stage_override && to_string(stage_override)) || acc.stage,
          label: label,
          kind: kind,
          value: JSON.sanitize(value),
          seq: seq,
          paths: sanitize_paths(paths)
        }

        %{acc | captures: [entry | acc.captures]}
      end)

    {:noreply, state}
  end

  def handle_cast({:db_event, pid, event}, state) do
    {seq, state} = next_seq(state)

    state =
      update_acc(state, pid, fn acc ->
        %{acc | db_events: [Map.merge(event, %{stage: acc.stage, seq: seq}) | acc.db_events]}
      end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:finish, module, name, status, duration_us, meta}, _from, state) do
    key = {module, name}

    acc =
      case Map.fetch(state.by_key, key) do
        {:ok, acc} -> acc
        :error -> blank_acc(module, name, meta)
      end

    path = write_case(state, acc, status, duration_us)
    pids = state.pids |> Enum.reject(fn {_pid, k} -> k == key end) |> Map.new()
    {:reply, {:ok, path}, %{state | by_key: Map.delete(state.by_key, key), pids: pids}}
  end

  # A test that never called begin/1 (no `use TestLens.Case`) still gets a
  # status-only case from what the formatter already knows about it.
  defp blank_acc(module, name, meta) do
    %{
      module: inspect(module),
      name: to_string(name),
      file: relative(meta[:file]),
      line: meta[:line],
      tags: meta[:tags] || [],
      stage: "setup",
      captures: [],
      db_events: []
    }
  end

  defp write_case(state, acc, status, duration_us) do
    payload = %{
      schema: "test_lens/v1.1",
      project: state.project,
      module: acc.module,
      name: acc.name,
      file: acc.file,
      line: acc.line,
      status: status,
      tags: acc.tags,
      duration_us: duration_us,
      captures: acc.captures |> Enum.reverse() |> Enum.map(&encode_capture/1),
      db_events: Enum.reverse(acc.db_events)
    }

    filename = slug(state.project, acc.module, acc.name) <> ".json"
    path = Path.join(state.cases_dir, filename)
    File.write!(path, Jason.encode!(payload, pretty: true))
    path
  end

  defp update_acc(state, pid, fun) do
    with key when not is_nil(key) <- state.pids[pid],
         acc when not is_nil(acc) <- state.by_key[key] do
      %{state | by_key: Map.put(state.by_key, key, fun.(acc))}
    else
      _ -> state
    end
  end

  defp next_seq(state), do: {state.seq, %{state | seq: state.seq + 1}}

  defp sanitize_paths(paths) when is_list(paths) do
    Enum.map(paths, fn path -> Enum.map(List.wrap(path), &path_key/1) end)
  end

  defp sanitize_paths(_), do: []

  defp path_key(k) when is_integer(k), do: k
  defp path_key(k) when is_atom(k), do: Atom.to_string(k)
  defp path_key(k) when is_binary(k), do: k
  defp path_key(k), do: inspect(k)

  defp encode_capture(%{paths: []} = entry), do: Map.delete(entry, :paths)
  defp encode_capture(entry), do: entry

  defp slug(project, module, name) do
    "#{project}-#{module}-#{name}"
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.slice(0, 180)
  end

  defp relative(nil), do: nil

  defp relative(file) do
    case Path.relative_to_cwd(file) do
      ^file -> Path.basename(file)
      rel -> rel
    end
  end
end
