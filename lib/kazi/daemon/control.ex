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
    %{
      "ok" => true,
      "vsn" => vsn(),
      "uptime_s" => uptime_s(Keyword.get(opts, :started_at)),
      "pid" => os_pid()
    }
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
end
