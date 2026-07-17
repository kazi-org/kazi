# The `oss_hygiene` predicate

`oss_hygiene` is the E29/ADR-0034 **internal-leak guard** as a first-class kazi
predicate (T44.7). A public repo must not leak internal-only markers; this
predicate holds the same bar the "no internal-info leak" CI gate does, so a goal
can converge on a scrubbed diff.

It scans the **added lines** of the diff between a base ref and `HEAD` for:

- **private IPv4** (RFC-1918): `192.168.*`, `10.*`, `172.16-31.*`;
- **absolute home paths**: `/Users/<name>/…`, `/home/<name>/…`;
- **internal codenames**: a per-goal **configurable** list (`codenames`) — matched
  case-insensitively as whole-ish tokens. The real names live in your goal-file,
  never hardcoded into kazi (which would itself leak them).

A hit is a `:fail` naming the exact `path:line` and the offending line; a scrubbed
diff is `:pass`. An inability to compute the diff (not a git repo, base ref
unresolvable) is `:error`, never `:fail`.

Introspect every key at runtime with:

```
kazi schema oss_hygiene
```

## Allow-list

Legitimate cases pass — kept in lockstep with
`.github/scripts/no_internal_leak_guard.sh` (the CI gate this predicate ports):

- RFC-5737 example IPs: `192.0.2.*`, `198.51.100.*`, `203.0.113.*`;
- loopback / unspecified: `127.0.0.1`, `0.0.0.0`;
- documentation placeholder home paths: `/Users/<name>`, `/home/USER`, … (an
  angle-bracket placeholder or an all-caps `NAME`/`USER`/`USERNAME`/`YOU` token);
- any line carrying the inline `leak-guard:allow` marker.

## Evidence

A `:fail` carries `%{hits: [%{path:, line:, kind:, content:}], count:, base:}` —
`kind` is `:private_ip`, `:home_path`, or `:codename` — so a fixer sees exactly
which line to scrub. `score` is the hit count (`direction: lower_better`), so the
loop reads progress as the count drops to zero.

## Config keys

| key | required | meaning |
|-----|----------|---------|
| `codenames` | no | Internal codename strings to flag (default `[]`). |
| `base_ref` | no | The ref the diff is taken against (default `"origin/main"`). |

## Example

```toml
[[predicate]]
id = "no-internal-leaks"
provider = "oss_hygiene"
base_ref = "origin/main"
codenames = ["examplecorp-internal", "project-nimbus"]
```

See [ADR-0034](adr/) and `.github/scripts/no_internal_leak_guard.sh` for the CI
gate this predicate mirrors.
