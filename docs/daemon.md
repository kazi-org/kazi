# Read-model daemon

The optional per-machine daemon serves the local SQLite read-model through a
Unix socket. It serializes writes, migrates before serving, and runs the opt-in
local velocity collector. It does not launch NATS or provide agent messaging.

```sh
kazi daemon start               # foreground
kazi daemon status --json
kazi daemon restart             # stop, then start
kazi daemon stop
```

The control protocol supports `ping`, `write`, and `shutdown`. The version
handshake includes the binary version, PID, uptime, stamped `schema_vsn`, and
velocity collector status. Read-model clients retain their schema-skew checks.
Convergence does not require the daemon.

For managed startup, the existing launchd/systemd templates still run
`kazi daemon start`. On macOS, `kazi daemon reregister` refreshes a registered
LaunchAgent after an in-place binary upgrade. Daemon commands no longer accept
`--nats-bin`, `--nats-port`, `--nats-host`, or `--nats-token`.

See [Ajent migration](ajent.md) for retiring old bus hooks and dedicated NATS
processes.
