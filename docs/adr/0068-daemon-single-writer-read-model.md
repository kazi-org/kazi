# ADR 0068: The kazi daemon is the single writer for the read-model

## Status
Accepted (builds on the `kazi daemon` introduced in ADR-0067; independently
acceptable -- the daemon could ship with this role alone)

**Implementation note (T52.1).** The client-side write seam of decision 1 is
`Kazi.ReadModel.Writer` (`Writer.write/2`): it makes the presence decision
(`Kazi.Daemon.Probe.probe/1` against `Kazi.Daemon.Supervisor.default_sock_path/0`,
memoized per process) and routes to the daemon or to `Kazi.Repo`. T52.1 lands the
seam and the direct-write passthrough only; moving the ~20 write call sites onto it
and the daemon-side `write` op + version handshake (decisions 1-3) are later E52
tasks, added additively.

## Date
2026-07-10

## Context

Every kazi process on a machine opens the shared read-model database directly
(`~/.kazi/kazi.db`, SQLite WAL, ADR-0005). With today's release cadence plus
long-lived runs, a single machine routinely has *concurrent writers on
different kazi versions carrying different Ecto migration sets* -- three
versions holding the same file simultaneously has been observed during one
release window (issue #1019). The failure modes:

- **Migration-lock deadlocks**: a newer binary migrating while older binaries
  hold connections, and vice versa.
- **Startup hangs** on versions predating Guard coverage of the affected path.
- **Blind runs**: `Kazi.ReadModel.Guard` (the L-0049 never-hang discipline)
  correctly contains the failure and the run continues *without persistence*
  -- no registry row, no duplicate-run guard (the #941 incident class), no
  economics (ADR-0058). Contained, but invisible to the starmap and to every
  other session precisely when coordination matters most.

`busy_timeout` tuning and Guard degradation treat symptoms. The structural
cause is N writers x M schema versions on one SQLite file. ADR-0005 designed
the read-model as a disposable, rebuildable projection -- nothing about that
design requires every process to hold write access to the file; that was
simply the cheapest wiring before any long-lived kazi process existed.
ADR-0067 introduces one.

## Decision

1. **When the daemon is running, it is the only process that opens the
   read-model read-write.** CLI and run processes send writes over the
   daemon's local API (Unix domain socket) instead of opening the file. One
   writer, one version, one connection pool.

2. **Only the daemon migrates**, once, at its own startup. Migration
   contention disappears by construction: there is exactly one process whose
   schema version matters.

3. **Version skew is a handshake, not a lock fight.** Client and daemon
   exchange versions on connect. A client newer than the daemon (the common
   case mid-release-window) gets a clear, single-line outcome: "daemon is
   older than this client; restart it (`kazi daemon restart`) or continue
   without persistence" -- an explicit, visible Guard-style degrade chosen by
   the operator, never an implicit deadlock discovered twenty minutes later.
   A client older than the daemon writes through the daemon's API, which is
   versioned and additive, so old clients keep working across daemon upgrades
   within a major version.

4. **Reads may stay direct.** WAL supports concurrent readers safely; cheap
   read paths (`kazi status`, `kazi economy`) may open the file read-only
   rather than round-trip the socket. Writes are what centralize.

5. **No daemon, no change.** Absent a running daemon, today's behavior stands
   unchanged: direct open, `busy_timeout`, Guard degradation. The daemon is an
   upgrade for machines that run concurrent sessions, not a requirement for
   `brew install kazi && kazi apply` on a laptop.

6. **The live layer gets its intended home.** ADR-0005 assigned the in-memory
   working set to BEAM/ETS, but with only short-lived CLI processes that layer
   never had a stable host. The daemon is that host: the dashboard/starmap
   serves from the daemon's live state when present, falling back to the
   SQLite projection when not.

## Consequences

- The #1019 class is eliminated structurally rather than mitigated: no two
  writers, no two migration sets, no deadlock to contain. The duplicate-run
  guard and run economics stay reliable exactly during release windows, when
  they were previously blind.
- The failure mode moves from "silent contention" to "explicit skew
  handshake" -- strictly better diagnosability, and the remedy
  (`kazi daemon restart`) is one command.
- New obligations: a versioned client-daemon API kept additive within a major
  version, and daemon lifecycle management (start on demand or via the
  operator's service manager; `kazi daemon status|restart`).
- Read-model rebuildability (ADR-0005) is unchanged -- the file remains a
  disposable projection; only who holds the pen changes.
- Because the daemon is the single writer/migrator (decisions 1-2), it STARTS
  the read-model writer itself at boot, before it migrates and before any child
  serves a write (`Kazi.Daemon.Supervisor.ensure_repo_started/1`, #1504): under
  a standalone binary the app supervision tree never stood `Kazi.Repo` up, so
  absent this the boot migration hit "could not lookup Ecto repo ... not
  started" and the daemon served blind (the #1483 writer half). This is
  fail-loud, not a silent degrade: a writer that genuinely cannot start (an
  unwritable state dir, a corrupt db) makes `kazi daemon start` refuse to serve
  (`{:error, _}`, non-zero exit) rather than come up healthy-looking with no
  write path. The boot migration's OWN bounded degrade (a peer holding the lock,
  a newer schema stamp) is unchanged -- that is the visible, logged skew case
  above, not a not-started repo.
- The client-newer-than-daemon skew (decision 3) is realized at write time in
  `Kazi.ReadModel.Writer` (T52.8): with a live daemon whose `ping` `schema_vsn`
  is OLDER than this binary's schema version (`SchemaSkew.classify/2 ==
  :client_newer`), the seam does NOT write blind. It logs exactly

  ```
  daemon is older than this client (schema vN < vM); restart it (`kazi daemon restart`) or continue without persistence
  ```

  and continues Guard-style without persistence, returning the same shaped
  `{:error, :read_model_unavailable}` degrade the no-daemon refuse (T52.7) uses --
  one visible degrade shape, never an implicit deadlock. The daemon's `schema_vsn`
  is read from the handshake at most once per short TTL window (memoized like the
  presence probe, not per write); a daemon that reports no `schema_vsn` writes
  through. The remedy is one command, `kazi daemon restart`. The reverse case (a
  daemon NEWER than the client) writes through the additive API unchanged.

## Alternatives rejected

- **Per-version database files** (`kazi-<vsn>.db`): kills contention but
  splinters exactly the state that must be global -- the duplicate-run guard
  and the run registry would only see runs from their own binary version,
  which is the blind spot #1019 makes dangerous.
- **Version-stamp-and-refuse without a daemon** (older binaries decline to
  touch a newer schema): better than deadlocking and worth keeping as the
  no-daemon fallback hardening, but it maximizes blind runs instead of
  eliminating them -- every release window still degrades persistence for
  every live run.
- **Move the read-model to a server database** (Postgres): ADR-0005 already
  rejected heavier stores for a local, disposable projection; a daemon over
  SQLite gets single-writer semantics without new infrastructure.
- **Serialize writers with coarser locking** (one cross-process file lock
  around all writes): still leaves mixed migration sets racing at startup and
  adds a new deadlock surface; treats the symptom the same way `busy_timeout`
  does, at higher cost.
