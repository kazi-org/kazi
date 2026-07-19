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

  # T55.7 LANDMINE: `packet: :line` truncates a line longer than the socket's
  # `buffer` SILENTLY -- no error, just a short binary that then fails to
  # decode as JSON. Measured: a 61,461-byte reply came back as 9,216 bytes
  # (the default buffer) with `recv` reporting `:ok`. A bounded digest (40
  # lines, each up to the ~1 KiB render threshold plus provenance) runs to
  # tens of KB, so the default would have corrupted real replies. This is
  # ~16x the worst-case digest; anything genuinely unbounded (`--full`) must
  # NOT come through this socket at all.
  @socket_buffer 1_048_576

  @typedoc "`:missing` -- no socket file. `:dead` -- a stale file, connection refused. `:alive` -- a live listener accepted the connection."
  @type status :: :missing | :dead | :alive

  @spec probe(Path.t()) :: status()
  def probe(sock_path) do
    if File.exists?(sock_path) do
      case safe_connect(sock_path) do
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

  # #1579: a path EXISTS at the socket location but connecting to it either is
  # refused (a crashed daemon's leftover socket) OR raises (a non-socket regular
  # file left at the path — `:gen_tcp.connect` on a non-socket AF_UNIX path is a
  # `:badarg`). Both mean "present but not a working daemon" — `:dead`, never a
  # crash that takes down the probing CLI.
  defp safe_connect(sock_path) do
    connect(sock_path)
  rescue
    _ -> {:error, :not_a_socket}
  catch
    _, _ -> {:error, :not_a_socket}
  end

  @doc "Sends `{\"op\":\"ping\"}` and decodes the reply. Caller should already know the socket is `:alive`."
  @spec ping(Path.t()) :: {:ok, map()} | {:error, term()}
  def ping(sock_path), do: request(sock_path, %{"op" => "ping"})

  @doc """
  Sends an arbitrary request map and decodes the single-line JSON reply.

  `recv_timeout` (ms, default #{@recv_timeout}) is the caller's patience for
  the reply. An op the daemon answers from memory (`ping`) needs no more than
  the default; one it has to do real work for (T55.7's `read`, which may walk
  a deep backlog before it can answer) passes its own budget.
  """
  @spec request(Path.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(sock_path, payload, recv_timeout \\ @recv_timeout) do
    with {:ok, socket} <- connect(sock_path),
         :ok <- :gen_tcp.send(socket, Jason.encode!(payload) <> "\n"),
         {:ok, line} <- :gen_tcp.recv(socket, 0, recv_timeout) do
      :gen_tcp.close(socket)
      Jason.decode(line)
    end
  end

  defp connect(sock_path) do
    :gen_tcp.connect(
      {:local, sock_path},
      0,
      [:binary, packet: :line, active: false, buffer: @socket_buffer],
      @connect_timeout
    )
  end

  @doc "The control socket's line buffer. Public so the listener binds the SAME bound and a test can pin the truncation contract."
  @spec socket_buffer() :: pos_integer()
  def socket_buffer, do: @socket_buffer
end
