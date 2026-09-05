defmodule Kazi.Daemon.Nats do
  @moduledoc """
  T51.2 (ADR-0067 decision point 2): supervises a `nats-server -js` process as
  a linked `Port` so the daemon can run the session bus's JetStream backend
  without an operator standing up their own NATS.

  Binary resolution is `opts[:nats_bin]` (the `kazi daemon start --nats-bin`
  flag) or `System.find_executable("nats-server")`. When neither resolves,
  `start_link/1` returns `{:error, :nats_bin_not_found}` immediately -- the
  daemon does not limp along busless (per the task brief); the caller
  (`Kazi.Daemon.Supervisor`) surfaces this as the ONE clear `kazi daemon
  start` failure line.

  The port binds `opts[:port]` (default 4223 -- deliberately non-standard so
  it never collides with an operator's own NATS on 4222) and stores JetStream
  under `opts[:store_dir]` (default `<state dir>/daemon/jetstream`).
  `wait_ready/2` briefly retries a `Gnat` connection so the caller (the
  supervisor's `init/1`, before `Kazi.Bus.Provision` runs) knows the server
  actually accepted TCP before reporting the daemon ready.

  ADR-0067 cross-machine (T51.3): when `opts[:nats_host]` is set, `init/1`
  skips binary resolution and `Port.open/2` entirely and CONNECTS to that
  remote host/port instead of spawning a local `nats-server` -- `port/1`
  still returns the (remote) port for the control-socket ping and
  `Kazi.Bus.Provision`'s host/port threading. `terminate/2` is then a no-op
  (there is no local OS process to kill). An optional shared
  `opts[:nats_token]` is passed as `-auth <token>` to the spawned server
  (spawn side) or as `auth_token:` on the `Gnat` connect opts (both spawn
  side's `wait_ready/2` and connect side) -- see `docs/session-bus.md`
  ("Cross-machine setup") for the security tradeoff of running without one.

  Issue #1719: the local spawn goes through a `/bin/sh` shim (`@shim`) that
  kills nats-server when the port pipe reaches EOF, so the server dies with the
  BEAM even when the BEAM is signalled away and `terminate/2` never runs.

  Issue #1684: `handle_info/2`'s `:exit_status` clause used to treat EVERY
  nats-server exit as fatal, with no distinction between "this port is
  squatted by an unrelated/orphaned process" (recoverable, self-diagnosable)
  and any other exit. A live incident: an orphaned nats-server (ppid 1, #1719's
  exact symptom) held the daemon's configured port for 10+ hours while the
  supervised nats-server crash-looped with only a generic "nats-server exited"
  line. `classify_bind_conflict/1` runs on every unexpected exit and answers
  BEHAVIORALLY -- "is my configured port currently held by someone else" via
  `lsof`/`ps` -- rather than by parsing nats-server's stderr (log text is
  version/locale-fragile; port occupancy is not). See `handle_orphan/4` /
  `handle_peer/3` / `handle_unresolved/6` for the four dispositions and
  `docs/session-bus.md` ("Bind-conflict recovery") for the full writeup.
  """

  use GenServer
  require Logger

  @default_port 4223
  @ready_retry_ms 100
  @ready_timeout_ms 5_000

  # #1684: the rolling exit-restart window `kazi daemon status` surfaces as
  # `restart_loop`, and the bounded self-heal budget for a genuinely orphaned
  # (ppid 1) same-store-dir holder. 60s/3 mirrors the Supervisor's own default
  # restart intensity (3 restarts / 5s) order-of-magnitude -- loose enough that
  # a couple of incidental exits never falsely cry "loop", tight enough that
  # the exact incident this closes (exits spaced ~seconds apart, all day) trips
  # it within one minute. `@orphan_max_auto_reaps` bounds how many times THIS
  # GenServer will kill-and-retry an orphan before giving up and going fatal
  # (so a holder that is somehow unkillable, or whose death never frees the
  # port, cannot spin an infinite in-process respawn loop).
  @exit_window_ms 60_000
  @exit_loop_threshold 3
  @orphan_max_auto_reaps 3
  @orphan_kill_wait_ms 1_500

  @default_health %{
    restart_loop: false,
    exits_in_window: 0,
    exit_window_ms: @exit_window_ms,
    bind_conflict: nil,
    last_exit_at: nil,
    last_exit_monotonic_ms: nil
  }

  # #1719: nats-server is spawned THROUGH this `/bin/sh` shim instead of as a
  # bare `Port.open({:spawn_executable, bin}, ...)`. A port's OS process has no
  # death pact with the BEAM on macOS/Linux, and the daemon tree runs from the
  # CLI process rather than under `Kazi.Application` -- so when the VM is stopped
  # by a signal (`launchctl kickstart -k`, `kill`, SIGKILL) `terminate/2` never
  # runs and the nats-server is orphaned still holding the TCP port. The next
  # daemon can then never bind it and logs `nats-server exited (status 1)`
  # forever while every client silently talks to the orphan.
  #
  # The shim's stdin IS the port pipe, whose write end only the BEAM holds, so it
  # reaches EOF the instant the VM goes away by ANY means -- including SIGKILL,
  # which no in-BEAM handler can cover. What each line is for:
  #
  #   * `trap ... TERM INT` -- `terminate/2` kills the SHIM (the port's os_pid);
  #     the trap forwards that to nats-server and `wait`s for it, so the shim
  #     outlives nats-server and `wait_for_exit/2` returning still means the TCP
  #     port is genuinely free.
  #   * `exec 4<&0` -- a background command's stdin is reassigned to /dev/null
  #     before its own redirections (POSIX), so the reader below would see an
  #     instant EOF and kill the server at boot. Fd 4 preserves the real pipe.
  #   * the `<&4 &` subshell -- blocks on the pipe and, at EOF, signals the shim
  #     so the SAME trap does the killing (one shutdown path, not two).
  #   * `wait "$p"` in the foreground -- keeps the shim alive exactly as long as
  #     nats-server, so a server that dies on its own still closes the port and
  #     reaches `handle_info/2`'s `:exit_status` clause with its real status.
  @shim """
  p=""
  trap 'if [ -n "$p" ]; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; fi; exit 0' TERM INT
  exec 4<&0
  "$@" </dev/null &
  p=$!
  (trap - TERM INT; while read -r _line; do :; done; kill "$$" 2>/dev/null) <&4 &
  r=$!
  wait "$p"
  rc=$?
  kill "$r" 2>/dev/null
  exit "$rc"
  """

  @shim_shell "/bin/sh"

  defstruct [
    :port,
    :os_pid,
    :nats_host,
    :nats_port,
    :nats_token,
    :nats_bin,
    :store_dir,
    :health_name,
    :os_probe,
    auto_reap_count: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The TCP port the supervised (or remote-connected) nats-server is bound to (for `Kazi.Daemon.Control`'s ping response)."
  @spec port(GenServer.server()) :: pos_integer()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @doc "The nats-server host: `127.0.0.1` when locally spawned, or the connect-mode `opts[:nats_host]`."
  @spec host(GenServer.server()) :: String.t()
  def host(server \\ __MODULE__), do: GenServer.call(server, :host)

  @doc """
  The shared-bus auth token (`opts[:nats_token]`), or `nil` when the bus runs
  unauthenticated. Surfaced through the daemon control handshake so a bus CLIENT
  on the SAME machine can present it to a token-protected nats (issue #1101).
  """
  @spec token(GenServer.server()) :: String.t() | nil
  def token(server \\ __MODULE__), do: GenServer.call(server, :token)

  @doc """
  Point-in-time health for `kazi daemon status` (#1684): the rolling
  exit-restart window and, when detected, the last classified bind-conflict.

  Backed by `:persistent_term`, NOT GenServer state -- deliberately, so it
  survives the very crash it describes. A bind conflict this module cannot
  resolve (see `handle_unresolved/6`) still ends in a fatal `:stop`, and the
  Supervisor respawns a FRESH `Kazi.Daemon.Nats` process afterward; if health
  lived in that process's own state it would reset to "all clear" on every
  such respawn -- exactly backwards for a restart-loop indicator, whose whole
  point is to survive the crash. `server` is the process's registered `name`
  (the same atom passed to `start_link/1`), used here purely as a lookup key,
  never for a `GenServer.call` -- so this ALSO answers correctly in the brief
  window where the named process is between a crash and its respawn.

  Recency-adjusted at read time: once `exit_window_ms` has elapsed since the
  last exit with no new one, `restart_loop` and `exits_in_window` report as
  recovered even though the last-seen `bind_conflict` (a historical fact, not
  a live condition) is kept for the operator's reference.
  """
  @spec health(GenServer.server()) :: map()
  def health(server \\ __MODULE__) do
    stored = :persistent_term.get(health_key(server), @default_health)
    now = System.monotonic_time(:millisecond)

    if is_integer(stored.last_exit_monotonic_ms) and
         now - stored.last_exit_monotonic_ms > @exit_window_ms do
      %{stored | restart_loop: false, exits_in_window: 0}
    else
      stored
    end
  end

  @doc """
  Resolves the `nats-server` binary: an explicit path first, then `PATH`.
  Public so `Kazi.Daemon.start/1` can fail fast (before starting the
  supervision tree) with a clear, single-line error.
  """
  @spec resolve_bin(keyword()) :: {:ok, String.t()} | {:error, :nats_bin_not_found}
  def resolve_bin(opts \\ []) do
    case Keyword.get(opts, :nats_bin) || System.find_executable("nats-server") do
      nil -> {:error, :nats_bin_not_found}
      bin -> {:ok, bin}
    end
  end

  @doc """
  Briefly retries a `Gnat` connection to `host`:`port` until it succeeds or
  `timeout_ms` elapses -- used by the caller to confirm the server is ready
  before running boot provisioning (`Kazi.Bus.Provision`). `host` defaults to
  `127.0.0.1` (the local-spawn case); the connect-mode caller passes the
  remote `opts[:nats_host]` instead. `token` is passed as the `Gnat`
  connection's `auth_token` when the shared bus is running with one.
  """
  @spec wait_ready(pos_integer(), non_neg_integer(), String.t(), String.t() | nil) ::
          :ok | {:error, :timeout}
  def wait_ready(port, timeout_ms \\ @ready_timeout_ms, host \\ "127.0.0.1", token \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_ready(host, port, token, deadline)
  end

  defp do_wait_ready(host, port, token, deadline) do
    case Gnat.start_link(connect_opts(host, port, token)) do
      {:ok, conn} ->
        Gnat.stop(conn)
        :ok

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@ready_retry_ms)
          do_wait_ready(host, port, token, deadline)
        end
    end
  end

  defp connect_opts(host, port, nil), do: %{host: host, port: port}
  defp connect_opts(host, port, token), do: %{host: host, port: port, auth_token: token}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Keyword.get(opts, :nats_host) do
      nil -> init_spawn(opts)
      host -> init_connect(host, opts)
    end
  end

  defp init_connect(host, opts) do
    nats_port = Keyword.get(opts, :port, @default_port)

    {:ok,
     %__MODULE__{
       nats_host: host,
       nats_port: nats_port,
       nats_token: Keyword.get(opts, :nats_token),
       health_name: health_name(opts),
       os_probe: resolve_os_probe(opts)
     }}
  end

  defp init_spawn(opts) do
    with {:ok, bin} <- resolve_bin(opts) do
      nats_port = Keyword.get(opts, :port, @default_port)
      store_dir = Keyword.get(opts, :store_dir, default_store_dir())
      File.mkdir_p!(store_dir)

      token = Keyword.get(opts, :nats_token)

      case do_spawn(bin, nats_port, store_dir, token) do
        {:ok, port, os_pid} ->
          {:ok,
           %__MODULE__{
             port: port,
             os_pid: os_pid,
             nats_host: "127.0.0.1",
             nats_port: nats_port,
             nats_token: token,
             nats_bin: bin,
             store_dir: store_dir,
             health_name: health_name(opts),
             os_probe: resolve_os_probe(opts)
           }}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Shared by `init_spawn/1` (first boot) and `handle_orphan/4` (the #1684
  # reap-then-retry self-heal) -- exactly the same shim-wrapped spawn either
  # way, so a respawned nats-server keeps the #1719 death-pact.
  #
  # #1719: `@shim`'s argv is `sh -c <script> sh <nats-bin> <nats args...>`, so
  # `$0` is `sh` and `"$@"` inside the script is exactly the command that used
  # to be spawned directly. `os_pid` is now the SHIM's pid -- see `terminate/2`
  # for why that keeps the stop path correct.
  defp do_spawn(bin, nats_port, store_dir, token) do
    args = ["-js", "-p", to_string(nats_port), "-sd", store_dir] ++ auth_args(token)

    port =
      Port.open({:spawn_executable, @shim_shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", @shim, "sh", bin | args]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, port, os_pid}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp respawn(state),
    do: do_spawn(state.nats_bin, state.nats_port, state.store_dir, state.nats_token)

  defp auth_args(nil), do: []
  defp auth_args(token), do: ["-auth", token]

  # The registered `name` doubles as the `:persistent_term` health key (see
  # `health/1`) -- stable across every respawn of this daemon's Nats child,
  # which is the property that makes the restart-loop window meaningful.
  defp health_name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.nats_port, state}

  @impl true
  def handle_call(:host, _from, state), do: {:reply, state.nats_host, state}

  @impl true
  def handle_call(:token, _from, state), do: {:reply, state.nats_token, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("nats-server: #{String.trim(data)}")
    {:noreply, state}
  end

  # #1684: EVERY unexpected exit used to be unconditionally fatal. This now
  # classifies the exit first (see `classify_bind_conflict/1`) and only stays
  # fatal for the two cases that genuinely warrant it: a non-bind-conflict
  # exit (`:none`), or a bind conflict this process cannot safely resolve on
  # its own (`handle_unresolved/6`). `bump_exit_history/1` runs unconditionally
  # -- the rolling restart-loop window tracks EVERY exit, recovered or not.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    exits_info = bump_exit_history(state.health_name)

    case classify_bind_conflict(state) do
      {:orphan, pid} ->
        if state.auto_reap_count < @orphan_max_auto_reaps do
          handle_orphan(pid, status, exits_info, state)
        else
          handle_unresolved(
            pid,
            "nats-server",
            :orphan_budget_exhausted,
            status,
            exits_info,
            state
          )
        end

      {:peer, pid} ->
        handle_peer(pid, exits_info, state)

      {:foreign, pid, comm} ->
        handle_unresolved(pid, comm, :foreign, status, exits_info, state)

      {:incompatible, pid} ->
        handle_unresolved(pid, "nats-server", :incompatible, status, exits_info, state)

      :none ->
        handle_plain_exit(status, exits_info, state)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- #1684 bind-conflict detection + disposition ---------------------------

  # BEHAVIORAL detection, not textual: answers "is my configured port
  # currently held by someone else" via `lsof`/`ps` rather than parsing
  # nats-server's stderr for a phrase like "address already in use" (log text
  # is version/locale-fragile across nats-server releases; port occupancy is
  # not). Runs on every unexpected exit -- when nothing else holds the port
  # (`:none`), this is a genuinely unrelated exit and the caller keeps the
  # unchanged fatal-stop behavior.
  #
  # Four dispositions, decided by the holder's `comm` (is it even a
  # nats-server?), whether its command line names OUR `-sd <store_dir>` (is it
  # even OUR data?), and its `ppid` (`1` means reparented to init -- an orphan,
  # #1719's exact symptom; anything else means a live parent still owns it):
  #
  #   * `{:foreign, pid, comm}`     -- not a nats-server at all. Not ours to
  #     touch; stays fatal (`handle_unresolved/6`).
  #   * `{:incompatible, pid}`      -- a nats-server, but a DIFFERENT store dir
  #     (someone else's instance, unrelated data). Not ours; stays fatal.
  #   * `{:orphan, pid}`            -- a nats-server with OUR store dir, ppid 1
  #     (no live parent). Reap it and retry our own spawn
  #     (`handle_orphan/4`).
  #   * `{:peer, pid}`              -- a nats-server with OUR store dir and a
  #     live parent -- another daemon instance beat us to this port serving
  #     the SAME data. Adopt it instead of spawning a second writer against
  #     the same JetStream directory (`handle_peer/3`).
  #
  # `state.os_probe` is the injectable seam (`opts[:os_probe]`, mirroring this
  # codebase's other OS-boundary seams -- `:launchd_os`/`:uid_fn` in
  # `Kazi.CLI`, `:repo_start_fun` in `Kazi.Daemon.Supervisor`): production uses
  # `default_os_probe/0` (real `lsof`/`ps`); tests inject fakes for the one
  # fact that is impractical to fabricate reliably across OSes/sandboxes
  # (genuine ppid-1 reparenting) while exercising the REAL kill/respawn code
  # against a real decoy process.
  defp classify_bind_conflict(%{os_probe: probe} = state) do
    case probe.port_holder.(state.nats_port) do
      nil ->
        :none

      pid ->
        comm = probe.comm.(pid)
        cmdline = probe.cmdline.(pid)
        compatible = is_binary(state.store_dir) and String.contains?(cmdline, state.store_dir)

        cond do
          comm != "nats-server" -> {:foreign, pid, comm || "unknown"}
          not compatible -> {:incompatible, pid}
          probe.ppid.(pid) == 1 -> {:orphan, pid}
          true -> {:peer, pid}
        end
    end
  rescue
    _ -> :none
  catch
    _, _ -> :none
  end

  # Genuine orphan, budget remaining: reap it, then retry OUR spawn on the
  # (now presumably free) port -- self-heals WITHOUT going through `{:stop,
  # ...}`, so the Supervisor's own restart budget (and this process's
  # in-memory `auto_reap_count`) is never touched by the recovery itself, only
  # by how many times reaping was actually NEEDED.
  defp handle_orphan(pid, status, exits_info, state) do
    Logger.error(bind_conflict_message(state.nats_port, pid, "nats-server", :orphan))
    reap_holder(pid)
    publish_health(state.health_name, exits_info, conflict_details(:orphan, pid, state.nats_port))

    case respawn(state) do
      {:ok, port, os_pid} ->
        {:noreply,
         %{state | port: port, os_pid: os_pid, auto_reap_count: state.auto_reap_count + 1}}

      {:error, reason} ->
        Logger.warning(
          "kazi daemon: nats-server exited (status #{status}) -- reap+respawn failed: #{inspect(reason)}"
        )

        {:stop, {:nats_server_exited, status}, state}
    end
  end

  # A live peer daemon already serves this exact store dir on this exact port.
  # Adopting (connect-mode, like `init_connect/2`) is the only safe move -- a
  # SECOND process pointed at the SAME JetStream store dir would corrupt or
  # lock it, so this must never spawn. `os_pid: nil` means `terminate/2`
  # correctly no-ops afterward: this process never owned that OS process.
  defp handle_peer(pid, exits_info, state) do
    Logger.error(bind_conflict_message(state.nats_port, pid, "nats-server", :peer))
    publish_health(state.health_name, exits_info, conflict_details(:peer, pid, state.nats_port))
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  # Foreign process, incompatible-store-dir nats-server, or an orphan whose
  # auto-reap budget is exhausted: a bind conflict this process cannot safely
  # resolve. Logs the distinct, greppable line (in ADDITION to the unchanged
  # generic warning, per #1684's ask) and stays fatal -- killing an arbitrary
  # process we don't recognize, or a nats-server holding someone else's data,
  # is a worse failure mode than a clear crash.
  defp handle_unresolved(pid, comm, disposition, status, exits_info, state) do
    Logger.error(bind_conflict_message(state.nats_port, pid, comm, disposition))

    publish_health(
      state.health_name,
      exits_info,
      conflict_details(disposition, pid, state.nats_port)
    )

    Logger.warning("kazi daemon: nats-server exited (status #{status})")
    {:stop, {:nats_server_exited, status}, state}
  end

  # No holder found at all: a genuinely unrelated exit (killed by an operator,
  # crashed on its own, ...). Unchanged from pre-#1684 behavior -- the ONE
  # difference is `bump_exit_history/1` (already run by the caller) still
  # counts this exit toward the restart-loop window, since "N nats-exits in a
  # short window" cares about ALL exits, not only conflict-caused ones.
  defp handle_plain_exit(status, exits_info, state) do
    Logger.warning("kazi daemon: nats-server exited (status #{status})")
    publish_health(state.health_name, exits_info, nil)
    {:stop, {:nats_server_exited, status}, state}
  end

  defp bind_conflict_message(port, pid, comm, disposition) do
    "nats bind conflict: port #{port} held by pid #{pid} (#{comm}), not ours" <>
      disposition_suffix(disposition)
  end

  defp disposition_suffix(:orphan),
    do: " -- orphaned (ppid 1, matching store dir); reaping and retrying"

  defp disposition_suffix(:orphan_budget_exhausted),
    do: " -- orphaned but auto-reap budget exhausted; giving up"

  defp disposition_suffix(:peer),
    do: " -- a live daemon instance already serves this store dir; adopting its connection"

  defp disposition_suffix(:foreign),
    do: " -- an unrelated process; leaving it alone"

  defp disposition_suffix(:incompatible),
    do: " -- a nats-server with a different store dir; leaving it alone"

  defp reap_holder(pid) do
    System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)
    wait_for_exit(pid, System.monotonic_time(:millisecond) + @orphan_kill_wait_ms)

    if alive_os_pid?(pid) do
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      wait_for_exit(pid, System.monotonic_time(:millisecond) + @orphan_kill_wait_ms)
    end

    :ok
  end

  # -- #1684 exit-history / health bookkeeping (`:persistent_term`-backed) ---

  defp bump_exit_history(name) do
    now = System.monotonic_time(:millisecond)
    key = exit_history_key(name)

    history =
      case :persistent_term.get(key, []) do
        list when is_list(list) -> list
        _other -> []
      end

    pruned = Enum.filter([now | history], &(now - &1 <= @exit_window_ms))
    :persistent_term.put(key, pruned)

    %{count: length(pruned), restart_loop: length(pruned) >= @exit_loop_threshold, at_ms: now}
  end

  defp publish_health(name, exits_info, conflict) do
    health = %{
      restart_loop: exits_info.restart_loop,
      exits_in_window: exits_info.count,
      exit_window_ms: @exit_window_ms,
      bind_conflict: conflict,
      last_exit_at: DateTime.utc_now(),
      last_exit_monotonic_ms: exits_info.at_ms
    }

    :persistent_term.put(health_key(name), health)
  end

  defp conflict_details(disposition, pid, port) do
    %{disposition: disposition, holder_pid: pid, port: port, detected_at: DateTime.utc_now()}
  end

  defp health_key(name), do: {__MODULE__, :health, name}
  defp exit_history_key(name), do: {__MODULE__, :exit_history, name}

  # -- #1684 OS probe (the injectable lsof/ps seam) ---------------------------

  defp default_os_probe do
    %{
      port_holder: &real_port_holder/1,
      comm: &real_holder_comm/1,
      ppid: &real_holder_ppid/1,
      cmdline: &real_holder_cmdline/1
    }
  end

  defp resolve_os_probe(opts) do
    Map.merge(default_os_probe(), Keyword.get(opts, :os_probe, %{}))
  end

  # The PID (if any) with a LISTEN socket on `port`. `-t` (terse) emits bare
  # PIDs, one per line, nothing else to parse.
  defp real_port_holder(port) do
    case System.cmd("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-t"]) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> List.first() |> parse_pid()

      _other ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp parse_pid(nil), do: nil

  defp parse_pid(str) do
    case Integer.parse(String.trim(str)) do
      {pid, _rest} -> pid
      :error -> nil
    end
  end

  defp real_holder_comm(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> Path.basename()
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp real_holder_ppid(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "ppid="], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> parse_pid()
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp real_holder_cmdline(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "command="], stderr_to_stdout: true) do
      {out, 0} -> out
      _other -> ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  @stop_wait_ms 2_000
  @stop_poll_ms 20

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    # Port.close/1 disconnects the port but does not reliably kill the OS
    # process on every platform; send it a real signal too so a `kazi daemon
    # stop` never leaves an orphaned nats-server behind. Then WAIT for the
    # process to actually exit (bounded) so `terminate/2` returning -- and
    # thus `Supervisor.stop/2` returning -- means the port is genuinely free;
    # otherwise the very next daemon instance to start (a live concern in
    # tests, which start/stop the tree repeatedly) can race a still-dying
    # nats-server for the same TCP port.
    #
    # #1719: `os_pid` is the `@shim` shell, not nats-server itself. The signal
    # sent here is what the shim's TERM trap forwards to nats-server, and the
    # shim only exits once it has `wait`ed on nats-server -- so waiting on the
    # shim below still means "nats-server is reaped, the TCP port is free".
    System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
    wait_for_exit(os_pid, System.monotonic_time(:millisecond) + @stop_wait_ms)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp wait_for_exit(os_pid, deadline) do
    if alive_os_pid?(os_pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@stop_poll_ms)
      wait_for_exit(os_pid, deadline)
    else
      :ok
    end
  end

  defp alive_os_pid?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _other -> false
    end
  end

  defp default_store_dir do
    state_dir =
      System.get_env("KAZI_STATE_DIR") ||
        Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join([state_dir, "daemon", "jetstream"])
  end
end
