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
  """
  @spec collect(keyword()) :: [collected()]
  def collect(opts) do
    dir = Keyword.fetch!(opts, :dir)
    state_dir = Keyword.get(opts, :state_dir, default_state_dir())
    machine = Keyword.get(opts, :machine) || default_machine()

    dir
    |> transcripts()
    |> Enum.flat_map(fn path -> collect_transcript(path, state_dir, machine, opts) end)
  end

  defp transcripts(dir) do
    Path.wildcard(Path.join(dir, "**/*.jsonl")) |> Enum.sort()
  end

  defp collect_transcript(path, state_dir, machine, opts) do
    with {:ok, content} <- File.read(path) do
      cursor = Cursor.load(state_dir, path)
      {chunk, next_offset} = new_bytes(content, cursor.offset)

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

      ship(session_uuid, session_name, machine, cumulative, opts)
    else
      _ -> []
    end
  end

  # Only consume up to the last COMPLETE line (the byte after the final newline),
  # so a transcript whose final line is still being written is re-read next pass
  # rather than parsed half-formed. Returns the fresh chunk and the new offset.
  defp new_bytes(content, offset) do
    size = byte_size(content)
    offset = min(offset, size)
    tail = binary_part(content, offset, size - offset)

    case last_newline(tail) do
      nil -> {"", offset}
      idx -> {binary_part(tail, 0, idx + 1), offset + idx + 1}
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
  defp ship(nil, _name, _machine, _counters, _opts), do: []

  defp ship(session_uuid, session_name, machine, counters, opts) do
    identity = %{session_uuid: session_uuid, session_name: session_name, machine: machine}
    wire = Counters.to_wire(counters, identity)

    post_fact(session_uuid, session_name, wire, opts)
    write_row(wire, opts)

    [%{session_uuid: session_uuid, session_name: session_name, counters: counters}]
  end

  # Best-effort bus fact (the T60.1 mirror contract): a daemon-down / error /
  # timeout collapses to :ok, never a collector crash.
  defp post_fact(session_uuid, session_name, wire, opts) do
    poster = Keyword.get(opts, :poster, &Kazi.Bus.post/3)
    topic = "session:" <> short(session_uuid)
    text = Jason.encode!(wire)

    try do
      poster.("fact", text, topic: topic, session_name: session_name)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
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
  # cumulative counters, so a re-post overwrites the session's current row.
  defp default_write(wire) do
    changeset = SessionCounters.changeset(%SessionCounters{}, wire)

    Writer.insert(changeset,
      on_conflict: {:replace, replaceable_fields()},
      conflict_target: [:session_uuid, :machine]
    )
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
