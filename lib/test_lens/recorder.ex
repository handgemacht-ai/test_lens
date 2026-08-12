defmodule TestLens.Recorder do
  @moduledoc """
  Holds in-progress captures, keyed by `{module, test_name}`, and flushes each
  test to a JSON case file when the formatter reports it finished.

  Captures arrive from the test process (and from telemetry handlers running in
  that process); the flush is triggered from the ExUnit formatter process. A
  pid index bridges the two so callers never thread an id around by hand.

  Each run is given a stable identity once, in `init/1`: a `run_id`, an ISO-8601
  `run_at`, and a best-effort git context. The run directory and the
  `runs/latest` pointer are **created lazily**, only once a real case is written
  — a recorder that boots but records nothing leaves no trace and never repoints
  `latest` at an empty run. Cases land under `<dir>/runs/<run_id>/cases/`, and a
  run-level `meta.json` is flushed when the suite finishes (or, as a backstop, on
  process terminate) but only for a run that actually recorded something. A fresh
  run never overwrites a previous one — each lands in its own `run_id` directory.
  See `SPEC.md` for the on-disk contract.

  The recorder is defensive on purpose: value sanitization happens on the caller
  (the test pid) before every cast — captures, db-events and begin tags are all
  coerced JSON-safe there — and `write_case` sanitizes the whole document once
  more as a last line of defense, so an unsanitized field degrades to a safe
  string instead of dropping the case. Every message handler is still wrapped so
  a genuinely unwritable case (a failing `File.write!`) drops that one case
  (logged once) rather than taking the whole run's recording down with it. Run it
  under a supervisor (see `TestLens.start/1`) so even an unexpected crash restarts
  it.
  """
  use GenServer
  require Logger

  alias TestLens.{Git, JSON}

  @name __MODULE__

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # Tags can carry raw ExUnit context values (refs, pids, functions); sanitize
  # them on the caller so nothing unencodable rides into the case via begin.
  def begin(meta), do: cast({:begin, Map.update(meta, :tags, [], &JSON.sanitize/1)})
  def put_stage(pid, stage), do: cast({:stage, pid, stage})

  # Sanitize on the caller (the test pid) *before* the cast, so the recorder
  # never runs arbitrary-value coercion inside its single message loop.
  def add_capture(pid, label, kind, value, stage, paths \\ []),
    do: cast({:capture, pid, label, kind, JSON.sanitize(value), stage, sanitize_paths(paths)})

  # Sanitize the event on the caller too, mirroring add_capture, so a poison
  # db-event value can't ride into the case document unencoded.
  def add_db_event(pid, event), do: cast({:db_event, pid, JSON.sanitize(event)})

  @doc """
  Flush a finished test to disk. Returns {:ok, path} | {:error, reason} | :ignored.

  `meta` (`:file`, `:line`, `:tags`) lets a test that never called `begin/1`
  still be written as a status-only case, so a suite with no shared case module
  renders as a catalog from the test_helper wiring alone.
  """
  def finish(module, name, status, duration_us, meta \\ %{}) do
    if alive?(),
      do: GenServer.call(@name, {:finish, module, name, status, duration_us, meta}),
      else: :ignored
  end

  @doc """
  Flush the run-level `meta.json`. Called by `TestLens.Formatter` on
  `:suite_finished`; safe to call more than once. A no-op for a run that never
  recorded a case.
  """
  def finalize, do: if(alive?(), do: GenServer.call(@name, :finalize), else: :ignored)

  @doc "Identity of the active run: `run_id`, `run_at`, `git`, `run_dir`, `dir`."
  def run_info, do: if(alive?(), do: GenServer.call(@name, :run_info), else: :ignored)

  defp cast(msg), do: if(alive?(), do: GenServer.cast(@name, msg), else: :ok)
  defp alive?, do: is_pid(Process.whereis(@name))

  # --- server ---

  @impl true
  def init(opts) do
    project = opts[:project] || "unknown"
    dir = opts[:dir] || "test_lens_out"
    {run_id, run_at} = new_run_id()
    git = opts[:git] || Git.context(opts[:git_dir] || File.cwd!())

    run_dir = Path.join([dir, "runs", run_id])
    cases_dir = Path.join(run_dir, "cases")

    # No filesystem side effects here — the run dir and `runs/latest` pointer are
    # materialized lazily on the first successful case write (see `handle_call`
    # for `:finish`). Booting without recording must leave nothing behind.
    {:ok,
     %{
       project: project,
       dir: dir,
       run_dir: run_dir,
       cases_dir: cases_dir,
       run_id: run_id,
       run_at: run_at,
       git: git,
       by_key: %{},
       pids: %{},
       seq: 0,
       case_count: 0,
       status_counts: %{},
       dropped_off_pid: 0,
       materialized: false
     }}
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
  rescue
    error ->
      log_once(:begin, error, __STACKTRACE__)
      {:noreply, state}
  end

  def handle_cast({:stage, pid, stage}, state) do
    {:noreply, update_acc(state, pid, &%{&1 | stage: stage})}
  rescue
    error ->
      log_once(:stage, error, __STACKTRACE__)
      {:noreply, state}
  end

  def handle_cast({:capture, pid, label, kind, value, stage_override, paths}, state) do
    {seq, state} = next_seq(state)

    state =
      update_acc(state, pid, fn acc ->
        # `value`/`paths` are already sanitized on the caller side (add_capture).
        entry = %{
          stage: (stage_override && to_string(stage_override)) || acc.stage,
          label: label,
          kind: kind,
          value: value,
          seq: seq,
          paths: paths
        }

        %{acc | captures: [entry | acc.captures]}
      end)

    {:noreply, state}
  rescue
    error ->
      log_once(:capture, error, __STACKTRACE__)
      {:noreply, state}
  end

  def handle_cast({:db_event, pid, event}, state) do
    {seq, state} = next_seq(state)

    state =
      update_acc(state, pid, fn acc ->
        %{acc | db_events: [Map.merge(event, %{stage: acc.stage, seq: seq}) | acc.db_events]}
      end)

    {:noreply, state}
  rescue
    error ->
      log_once(:db_event, error, __STACKTRACE__)
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

    try do
      File.mkdir_p!(state.cases_dir)
      path = write_case(state, acc, status, duration_us)

      state =
        state
        |> mark_materialized()
        |> forget_key(key)

      state = %{
        state
        | case_count: state.case_count + 1,
          status_counts:
            Map.update(state.status_counts, TestLens.Status.to_string(status), 1, &(&1 + 1))
      }

      {:reply, {:ok, path}, state}
    rescue
      error ->
        # Drop this one case (log once) but keep the recorder — and the rest of
        # the run — alive. Forget the key so a failed test never leaks state.
        log_once(:write_case, error, __STACKTRACE__)
        {:reply, {:error, :write_failed}, forget_key(state, key)}
    end
  end

  def handle_call(:finalize, _from, state) do
    write_meta(state)
    {:reply, :ok, state}
  end

  def handle_call(:run_info, _from, state) do
    info = Map.take(state, [:run_id, :run_at, :git, :run_dir, :dir])
    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    write_meta(state)
    :ok
  end

  # A test that never called begin/1 (no `use TestLens.Case`) still gets a
  # status-only case from what the formatter already knows about it.
  defp blank_acc(module, name, meta) do
    %{
      module: inspect(module),
      name: to_string(name),
      file: relative(meta[:file]),
      line: meta[:line],
      tags: JSON.sanitize(meta[:tags] || []),
      stage: "setup",
      captures: [],
      db_events: []
    }
  end

  defp write_case(state, acc, status, duration_us) do
    payload = %{
      schema: "test_lens/v1.1",
      run_id: state.run_id,
      run_at: state.run_at,
      git: state.git,
      project: state.project,
      module: acc.module,
      name: acc.name,
      file: acc.file,
      line: acc.line,
      status: TestLens.Status.to_string(status),
      tags: acc.tags,
      duration_us: duration_us,
      captures: acc.captures |> Enum.reverse() |> Enum.map(&encode_capture/1),
      db_events: Enum.reverse(acc.db_events)
    }

    filename = slug(state.project, acc.module, acc.name) <> ".json"
    path = Path.join(state.cases_dir, filename)
    # Last line of defense: the entry points already sanitize, but coerce the
    # whole document once more so any future unsanitized field degrades to a safe
    # string rather than dropping the case. The drop-and-log rescue still guards
    # a genuinely unwritable case (an `File.write!` that fails), which sanitizing
    # cannot fix.
    File.write!(path, Jason.encode!(JSON.sanitize(payload), pretty: true))
    path
  end

  # Only ever writes a meta.json for a run that materialized (recorded ≥1 case),
  # so a boot-without-recording never leaves a phantom run behind.
  defp write_meta(%{materialized: false}), do: :ok

  defp write_meta(state) do
    meta = %{
      schema: "test_lens_run/v1",
      run_id: state.run_id,
      run_at: state.run_at,
      project: state.project,
      git: state.git,
      case_count: state.case_count,
      status_counts: state.status_counts,
      dropped_off_pid: state.dropped_off_pid
    }

    File.mkdir_p!(state.run_dir)
    File.write!(Path.join(state.run_dir, "meta.json"), Jason.encode!(meta, pretty: true))
  rescue
    _ -> :ok
  end

  defp new_run_id do
    now = DateTime.utc_now()
    run_at = DateTime.to_iso8601(now)

    stamp =
      now
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(["-", ":"], "")

    uniq = System.unique_integer([:positive, :monotonic])
    {stamp <> "-" <> Integer.to_string(uniq), run_at}
  end

  # The first real case both creates the run dir's pointer and claims `latest`.
  # Idempotent: only the first successful case write flips the flag.
  defp mark_materialized(%{materialized: true} = state), do: state

  defp mark_materialized(state) do
    write_latest_pointer(state.dir, state.run_id)
    %{state | materialized: true}
  end

  defp write_latest_pointer(dir, run_id) do
    File.write(Path.join([dir, "runs", "latest"]), run_id)
  rescue
    _ -> :ok
  end

  defp forget_key(state, key) do
    %{
      state
      | by_key: Map.delete(state.by_key, key),
        pids: state.pids |> Enum.reject(fn {_pid, k} -> k == key end) |> Map.new()
    }
  end

  defp update_acc(state, pid, fun) do
    with key when not is_nil(key) <- state.pids[pid],
         acc when not is_nil(acc) <- state.by_key[key] do
      %{state | by_key: Map.put(state.by_key, key, fun.(acc))}
    else
      # A cast from a pid we can't resolve to a test is dropped — but counted, so
      # the loss is visible in meta.json instead of silently vanishing.
      _ -> %{state | dropped_off_pid: state.dropped_off_pid + 1}
    end
  end

  defp next_seq(state), do: {state.seq, %{state | seq: state.seq + 1}}

  # Log the first drop of each kind and stay quiet after, so a systematically
  # bad value (e.g. an unwritable output dir) does not flood the run's output.
  defp log_once(tag, error, stacktrace) do
    unless Process.get({__MODULE__, :logged, tag}) do
      Process.put({__MODULE__, :logged, tag}, true)

      Logger.warning(
        "TestLens.Recorder dropped a #{tag}; the run continues without it.\n" <>
          Exception.format(:error, error, stacktrace)
      )
    end

    :ok
  end

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
