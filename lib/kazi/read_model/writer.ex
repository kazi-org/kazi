defmodule Kazi.ReadModel.Writer do
  @moduledoc """
  T52.1 (ADR-0068): the single client-side write-router seam for the read-model.

  Every read-model write entry point routes through `write/2` so there is ONE
  place that decides *who holds the pen* (ADR-0068 decision 1): when the machine's
  daemon is running, writes belong to it (the daemon is the single writer, one
  process on one schema version — the structural fix for the #1019 mixed-migration
  contention class); with no daemon, writes go straight to `Kazi.Repo`, exactly as
  they do today (ADR-0068 decision 5, "no daemon, no change").

  ## What this task lands (and deliberately does not)

  This is the seam and the presence decision only. It moves NO call site yet, so
  behavior is unchanged and every existing read-model test stays green. The
  daemon-side `write` op and a serializing socket client are later E52 tasks; until
  a caller supplies a `:remote` writer, the alive branch falls back to the direct
  `Kazi.Repo` write, so a running daemon never silently drops a write while the
  socket path is still being built. The seam is what ships now; the routing target
  is swapped in additively later (ADR-0068 decision 3, a versioned additive API).

  ## Usage

      Writer.write(fn -> Repo.insert!(changeset) end)

  `write/2` runs `direct` (a zero-arity closure performing today's exact `Repo`
  write) when no daemon is present, and the `:remote` writer when one is. `:remote`
  defaults to `direct`.

  ## Options

    * `:remote`    — a zero-arity closure invoked instead of `direct` when the
      daemon is `:alive` (the socket-client path a later task supplies). Defaults
      to `direct`.
    * `:sock_path` — the daemon control socket to probe. Defaults to
      `Kazi.Daemon.Supervisor.default_sock_path/0`.
    * `:probe`     — a 1-arity presence probe `(sock_path -> :alive | :dead |
      :missing)`. Defaults to `&Kazi.Daemon.Probe.probe/1`. Injectable for tests.
    * `:ttl_ms`    — how long a presence decision is memoized per process before
      the socket is re-probed. Defaults to `#{__MODULE__}` module default.

  ## Memoized presence (per process, short TTL)

  A busy run issues many writes; `stat`-ing the socket on every one would be waste.
  The presence decision is cached in the process dictionary keyed by socket path
  with a short TTL, so a burst of writes probes at most once per window. The cache
  is per process — it never leaks a stale "alive" across an unrelated caller — and
  a probe after the TTL expires picks up a daemon that started or stopped meanwhile.
  """

  alias Kazi.Daemon.{Probe, Supervisor}

  # Short enough that a daemon starting/stopping mid-run is noticed within a
  # second; long enough that a tight write loop probes the socket at most once.
  @default_ttl_ms 1_000

  @typedoc "A zero-arity closure performing a read-model write and returning its result."
  @type writer :: (-> term())

  @doc """
  Route a read-model write through the single-writer seam.

  `direct` is today's exact `Kazi.Repo` write, run as-is when no daemon owns the
  file. When a daemon is `:alive`, the `:remote` writer runs instead (defaulting to
  `direct` until the socket-client path is wired). Returns whatever the chosen
  writer returns.
  """
  @spec write(writer(), keyword()) :: term()
  def write(direct, opts \\ []) when is_function(direct, 0) do
    remote = Keyword.get(opts, :remote, direct)

    case daemon_status(opts) do
      :alive -> remote.()
      _absent -> direct.()
    end
  end

  # Presence, memoized per process with a short TTL (ADR-0068: do not stat the
  # socket on every write of a busy run).
  defp daemon_status(opts) do
    sock_path = Keyword.get(opts, :sock_path, Supervisor.default_sock_path())
    probe = Keyword.get(opts, :probe, &Probe.probe/1)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case Process.get(cache_key(sock_path)) do
      {status, expires_at} when expires_at > now ->
        status

      _expired_or_missing ->
        status = probe.(sock_path)
        Process.put(cache_key(sock_path), {status, now + ttl_ms})
        status
    end
  end

  defp cache_key(sock_path), do: {__MODULE__, :presence, sock_path}
end
