defmodule Kazi.Harness.ChildSupervisor do
  @moduledoc """
  Ties a dispatched harness subprocess's lifetime to the controller's (issue
  #857): `Kazi.Harness.CliAdapter` wraps every harness invocation through
  `wrap/3` instead of running the command directly, so a controller that dies
  — including an uncatchable `SIGKILL`/crash, not just a graceful shutdown —
  cannot leave a grinding, unsupervised agent behind (the #856 abnormal-exit
  path).

  ## Why a wrapper script, not a BEAM-side mechanism

  Erlang's port machinery only reaps a spawned OS process when the emulator
  exits NORMALLY (closing the port runs cleanup); a `kill -9` on the emulator
  gives it no chance to run any cleanup code at all, so the child is orphaned
  regardless of anything done in Elixir. The fix has to live entirely at the
  OS-process level, outside the BEAM: `wrap/3` renders a small POSIX `sh`
  script that

    1. backgrounds the real command as its own process-group leader (`set -m`
       job control, portable to both bash and dash — no `setsid` binary
       needed, notably absent from stock macOS);
    2. writes that command's OS pid to `pid_file` (the side channel
       `CliAdapter` reads back to record on the run registry, issue #857's
       second ask);
    3. forks a background watchdog that polls whether `parent_pid` (the
       controller, `System.pid()` by default) is still alive, and once it
       is not, kills the ENTIRE process group the real command leads.

  A normal dispatch never trips the watchdog — it just idles until the wrapped
  command exits, at which point its exit status is propagated unchanged and
  the watchdog is reaped. Combined stdout+stderr streams through exactly as if
  the command had been run directly, since backgrounding via `&` does not
  change file-descriptor inheritance.

  `parent_pid`/`poll_ms` are overridable opts purely so tests can simulate
  "the controller died" against a synthetic pid instead of the real BEAM
  process (which would end the test process too).
  """

  # Default watchdog poll interval: responsive without meaningfully polling.
  @default_poll_ms 1_000

  # Grace between the group TERM and the group KILL in `reap/1` -- matches the
  # wrapper watchdog's own `sleep 1` between its escalating signals.
  @reap_grace_ms 1_000

  # PORTABILITY (the Linux-CI hang): `set -m` gives every background job its
  # own process group under bash (macOS /bin/sh), but NON-INTERACTIVE dash
  # (Ubuntu /bin/sh) quietly ignores it — background jobs stay in the
  # wrapper's own group, so a group-kill (`kill -- -$pid`) fails with "no such
  # process group". Two consequences the script must survive: (1) the
  # watchdog cannot be assumed killable BY GROUP, so every group-kill carries
  # a single-pid fallback; (2) more fundamentally, the watchdog must NEVER
  # hold the dispatch's stdout/stderr pipe — it is forked with all three fds
  # detached to /dev/null, so even a watchdog that outlives the wrapper (dash,
  # fallback kill racing a poll `sleep`) cannot delay the port's EOF and hang
  # `System.cmd/3`. On dash the child also runs in the wrapper's group, so
  # the watchdog's group-kill of the child degrades to a direct kill of the
  # child pid — the harness process itself still dies with the controller;
  # only grandchildren it spawned may need their own reaping there.
  @script """
  { set -m; } 2>/dev/null
  parent_pid="$1"; shift
  poll_interval="$1"; shift
  pid_file="$1"; shift
  wrapper_pid=$$
  # Make the child a REAL process-group leader everywhere: `setsid` where it
  # exists (Linux -- dash's inert `set -m` gives background jobs no group of
  # their own), plain `&` where it does not (macOS ships no setsid binary, but
  # its /bin/sh is bash, whose non-interactive `set -m` genuinely groups
  # background jobs).
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
  else
    "$@" &
  fi
  child_pid=$!
  echo "$child_pid" > "$pid_file" 2>/dev/null
  # The watchdog is DOUBLE-FORKED ( ( ... & ) ) so it is never a job of this
  # shell: no asynchronous "Terminated" job notice can ever leak into the
  # dispatch's merged output, and the wrapper never has to kill or wait for
  # it. It self-exits within one poll once EITHER pid is gone: the controller
  # (then it reaps the child's whole group first -- the issue #857 case) or
  # this wrapper (normal completion -- nothing to do). All three fds are
  # detached so it can never hold the dispatch pipe's EOF hostage.
  # Group kills go through `env kill` (the EXTERNAL kill): dash's builtin
  # rejects negative-pid group syntax outright ("Illegal number"), which is
  # exactly how the child's grandchildren survived on Linux CI. The single-pid
  # fallback covers a shell where no group was created at all.
  (
    (
      while kill -0 "$parent_pid" 2>/dev/null && kill -0 "$wrapper_pid" 2>/dev/null; do
        sleep "$poll_interval"
      done
      if ! kill -0 "$parent_pid" 2>/dev/null; then
        env kill -TERM -- -"$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null
        sleep 1
        env kill -KILL -- -"$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null
      fi
    ) </dev/null >/dev/null 2>&1 &
  )
  wait "$child_pid" 2>/dev/null
  exit $?
  """

  @doc """
  Wraps `command`/`args` so the resulting `{cmd, args}` — meant to be run
  exactly where `command`/`args` would have been, e.g. via `System.cmd/3` —
  dies when `opts[:parent_pid]` (default `System.pid/0`, the current
  controller) does, and reports the wrapped command's own OS pid on
  `opts[:pid_file]` (required).

  The command/args are passed as raw argv entries after the script text, so
  the OS execs them directly (no additional shell word-splitting or
  injection risk from prompt text/flags containing shell metacharacters).
  """
  @spec wrap(String.t(), [String.t()], keyword()) :: {String.t(), [String.t()]}
  def wrap(command, args, opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    parent_pid = Keyword.get(opts, :parent_pid, System.pid())
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    pid_file = Keyword.fetch!(opts, :pid_file)

    {"sh",
     [
       "-c",
       @script,
       "sh",
       to_string(parent_pid),
       poll_seconds(poll_ms),
       pid_file,
       command | args
     ]}
  end

  @doc """
  True when the OS process `pid` (an integer or its string form) is alive —
  i.e. `kill -0 pid` succeeds. Used both by the watchdog's own liveness check
  conceptually and, in Elixir, by the orphan-on-resume check (issue #857)
  deciding whether a prior run's recorded `harness_child_pid` is still
  running. Never raises: an unparseable/blank pid, or a `kill` invocation
  failure, is treated as "not alive" (no evidence of life).
  """
  @spec alive?(String.t() | integer()) :: boolean()
  def alive?(pid) when is_integer(pid), do: alive?(Integer.to_string(pid))

  def alive?(pid) when is_binary(pid) and pid != "" do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def alive?(_pid), do: false

  @doc """
  Reaps the process group led by `pid` (an integer or its string form) --
  a graceful `TERM` to the whole group, then, after a short grace, a `KILL`.
  Used by `kazi orphans --reap` to kill a launcher-orphaned dispatch tree whose
  recorded `harness_child_pid` is still `alive?/1`.

  Mirrors the wrapper watchdog's kill shape (issue #857): the group kill goes
  through the EXTERNAL `env kill` (dash's builtin rejects negative-pid group
  syntax), with a single-pid fallback for a shell where no group was created.
  Best-effort and never raises: a pid that is already gone is a no-op.

  Returns `:ok` when the pid was live and a signal was sent, `:not_alive` when
  it was already dead (nothing to reap).
  """
  @spec reap(String.t() | integer()) :: :ok | :not_alive
  def reap(pid) when is_integer(pid), do: reap(Integer.to_string(pid))

  def reap(pid) when is_binary(pid) and pid != "" do
    if alive?(pid) do
      group_or_pid("TERM", pid)
      Process.sleep(@reap_grace_ms)
      group_or_pid("KILL", pid)
      :ok
    else
      :not_alive
    end
  rescue
    _ -> :not_alive
  end

  def reap(_pid), do: :not_alive

  # `env kill -SIG -- -PID` signals the whole process group (the child is its
  # group leader, per the wrapper); the `|| kill -SIG PID` fallback covers a
  # shell where no group was created (dash's inert `set -m`).
  defp group_or_pid(signal, pid) do
    case System.cmd("env", ["kill", "-" <> signal, "--", "-" <> pid], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      _ ->
        _ = System.cmd("kill", ["-" <> signal, pid], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  # `sleep` on both GNU coreutils and BSD/macOS accepts fractional seconds, so a
  # sub-second `poll_ms` (as tests use, to keep the watchdog loop fast) renders
  # cleanly rather than truncating to 0 (which would busy-loop).
  defp poll_seconds(poll_ms), do: :erlang.float_to_binary(poll_ms / 1000, decimals: 3)
end
