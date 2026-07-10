defmodule Kazi.Daemon.Probe do
  @moduledoc """
  T51.1: down/stale detection for the daemon's Unix-socket control plane, used
  by both `kazi daemon status|stop` and `Kazi.Daemon.start/1` (a live daemon
  must never be stolen from; a stale socket left by a dead one must never be
  mistaken for "running").

  `probe/1` classifies a socket path without knowing anything about the
  request protocol; `ping/1` and `request/2` speak `Kazi.Daemon.Control`'s
  line-delimited JSON over an already-probed-alive socket.
  """

  @connect_timeout 500
  @recv_timeout 2000

  @typedoc "`:missing` -- no socket file. `:dead` -- a stale file, connection refused. `:alive` -- a live listener accepted the connection."
  @type status :: :missing | :dead | :alive

  @spec probe(Path.t()) :: status()
  def probe(sock_path) do
    if File.exists?(sock_path) do
      case connect(sock_path) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :alive

        {:error, _reason} ->
          :dead
      end
    else
      :missing
    end
  end

  @doc "Sends `{\"op\":\"ping\"}` and decodes the reply. Caller should already know the socket is `:alive`."
  @spec ping(Path.t()) :: {:ok, map()} | {:error, term()}
  def ping(sock_path), do: request(sock_path, %{"op" => "ping"})

  @doc "Sends an arbitrary request map and decodes the single-line JSON reply."
  @spec request(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(sock_path, payload) do
    with {:ok, socket} <- connect(sock_path),
         :ok <- :gen_tcp.send(socket, Jason.encode!(payload) <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, @recv_timeout) do
      :gen_tcp.close(socket)
      Jason.decode(line)
    end
  end

  defp connect(sock_path) do
    :gen_tcp.connect(
      {:local, sock_path},
      0,
      [:binary, packet: :line, active: false],
      @connect_timeout
    )
  end
end
