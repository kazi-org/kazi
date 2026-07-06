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

  @script """
  set -m
  parent_pid="$1"; shift
  poll_interval="$1"; shift
  pid_file="$1"; shift
  "$@" &
  child_pid=$!
  echo "$child_pid" > "$pid_file" 2>/dev/null
  (
    while kill -0 "$parent_pid" 2>/dev/null; do
      sleep "$poll_interval"
    done
    kill -TERM -"$child_pid" 2>/dev/null
    sleep 1
    kill -KILL -"$child_pid" 2>/dev/null
  ) &
  watchdog_pid=$!
  wait "$child_pid" 2>/dev/null
  status=$?
  # Group-kill (note the leading "-"): the watchdog's own `sleep` between polls
  # is a SEPARATE exec'd process (a child of the watchdog subshell, its own
  # process group under `set -m`), so a plain `kill "$watchdog_pid"` only kills
  # the subshell and leaves that `sleep` running or up to one whole poll
  # interval, holding the shared stdout/stderr pipe open and delaying
  # `System.cmd/3` (which waits for that pipe's EOF) by the same amount.
  kill -TERM -"$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  exit "$status"
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

  # `sleep` on both GNU coreutils and BSD/macOS accepts fractional seconds, so a
  # sub-second `poll_ms` (as tests use, to keep the watchdog loop fast) renders
  # cleanly rather than truncating to 0 (which would busy-loop).
  defp poll_seconds(poll_ms), do: :erlang.float_to_binary(poll_ms / 1000, decimals: 3)
end
