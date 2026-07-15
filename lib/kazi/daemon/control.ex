defmodule Kazi.Daemon.Control do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the daemon's line-delimited JSON control
  protocol, kept separate from `Kazi.Daemon.Listener`'s socket transport so a
  later task (T51.2+, the bus primitives) can add ops here without touching the
  accept loop.

  One op is implemented now: `ping` (the version handshake `status` reports).
  `shutdown` is recognized so the listener can react to it, but the actual
  supervision-tree teardown is the listener's job (`handle/2` only computes the
  reply); an unknown op replies `{"ok":false,"error":"unknown_op"}`.
  """

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
      "uptime_s" => uptime_s(Keyword.get(opts, :started_at)),
      "pid" => os_pid(),
      "nats_port" => nats_port(nats_name),
      "nats_host" => nats_host(nats_name)
    }
    |> maybe_put("nats_token", nats_token(nats_name))
  end

  def handle(%{"op" => "shutdown"}, _opts), do: %{"ok" => true}

  def handle(_other, _opts), do: %{"ok" => false, "error" => "unknown_op"}

  defp vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
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
