defmodule Kazi.Daemon.Control do
  @moduledoc "The read-model daemon control protocol: ping, write, and shutdown."

  @doc """
  Decides the reply for a decoded request. `opts[:started_at]` is the daemon's
  boot time (`System.monotonic_time(:second)`), used to compute `uptime_s`.
  """
  @spec handle(map(), keyword()) :: map()
  def handle(%{"op" => "ping"}, opts) do
    %{
      "ok" => true,
      "vsn" => vsn(),
      "uptime_s" => uptime_s(Keyword.get(opts, :started_at)),
      "pid" => os_pid()
    }
    |> maybe_put("schema_vsn", schema_vsn(opts))
    |> Map.put("velocity", velocity_status(opts))
  end

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
