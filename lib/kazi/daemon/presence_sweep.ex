defmodule Kazi.Daemon.PresenceSweep do
  @moduledoc """
  T55.11: the daemon-side presence sweep that lets `bus who` tell IDLE from
  DEAD. Field feedback: `who` hid rows past the 10-minute KV TTL, so a
  supervisor with several alive-but-quiet harness processes saw them vanish
  from the roster -- and "idle, needs a nudge" vs "process gone, needs a
  restart" are OPPOSITE situations the roster could not distinguish.

  A supervised GenServer under `Kazi.Daemon.Supervisor`. Every `interval_ms`
  (default 60s) it lists the `kazi_sessions` KV bucket and, for each row whose
  `machine` is THIS machine ONLY:

    * pid alive with a MATCHING recorded start time (`Kazi.Bus.Liveness`) --
      if the row is older than `idle_after_s` (default 120s), re-heartbeat it
      on the session's behalf marked `liveness: "idle"` (fresh `ts`, all other
      fields preserved), so a genuinely-alive-but-quiet session NEVER ages out
      of `who`. A row the session itself refreshed recently is left untouched
      (it stays `active`).
    * pid gone, or alive with a DIFFERENT start time (pid reuse) -- DELETE the
      row (reap). This also retires the accumulated `os-<pid>` ghost rows
      (pid-fallback identities of nameless sessions).
    * inconclusive (no pid, or a pre-T55.11 row without a recorded start time
      whose pid is currently taken) -- left alone; the bucket TTL ages it out.

  Rows for OTHER machines are NEVER touched -- a connect-mode daemon must not
  guess about pids it cannot see; each machine's daemon sweeps only its own
  rows, so on a shared cross-machine bus every machine's rows are swept by
  exactly one daemon.

  Connection: one short-lived `Gnat` connection per tick, discovered from the
  sibling `Kazi.Daemon.Nats` (host/port/token) -- or `opts[:connect_opts]`
  (a `Gnat.start_link/1` map), which tests use to point a sweep at a scratch
  server. A failed tick (nats not accepting yet, transient error) logs at
  debug and retries on the next interval; the sweep never crash-loops the
  daemon tree.
  """

  use GenServer
  require Logger

  alias Gnat.Jetstream.API.KV
  alias Kazi.Bus.Liveness
  alias Kazi.Bus.Provision

  @default_interval_ms 60_000
  @default_idle_after_s 120

  @doc "Seconds a row may go un-refreshed by its own session before the sweep re-heartbeats it as `idle`."
  @spec default_idle_after_s() :: pos_integer()
  def default_idle_after_s, do: @default_idle_after_s

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # The per-tick Gnat connection is linked; trap exits so a connection
    # dying mid-sweep is a swallowed message (the catch-all handle_info),
    # not a sweep crash.
    Process.flag(:trap_exit, true)

    state = %{
      nats_name: Keyword.get(opts, :nats_name, Kazi.Daemon.Nats),
      connect_opts: Keyword.get(opts, :connect_opts),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      idle_after_s: Keyword.get(opts, :idle_after_s, @default_idle_after_s)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    run_tick(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  One sweep pass over the sessions bucket against an already-connected `conn`
  -- the tick body, public so tests drive it directly without the timer.

  Options: `:machine` (default: the local hostname -- the ONLY machine whose
  rows are judged), `:idle_after_s` (default #{@default_idle_after_s}).

  Returns `{:ok, %{reaped: keys, idled: keys}}`.
  """
  @spec sweep(Gnat.t(), keyword()) ::
          {:ok, %{reaped: [String.t()], idled: [String.t()]}} | {:error, term()}
  def sweep(conn, opts \\ []) do
    bucket = Provision.sessions_bucket()
    machine = Keyword.get(opts, :machine, hostname())
    idle_after_s = Keyword.get(opts, :idle_after_s, @default_idle_after_s)

    case KV.contents(conn, bucket) do
      {:ok, contents} ->
        result =
          Enum.reduce(contents, %{reaped: [], idled: []}, fn {key, value}, acc ->
            sweep_row(conn, bucket, key, value, machine, idle_after_s, acc)
          end)

        {:ok, %{reaped: Enum.reverse(result.reaped), idled: Enum.reverse(result.idled)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # NEVER touch rows for other machines (the `^machine` match) or rows that
  # do not decode -- the bucket TTL is the backstop for anything unjudgeable.
  defp sweep_row(conn, bucket, key, value, machine, idle_after_s, acc) do
    case Jason.decode(value) do
      {:ok, %{"machine" => ^machine} = entry} ->
        case Liveness.verdict(entry) do
          :dead ->
            KV.delete_key(conn, bucket, key)
            %{acc | reaped: [key | acc.reaped]}

          :alive ->
            if stale_enough?(entry, idle_after_s) do
              re_heartbeat(conn, bucket, key, entry)
              %{acc | idled: [key | acc.idled]}
            else
              acc
            end

          :unknown ->
            acc
        end

      _other_machine_or_undecodable ->
        acc
    end
  end

  defp re_heartbeat(conn, bucket, key, entry) do
    refreshed =
      entry
      |> Map.put("ts", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("liveness", "idle")

    KV.put_value(conn, bucket, key, Jason.encode!(refreshed))
  end

  # A malformed/absent ts counts as stale: the re-heartbeat REPAIRS it with a
  # fresh one (the row's process is verified alive, so keeping it is correct).
  defp stale_enough?(entry, idle_after_s) do
    with ts when is_binary(ts) <- entry["ts"],
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
      DateTime.diff(DateTime.utc_now(), dt, :second) >= idle_after_s
    else
      _unparseable -> true
    end
  end

  defp run_tick(state) do
    case resolve_connect_opts(state) do
      {:ok, connect_opts} ->
        case Gnat.start_link(connect_opts) do
          {:ok, conn} ->
            try do
              sweep(conn, idle_after_s: state.idle_after_s)
            after
              if Process.alive?(conn), do: Gnat.stop(conn)
            end

          {:error, reason} ->
            Logger.debug("kazi daemon: presence sweep skipped (#{inspect(reason)})")
        end

      {:error, reason} ->
        Logger.debug("kazi daemon: presence sweep skipped (#{inspect(reason)})")
    end
  rescue
    error ->
      Logger.debug("kazi daemon: presence sweep failed (#{Exception.message(error)})")
  catch
    kind, reason ->
      Logger.debug("kazi daemon: presence sweep failed (#{inspect(kind)}: #{inspect(reason)})")
  end

  defp resolve_connect_opts(%{connect_opts: %{} = connect_opts}), do: {:ok, connect_opts}

  # The sibling Kazi.Daemon.Nats may not be answering yet (boot order) --
  # a caught exit is a skipped tick, never a crash.
  defp resolve_connect_opts(%{nats_name: nats_name}) do
    host = Kazi.Daemon.Nats.host(nats_name)
    port = Kazi.Daemon.Nats.port(nats_name)
    base = %{host: host, port: port}

    case Kazi.Daemon.Nats.token(nats_name) do
      nil -> {:ok, base}
      token -> {:ok, Map.put(base, :auth_token, token)}
    end
  catch
    :exit, reason -> {:error, {:nats_unavailable, reason}}
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _other -> "unknown"
    end
  end
end
