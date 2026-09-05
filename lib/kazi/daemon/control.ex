defmodule Kazi.Daemon.Control do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the daemon's line-delimited JSON control
  protocol, kept separate from `Kazi.Daemon.Listener`'s socket transport so a
  later task (T51.2+, the bus primitives) can add ops here without touching the
  accept loop.

  Ops: `ping` (the version handshake `status` reports), `read` (T55.7,
  ADR-0072 d5 -- the server-side bus digest, delegated to
  `Kazi.Daemon.BusRead`), and `write` (T52.3, ADR-0068 d1 -- the server-side
  single-writer read-model write, delegated to `Kazi.Daemon.Write`, applying a
  batch atomically). `shutdown` is recognized so the listener can react
  to it, but the actual supervision-tree teardown is the listener's job
  (`handle/2` only computes the reply); an unknown op replies
  `{"ok":false,"error":"unknown_op"}`.

  T58.2 (#1227): `ping` also reports `bus_vsn` (`@bus_vsn`, an integer
  bumped only when a control-socket op is added that an older daemon binary
  cannot serve at all -- the `read`/T55.7 class of change). This is what
  `Kazi.Bus.ProtocolSkew` compares client-side, at the SAME connection seam
  every bus verb already passes through, so an old daemon is caught with a
  clear "restart the daemon" error BEFORE an op is attempted, instead of
  reaching the `unknown_op` catch-all below.

  T69.5 (#1684): `ping` also reports `nats_health` -- `Kazi.Daemon.Nats`'s
  restart-loop window and last classified bind-conflict (an orphaned or
  otherwise-squatted nats-server holding the daemon's configured port). Purely
  additive, like `schema_vsn`; see `nats_health/1` and `docs/session-bus.md`
  ("Bind-conflict recovery").
  """

  # T58.2: bump together with `Kazi.Bus.ProtocolSkew`'s `@required_bus_vsn`.
  @bus_vsn 1

  @doc """
  Decides the reply for a decoded request. `opts[:started_at]` is the daemon's
  boot time (`System.monotonic_time(:second)`), used to compute `uptime_s`.
  """
  @spec handle(map(), keyword()) :: map()
  def handle(%{"op" => "ping"}, opts) do
    nats_name = Keyword.get(opts, :nats_name)

    # `nats_host` + `nats_token` (issue #1101) let a bus CLIENT dial the SAME
    # nats the daemon is configured for -- the connect-mode remote host and its
    # shared token -- instead of assuming a local, unauthenticated `127.0.0.1`.
    # A nil token is omitted so the handshake stays clean when the bus is
    # unauthenticated (and an old client ignores the extra fields).
    %{
      "ok" => true,
      "vsn" => vsn(),
      "bus_vsn" => @bus_vsn,
      "uptime_s" => uptime_s(Keyword.get(opts, :started_at)),
      "pid" => os_pid(),
      "nats_port" => nats_port(nats_name),
      "nats_host" => nats_host(nats_name)
    }
    |> maybe_put("nats_token", nats_token(nats_name))
    |> maybe_put("schema_vsn", schema_vsn(opts))
    |> Map.put("velocity", velocity_status(opts))
    |> Map.put("nats_health", nats_health(nats_name))
  end

  # T55.7 (ADR-0072 d5): assembly is the DAEMON's job -- the reply is already
  # bounded when it reaches the client.
  def handle(%{"op" => "read"} = request, opts) do
    Kazi.Daemon.BusRead.handle(
      request,
      Keyword.take(opts, [:nats_name, :connect_opts])
    )
  end

  # T52.3 (ADR-0068 decision 1): the daemon is the single read-model writer --
  # the whole `batch` is applied atomically server-side (`Kazi.Daemon.Write`),
  # the exact shape of `read` delegating to `Kazi.Daemon.BusRead`.
  def handle(%{"op" => "write"} = request, opts) do
    Kazi.Daemon.Write.handle(request, Keyword.take(opts, [:repo]))
  end

  def handle(%{"op" => "shutdown"}, _opts), do: %{"ok" => true}

  def handle(_other, _opts), do: %{"ok" => false, "error" => "unknown_op"}

  # T67.6 (ADR-0079): honest observability for the opt-in session-stats collector
  # so `kazi daemon status` shows an operator whether it is alive. Reports the
  # collector's enabled state plus, from REAL runs only (never fabricated), the
  # last run's ISO-8601 timestamp and session count. Defensive: a ticker that is
  # not running / not answering yields `enabled` from the gate check and null run
  # fields, never a crashed handshake. `:velocity_name` is a test seam.
  defp velocity_status(opts) do
    name =
      Keyword.get(opts, :velocity_name, Kazi.Daemon.Supervisor.default_velocity_ticker_name([]))

    s = Kazi.Daemon.VelocityTicker.status(name)

    %{
      "enabled" => s.enabled,
      "last_run_at" => s.last_run_at && DateTime.to_iso8601(s.last_run_at),
      "last_session_count" => s.last_session_count,
      # #1606: the tick-lifecycle counters, so `kazi daemon status` distinguishes
      # "the timer never fired" (ticks_fired == 0) from "it fired but every pass
      # died" (passes_killed / passes_crashed > 0) without depending on any log
      # reaching the LaunchAgent log file.
      "interval_ms" => Map.get(s, :interval_ms),
      "ticks_fired" => Map.get(s, :ticks_fired, 0),
      "passes_completed" => Map.get(s, :passes_completed, 0),
      "passes_killed" => Map.get(s, :passes_killed, 0),
      "passes_crashed" => Map.get(s, :passes_crashed, 0),
      "last_kill_at" => Map.get(s, :last_kill_at) && DateTime.to_iso8601(s.last_kill_at),
      "last_projection" => encode_projection(Map.get(s, :last_projection))
    }
  rescue
    _ -> velocity_status_down()
  catch
    _, _ -> velocity_status_down()
  end

  defp velocity_status_down do
    %{
      "enabled" => false,
      "last_run_at" => nil,
      "last_session_count" => nil,
      "interval_ms" => nil,
      "ticks_fired" => 0,
      "passes_completed" => 0,
      "passes_killed" => 0,
      "passes_crashed" => 0,
      "last_kill_at" => nil,
      "last_projection" => nil
    }
  end

  # The last delivery-projection pass (T67.6 finding 2): real facts only, `nil`
  # before the first pass (or when no workspaces are configured).
  defp encode_projection(%{workspaces_scanned: scanned, events_written: written, at: at}) do
    %{
      "workspaces_scanned" => scanned,
      "events_written" => written,
      "at" => at && DateTime.to_iso8601(at)
    }
  end

  defp encode_projection(_absent), do: nil

  # T69.5 (#1684): the nats-server restart-loop / bind-conflict watchdog.
  # Always present (like `velocity`, never omitted) -- absent a configured
  # `nats_name` (should not happen in production; a defensive default for the
  # handshake tests that ping without one), reports the same "all clear" shape
  # `Kazi.Daemon.Nats.health/1` returns for a process that has never exited.
  defp nats_health(nil), do: encode_nats_health(%{})

  defp nats_health(nats_name) do
    encode_nats_health(Kazi.Daemon.Nats.health(nats_name))
  rescue
    _ -> encode_nats_health(%{})
  catch
    _, _ -> encode_nats_health(%{})
  end

  defp encode_nats_health(h) do
    %{
      "restart_loop" => Map.get(h, :restart_loop, false),
      "exits_in_window" => Map.get(h, :exits_in_window, 0),
      "exit_window_ms" => Map.get(h, :exit_window_ms),
      "bind_conflict" => encode_bind_conflict(Map.get(h, :bind_conflict)),
      "last_exit_at" => encode_datetime(Map.get(h, :last_exit_at))
    }
  end

  defp encode_bind_conflict(nil), do: nil

  defp encode_bind_conflict(%{disposition: d, holder_pid: pid, port: port, detected_at: at}) do
    %{
      "disposition" => to_string(d),
      "holder_pid" => pid,
      "port" => port,
      "detected_at" => encode_datetime(at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  # T52.2 (ADR-0068 decision 3): the daemon is the single writer, so its stamped
  # `kazi_schema_meta` version is the authoritative `schema_vsn` for the skew
  # handshake. Read defensively -- a `ping` must always answer, so a repo that is
  # unavailable or unstamped omits the field (additive; an old client ignores it)
  # rather than crashing the control connection. `:repo` is injectable for tests.
  defp schema_vsn(opts) do
    repo = Keyword.get(opts, :repo, Kazi.Repo)
    Kazi.ReadModel.Migrate.db_stamped_version(repo)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp os_pid do
    :os.getpid() |> to_string() |> String.to_integer()
  end

  defp uptime_s(nil), do: 0
  defp uptime_s(started_at), do: max(System.monotonic_time(:second) - started_at, 0)

  defp nats_port(nil), do: nil

  defp nats_port(nats_name) do
    Kazi.Daemon.Nats.port(nats_name)
  catch
    :exit, _ -> nil
  end

  defp nats_host(nil), do: nil

  defp nats_host(nats_name) do
    Kazi.Daemon.Nats.host(nats_name)
  catch
    :exit, _ -> nil
  end

  defp nats_token(nil), do: nil

  defp nats_token(nats_name) do
    Kazi.Daemon.Nats.token(nats_name)
  catch
    :exit, _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
