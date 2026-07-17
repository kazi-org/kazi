defmodule Kazi.TestSupport.FakeDaemonSocket do
  @moduledoc """
  T55.3: a minimal Unix-domain control-socket listener — just enough daemon for
  `Kazi.Daemon.Probe.probe/1` to classify `:alive` and for `Probe.ping/1` to
  receive a one-line JSON reply. The reply is injectable so a test can hand back
  a handshake with or without a `nats_port`, driving the dashboard's
  daemon-detection seam (`KaziWeb.CoordinationSource.select/0`) through its
  daemon-up branch with no real daemon and no NATS.

  Compiled ONLY in the test env (`test/support` is on the `:test` elixirc path).
  The socket lives under `System.tmp_dir!()` (short path — Unix socket paths cap
  at ~104 bytes on macOS).
  """

  @doc """
  Starts the listener and returns its socket path. Every accepted connection is
  read for one line and answered with `reply` as one JSON line, then closed.
  Registers an `ExUnit.Callbacks.on_exit/1` cleanup when called inside a test.
  """
  @spec start!(map()) :: Path.t()
  def start!(reply \\ %{"ok" => true}) do
    path = Path.join(System.tmp_dir!(), "kazi-t553-#{System.unique_integer([:positive])}.sock")
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ifaddr: {:local, path}
      ])

    line = Jason.encode!(reply) <> "\n"
    acceptor = spawn(fn -> accept_loop(listen, line) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp accept_loop(listen, line) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        # A bare probe connects and closes without sending (recv errors out);
        # a ping sends one line and expects one line back.
        case :gen_tcp.recv(sock, 0, 2_000) do
          {:ok, _request} -> :gen_tcp.send(sock, line)
          _closed_or_timeout -> :ok
        end

        :gen_tcp.close(sock)
        accept_loop(listen, line)

      {:error, _closed} ->
        :ok
    end
  end
end
