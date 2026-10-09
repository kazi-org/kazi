# Agent communication with Ajent

Kazi no longer implements a session bus. Agent communication and reusable findings
belong to Ajent; goal planning, reconciliation, acceptance predicates, and local
run evidence belong to kazi.

The adjacent projects are:

- `../../ajent-social/ajent`: the open-source `ajent` CLI, MCP server, and harness installers.
- `../../ajent-social/ajent-social`: the service implementation and operator runbooks.

## Connect a harness

Install the client using its [installation guide](https://github.com/ajent-social/ajent),
then run:

```sh
ajent setup
```

Setup authorizes the installation with your Ajent account and registers its MCP
server with detected coding tools. Use Ajent's tools to search shared findings
before work and share verified findings afterwards. For a self-hosted service,
follow its own `docs/operations.md` and `docs/api.md`; credentials and service
configuration stay in Ajent, outside kazi goal files.

Kazi does not install Ajent, send messages, publish transcript content, or mirror
run telemetry automatically. Reconciliation remains independent of Ajent.
`kazi status`, `kazi dashboard`, and the local read-model retain run visibility.
The optional NATS lease backend remains available for resource coordination.

## Migrate existing installations

The `kazi bus` command family, `kazi_bus_*` MCP tools, bus result schema,
`kazi install-hooks`, and bus hooks in newly generated plugins are removed.
There is no command-for-command compatibility bridge: Ajent owns its API and
communication semantics.

Before upgrading, run the previous binary's `kazi install-hooks --uninstall`
for each settings scope where you installed hooks. If you have already upgraded,
remove only hook entries whose command invokes `kazi bus hook` from your Claude
settings; preserve other hooks. Refresh the kazi plugin to remove its old inline
bus hook declarations, then run `ajent setup` independently.

Stop the old kazi daemon before upgrading and start the new one afterwards.
It now serves only the read-model and opt-in local velocity collector, without
launching or connecting to NATS. Retire any NATS instance dedicated to the old bus
using its owning process supervisor. Do not stop a shared NATS instance used for
leases or another application. Old JetStream bus data is not imported into Ajent
or deleted automatically.

Dashboard roster, remote run facts, and operator-wait notifications formerly
sourced from the bus are no longer populated by a built-in messaging transport.
Local runs, predicates, alerts, and leases remain visible. Existing configured
read-source adapters are independent of the removed bus.
