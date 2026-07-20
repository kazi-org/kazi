defmodule Kazi.Velocity.SessionCollector do
  @moduledoc """
  T67.3 (ADR-0079 decision 2): the OPT-IN, per-machine session-stats collector.

  It parses the local harness session transcripts into per-session AGGREGATE
  counters (`Kazi.Velocity.Counters`), keyed by the E65 session UUID, and ships
  them into the read-model — INCREMENTALLY (a byte cursor per transcript,
  `Kazi.Velocity.Cursor`), IDEMPOTENTLY (cumulative counters upserted on
  `(session_uuid, machine)`, so a re-scan collapses to one current row), and
  ONLY as schema'd counters (never transcript content — R-E67-3).

  ## Disabled by default (ADR-0034 opt-in)

  `enabled?/0` is FALSE unless the operator explicitly opts this machine in, via
  either `config :kazi, :velocity_collector, enabled: true` or the
  `KAZI_VELOCITY_COLLECTOR` environment override (`1`/`true`/`yes`/`on`). `run/1`
  is a no-op that returns `{:ok, :disabled}` when the collector is off, so a
  machine that has not opted in reads NO transcript at all. `collect/1` performs
  the work regardless of the gate (it is what `run/1` calls once the gate passes,
  and what tests drive directly).

  ## Two ships, one whitelist (ADR-0079 decision 2 + 3)

    * a bus `fact` on topic `session:<short-uuid>` (the T60.1 `BusMirror`
      last-value-per-subject pattern) carries the counters cross-machine; because
      the counters are cumulative and a `fact` keeps only the last value per
      subject, a re-post idempotently overwrites the session's current totals;
    * the read-model row is written through `Kazi.ReadModel.Writer` (the ADR-0068
      daemon single-writer seam) as an upsert on `(session_uuid, machine)`.

  BOTH payloads are built from `Kazi.Velocity.Counters.to_wire/2`, the one closed
  whitelist, so nothing outside the schema can cross either path — the property
  `session_counters_wire_shape_test.exs` pins.
  """

  require Logger

  alias Kazi.ReadModel.SessionCounters
  alias Kazi.ReadModel.Writer
  alias Kazi.Velocity.{Counters, Cursor, TranscriptParser}

  @truthy ~w(1 true yes on)

  # The per-transcript, per-pass byte budget (#1606). A pass reads at most this
  # many NEW bytes from each transcript, so a first scan of a large ~/.claude tree
  # advances the cursors in bounded chunks across successive passes instead of one
  # unbounded read that blocks past the ticker's collect_timeout and is killed
  # every tick. A transcript already caught up (cursor at EOF) is skipped with only
  # a stat, so a steady-state pass over a large tree completes in seconds.
  @default_max_bytes_per_pass 8 * 1024 * 1024

  @typedoc "A per-session collection result."
  @type collected :: %{
          session_uuid: String.t(),
          session_name: String.t() | nil,
          counters: Counters.t()
        }

  @doc """
  Whether the collector is opted in on THIS machine. Disabled by default; enabled
  only by `config :kazi, :velocity_collector, enabled: true` or a truthy
  `KAZI_VELOCITY_COLLECTOR` env var.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    env = System.get_env("KAZI_VELOCITY_COLLECTOR")

    cond do
      is_binary(env) -> String.downcase(String.trim(env)) in @truthy
      true -> Application.get_env(:kazi, :velocity_collector, [])[:enabled] == true
    end
  end

  @doc """
  Run the collector IF this machine has opted in, else a no-op.

  Returns `{:ok, results}` with the per-session collections, or `{:ok, :disabled}`
  when the collector is off (no transcript is read). See `collect/1` for options.
  """
  @spec run(keyword()) :: {:ok, [collected()]} | {:ok, :disabled}
  def run(opts \\ []) do
    if enabled?() do
      {:ok, collect(opts)}
    else
      {:ok, :disabled}
    end
  end

  @doc """
  Collect counters from every `*.jsonl` transcript under `:dir` (recursively),
  advancing each transcript's cursor and shipping its cumulative counters.

  Options:

    * `:dir` — the transcript root to scan (required).
    * `:state_dir` — where per-transcript cursors persist (machine-local).
      Defaults to a tmp-scoped kazi dir; pass a stable dir in production.
    * `:machine` — the host label recorded on the counters. Defaults to the
      `KAZI_VELOCITY_MACHINE` env var or the system hostname.
    * `:poster` — `(kind, text, opts -> any)` bus poster for the counter fact.
      Defaults to `&Kazi.Bus.post/3`; best-effort (errors are swallowed).
    * `:write` — `(map -> any)` sink for the read-model row attrs. Defaults to the
      `Kazi.ReadModel.Writer` upsert. Injectable so a test asserts row shape.
    * `:bucket_cap_s` — active-time gap cap, passed to the parser.
    * `:max_bytes` — the per-transcript, per-pass NEW-byte budget (#1606, default
      #{@default_max_bytes_per_pass}). Bounds each pass so it completes on a large
      transcript tree instead of being killed at the ticker deadline.
  """
  @spec collect(keyword()) :: [collected()]
  def collect(opts) do
    dir = Keyword.fetch!(opts, :dir)
    state_dir = Keyword.get(opts, :state_dir, default_state_dir())
    machine = Keyword.get(opts, :machine) || default_machine()

    # #1606: `bus_ok?` circuit-breaks the best-effort fact post for the REST of
    # this pass once the bus has failed once — see `post_fact/5`.
    {collected, _bus_ok?} =
      dir
      |> transcripts()
      |> Enum.reduce({[], true}, fn path, {acc, bus_ok?} ->
        {results, bus_ok?} = collect_transcript(path, state_dir, machine, opts, bus_ok?)
        {acc ++ results, bus_ok?}
      end)

    collected
  end

  defp transcripts(dir) do
    Path.wildcard(Path.join(dir, "**/*.jsonl")) |> Enum.sort()
  end

  defp collect_transcript(path, state_dir, machine, opts, bus_ok?) do
    cursor = Cursor.load(state_dir, path)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes_per_pass)

    case new_bytes(path, cursor.offset, max_bytes) do
      # No new complete line since the cursor (a caught-up or unreadable
      # transcript): skip WITHOUT parsing or re-shipping — the row is already
      # current from the pass that first read it. This is what makes a steady-state
      # pass over a large tree cost only a stat per file (#1606).
      :skip ->
        {[], bus_ok?}

      {:ok, chunk, next_offset} ->
        result =
          TranscriptParser.parse(chunk,
            prev_ts: cursor.prev_ts,
            bucket_cap_s: Keyword.get(opts, :bucket_cap_s, 300)
          )

        cumulative = Counters.merge(cursor.counters, result.counters)
        session_uuid = cursor.session_uuid || result.session_uuid
        session_name = cursor.session_name || result.session_name

        Cursor.save(state_dir, path, %{
          offset: next_offset,
          counters: cumulative,
          prev_ts: result.counters.last_observed_at || cursor.prev_ts,
          session_uuid: session_uuid,
          session_name: session_name
        })

        ship(session_uuid, session_name, machine, cumulative, opts, bus_ok?)
    end
  end

  # Read only the NEW bytes past `offset`, capped at `max_bytes`, WITHOUT reading
  # the whole file (#1606) — a `stat` skips a caught-up transcript for free, and a
  # positioned read (`:file.pread`) touches only the fresh tail rather than
  # re-reading the entire multi-hundred-MB file every pass (the live hang). Only
  # bytes up to the last COMPLETE line in the window are consumed, so a partially
  # written final line is re-read next pass rather than parsed half-formed.
  # Returns `{:ok, chunk, next_offset}` or `:skip` (caught up / no complete line in
  # the window / unreadable).
  @spec new_bytes(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary(), non_neg_integer()} | :skip
  defp new_bytes(path, offset, max_bytes) do
    with {:ok, %File.Stat{size: size}} when size > offset <- File.stat(path),
         length = min(size - offset, max_bytes),
         {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        read_tail(fd, offset, length)
      after
        :file.close(fd)
      end
    else
      _ -> :skip
    end
  end

  defp read_tail(fd, offset, length) do
    case :file.pread(fd, offset, length) do
      {:ok, tail} ->
        case last_newline(tail) do
          nil -> :skip
          idx -> {:ok, binary_part(tail, 0, idx + 1), offset + idx + 1}
        end

      _eof_or_error ->
        :skip
    end
  end

  defp last_newline(bin) do
    case :binary.matches(bin, "\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # A chunk with no resolvable session UUID yields nothing (nothing to key on);
  # otherwise ship the fact and write the row from the ONE whitelist, then return
  # the collected result.
  defp ship(nil, _name, _machine, _counters, _opts, bus_ok?), do: {[], bus_ok?}

  defp ship(session_uuid, session_name, machine, counters, opts, bus_ok?) do
    identity = %{session_uuid: session_uuid, session_name: session_name, machine: machine}
    wire = Counters.to_wire(counters, identity)

    bus_ok? = post_fact(session_uuid, session_name, wire, opts, bus_ok?)
    write_row(wire, opts)

    {[%{session_uuid: session_uuid, session_name: session_name, counters: counters}], bus_ok?}
  end

  # Best-effort bus fact (the T60.1 mirror contract): a daemon-down / error /
  # timeout degrades, never a collector crash.
  #
  # #1606 CIRCUIT-BREAK: once the bus has failed ONCE in this pass, skip it for
  # every remaining session. `Kazi.Bus.run/3` bounds a single call at 15s, but the
  # collector posts once PER SESSION — so against an unreachable-but-blackholing
  # host a pass paid that deadline N times (N x 15s) and overran its tick
  # interval, which is the SECOND live #1606 failure mode: the ticker logged
  # "velocity pass still running after 10000ms; skipping this tick" forever while
  # `passes_killed` stayed 0 (the pass never reached the 120s kill deadline).
  # Same unreachable host as the `:ehostunreach` crash mode — only the network's
  # behaviour differs (fail-fast vs blackhole) — so both are fixed together: the
  # unlinked `Bus.run/3` stops the crash, this stops the stall. The read-model
  # write is the essential ship; the fact is telemetry, so dropping it for the
  # rest of a pass costs nothing (counters are cumulative — the next pass reposts
  # the current totals).
  @spec post_fact(String.t(), String.t() | nil, map(), keyword(), boolean()) :: boolean()
  defp post_fact(_session_uuid, _session_name, _wire, _opts, false), do: false

  defp post_fact(session_uuid, session_name, wire, opts, true) do
    poster = Keyword.get(opts, :poster, &Kazi.Bus.post/3)
    topic = "session:" <> short(session_uuid)
    text = Jason.encode!(wire)

    try do
      case poster.("fact", text, topic: topic, session_name: session_name) do
        # `Kazi.Bus` degrades to this rather than raising; treat it as "the bus is
        # down for this pass" and stop paying its deadline per session.
        {:error, _reason} -> false
        _posted -> true
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp write_row(wire, opts) do
    write = Keyword.get(opts, :write, &default_write/1)
    write.(wire)
  rescue
    error ->
      Logger.debug("kazi velocity collector: read-model write failed (#{inspect(error)})")
      :ok
  end

  # The default read-model sink: an upsert on `(session_uuid, machine)` routed
  # through the daemon single-writer seam (ADR-0068). Last-write-wins on the
  # cumulative counters, so a re-post overwrites the session's current row. This
  # is the CLIENT-context sink: from outside the daemon, `Writer` correctly
  # routes the write to the daemon over the control socket.
  defp default_write(wire) do
    Writer.insert(upsert_changeset(wire), upsert_opts())
  end

  @doc """
  The IN-DAEMON DIRECT read-model sink: the same `(session_uuid, machine)` upsert
  as `default_write/1`, but written STRAIGHT to `Kazi.Repo` instead of through
  `Kazi.ReadModel.Writer`.

  This exists because the collector's default sink (`Writer.insert/2`) is a
  client seam: it probes the daemon control socket and, when a daemon is alive,
  routes the write over that socket to the daemon's single writer. When the
  COLLECTOR ITSELF runs inside the daemon (the `Kazi.Daemon.VelocityTicker`
  path), that probe finds the daemon alive -- because it is probing itself -- and
  the ticker then blocks waiting on a control-socket round-trip the daemon must
  serve while the ticker (which `kazi daemon status` calls into) is busy: the
  daemon self-deadlocks (the T67.6 live wedge). The daemon IS the ADR-0068 single
  writer, so a write it originates must be a direct `Repo` write -- exactly what
  `Kazi.Daemon.Write` does when it applies a client batch. The ticker injects
  this as its `:write` sink so its writes never touch its own socket.
  """
  @spec direct_write(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def direct_write(wire) do
    Kazi.Repo.insert(upsert_changeset(wire), upsert_opts())
  end

  defp upsert_changeset(wire), do: SessionCounters.changeset(%SessionCounters{}, wire)

  defp upsert_opts do
    [on_conflict: {:replace, replaceable_fields()}, conflict_target: [:session_uuid, :machine]]
  end

  defp replaceable_fields do
    Counters.wire_fields() ++ [:session_name, :updated_at]
  end

  defp short(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)

  defp default_machine do
    case System.get_env("KAZI_VELOCITY_MACHINE") do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case :inet.gethostname() do
          {:ok, name} -> to_string(name)
          _ -> "unknown"
        end
    end
  end

  defp default_state_dir do
    Path.join([System.tmp_dir!(), "kazi", "velocity", "cursors"])
  end
end
