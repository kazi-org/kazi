defmodule Kazi.Daemon do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the long-lived per-machine `kazi daemon`'s
  lifecycle skeleton — process supervision + a local Unix-socket control plane
  other kazi processes can discover and query.

  T51.2 (ADR-0067 decision points 2-3) adds the session bus: `start/1` fails
  fast, with ONE clear line, when `nats-server` cannot be resolved (the
  daemon does not limp along busless) and, once the supervised `nats-server`
  accepts TCP, runs `Kazi.Bus.Provision.run/1` once so the bus's JetStream
  stream + KV bucket exist before any client can post/read/tell/who.

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
  @spec start(keyword()) :: {:ok, pid()} | {:error, start_error() | :nats_bin_not_found}
  def start(opts \\ []) do
    sock_path = Keyword.get(opts, :sock_path, Supervisor.default_sock_path())
    pid_path = Keyword.get(opts, :pid_path, Supervisor.default_pid_path())

    File.mkdir_p!(Path.dirname(sock_path))

    with {:ok, _bin} <- resolve_bin_unless_connecting(opts) do
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
  end

  # ADR-0067 cross-machine (T51.3): `opts[:nats_host]` means CONNECT, not
  # spawn -- a remote `nats-server` needs no local binary, so the fail-fast
  # gate is skipped entirely.
  defp resolve_bin_unless_connecting(opts) do
    if Keyword.get(opts, :nats_host) do
      {:ok, :connect_mode}
    else
      Kazi.Daemon.Nats.resolve_bin(opts)
    end
  end

  defp do_start(opts, sock_path, pid_path) do
    nats_name = Supervisor.default_nats_name(opts)

    with {:ok, sup_pid} <-
           opts
           |> Keyword.merge(sock_path: sock_path, pid_path: pid_path)
           |> Supervisor.start_link() do
      nats_port = Kazi.Daemon.Nats.port(nats_name)
      nats_host = Kazi.Daemon.Nats.host(nats_name)
      nats_token = Keyword.get(opts, :nats_token)

      # Best-effort and BOUNDED, run in an UNLINKED process: a transient
      # connect race against the just-spawned nats-server (or the daemon
      # being torn down again immediately, as tests do) must never crash
      # `start/1`'s caller -- boot provisioning is idempotent, so a later
      # bus call that finds it missing simply re-runs it (`Kazi.Bus`
      # discovers the daemon fresh per call, never through this pid).
      {provisioner, ref} =
        spawn_monitor(fn ->
          if Kazi.Daemon.Nats.wait_ready(nats_port, 5_000, nats_host, nats_token) == :ok do
            Kazi.Bus.Provision.run(host: nats_host, port: nats_port, auth_token: nats_token)
          end
        end)

      receive do
        {:DOWN, ^ref, :process, ^provisioner, _reason} -> :ok
      after
        6_000 -> :ok
      end

      {:ok, sup_pid}
    end
  end

  defp running_vsn(sock_path) do
    case Probe.ping(sock_path) do
      {:ok, %{"vsn" => vsn}} -> vsn
      _ -> "unknown"
    end
  end
end
