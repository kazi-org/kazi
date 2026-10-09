defmodule Kazi.Daemon do
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
    with {:ok, sup_pid} <-
           opts
           |> Keyword.merge(sock_path: sock_path, pid_path: pid_path)
           |> start_supervisor() do
      {:ok, sup_pid}
    end
  end

  # `Supervisor.start_link/1` LINKS the new tree to us. On a SUCCESSFUL boot that
  # is what we want (a foreground `kazi daemon start` should die with its tree).
  # But a FAILED boot -- the daemon supervisor giving up when a child cannot
  # start, e.g. the read-model writer refusing to open (#1504) -- makes the
  # supervisor exit with a `{:shutdown, {:failed_to_start_child, ...}}` reason
  # that, over that same link, would KILL this (the CLI / caller) process rather
  # than surface as the `{:error, _}` `start/1` is documented to return. So we
  # trap exits ONLY across the start: a boot failure comes back as a clean
  # `{:error, reason}` the caller reports ("could not start daemon"), never a
  # crash. On success we restore the prior flag and stay linked (the running
  # tree behaves exactly as before); on failure we drain the trapped signal so a
  # later non-trapping `receive` never sees it. This is the same
  # crash-must-not-reach-the-caller discipline the unlinked provisioner above
  # already applies to nats provisioning.
  defp start_supervisor(sup_opts) do
    prev_trap = Process.flag(:trap_exit, true)

    case Supervisor.start_link(sup_opts) do
      {:ok, _sup_pid} = ok ->
        Process.flag(:trap_exit, prev_trap)
        ok

      {:error, _reason} = error ->
        drain_start_exit()
        Process.flag(:trap_exit, prev_trap)
        error
    end
  end

  # A failed `Supervisor.start_link/1` under a trapping caller leaves the tree's
  # `{:EXIT, sup_pid, reason}` in our mailbox; drop it so it never leaks into a
  # later receive.
  defp drain_start_exit do
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp running_vsn(sock_path) do
    case Probe.ping(sock_path) do
      {:ok, %{"vsn" => vsn}} -> vsn
      _ -> "unknown"
    end
  end
end
