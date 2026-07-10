defmodule Kazi.Daemon do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the long-lived per-machine `kazi daemon`'s
  lifecycle skeleton — process supervision + a local Unix-socket control plane
  other kazi processes can discover and query. This task is deliberately
  hermetic: NO NATS, NO bus (those land in T51.2+); it exists so `kazi daemon
  start|stop|status` has a stable seam to build on.

  `Kazi.Daemon` is the entry point both `kazi daemon start` (via
  `Kazi.CLI`) and tests use — it wraps `Kazi.Daemon.Probe`'s down/stale
  detection around `Kazi.Daemon.Supervisor.start_link/1` so a caller never
  races to steal a socket a live daemon holds, and never mistakes a stale
  leftover for "running" (ADR-0067: the daemon degrades gracefully; a dead
  daemon's socket file is cleaned up, not treated as a lock).

  The daemon does NOT start as part of `Kazi.Application`'s normal
  supervision tree — only `start/1` (reached solely by `kazi daemon start`)
  stands up `Kazi.Daemon.Supervisor`. Nothing else in the codebase may depend
  on it.
  """

  alias Kazi.Daemon.{Probe, Supervisor}

  @typedoc "Why `start/1` refused: a live daemon already holds the socket (with its reported vsn), or the listener failed to bind for some other reason."
  @type start_error :: {:already_running, String.t()} | term()

  @doc """
  Starts the daemon supervision tree at `opts[:sock_path]` /
  `opts[:pid_path]` (defaulting to `Kazi.Daemon.Supervisor.default_sock_path/0`
  / `default_pid_path/0`).

  Probes the socket path first: `:alive` refuses with
  `{:error, {:already_running, vsn}}` (never stolen); `:dead` removes the
  stale socket file before starting; `:missing` starts cleanly. Any other
  `opts` (e.g. `:name`, `:listener_name`) pass through to
  `Kazi.Daemon.Supervisor.start_link/1`.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, start_error()}
  def start(opts \\ []) do
    sock_path = Keyword.get(opts, :sock_path, Supervisor.default_sock_path())
    pid_path = Keyword.get(opts, :pid_path, Supervisor.default_pid_path())

    File.mkdir_p!(Path.dirname(sock_path))

    case Probe.probe(sock_path) do
      :alive ->
        {:error, {:already_running, running_vsn(sock_path)}}

      :dead ->
        File.rm(sock_path)
        do_start(opts, sock_path, pid_path)

      :missing ->
        do_start(opts, sock_path, pid_path)
    end
  end

  defp do_start(opts, sock_path, pid_path) do
    opts
    |> Keyword.merge(sock_path: sock_path, pid_path: pid_path)
    |> Supervisor.start_link()
  end

  defp running_vsn(sock_path) do
    case Probe.ping(sock_path) do
      {:ok, %{"vsn" => vsn}} -> vsn
      _ -> "unknown"
    end
  end
end
