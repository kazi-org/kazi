# The roadmap artifact (`kazi schema roadmap`)

A **roadmap** is a top-level kazi artifact (T45.1, UC-059, ADR-0075): a
self-contained, DECLARATIVE DAG of goals. It is a NEW artifact type, sibling to a
goal-file — a goal-file declares acceptance predicates; a roadmap references goals
and the `needs` edges between them.

`kazi schema roadmap` emits this shape as a machine-readable descriptor (the same
`{field, type, description}` rows below, plus an `example`), so an agent can
introspect the artifact without external docs.

## Relationship to `--fleet`

The roadmap is the goal-to-goal DAG at the **artifact** tier; `kazi apply --fleet`
(ADR-0065) is the goal-to-goal DAG at the **execution** tier. They are the same DAG
shape, but a roadmap declares its edges CENTRALLY (`needs` in the roadmap file) and
allows INLINE goal-sets, whereas a fleet manifest is a thin list of paths whose
edges live DECENTRALIZED on each goal-file's `[metadata] depends_on`. Rule of thumb:
**roadmap = declare/inspect/validate; fleet = execute.** See ADR-0075.

## File format

A roadmap `.toml` is a `[[goals]]` array. Each entry is one DAG node:

| Field | Type | Description |
|---|---|---|
| `goals` | array&lt;table&gt; | The DAG nodes; at least one is required. |
| `goals[].id` | string | REQUIRED, unique across the roadmap. The handle other entries name in their `needs`. |
| `goals[].path` | string | A goal-file path, resolved relative to the roadmap file's own directory (absolute paths pass through). Loaded via `Kazi.Goal.Loader.load/1`. Mutually exclusive with an inline goal. |
| `goals[].goal` | table | An inline `[goals.goal]` goal-file table, loaded via `Kazi.Goal.Loader.from_map/1`. The entry `id` fills in the goal's `id` when the inline table omits it. Mutually exclusive with `path`. |
| `goals[].needs` | array&lt;string&gt; | OPTIONAL predecessor goal ids. Each must name a declared entry; the whole graph must be acyclic. |

### Example

```toml
[[goals]]
id = "foundation"
path = "goals/foundation.goal.toml"

[[goals]]
id = "api"
path = "goals/api.goal.toml"
needs = ["foundation"]

[[goals]]
id = "ui"
needs = ["api"]

  # an inline goal-set instead of a path
  [goals.goal]
  id = "ui-goal"
  name = "ship the UI"
```

## Validation (`kazi lint <roadmap>`)

`kazi lint` recognizes a roadmap (a file whose top-level shape is a `[[goals]]`
array) and validates the DAG. A roadmap that loads is a **valid DAG** (exit 0),
reporting its node / edge / wave counts. A broken roadmap is a **load error**
(non-zero exit) that NAMES the offending ref:

- a missing or duplicate `id`;
- an entry with neither or both of `path` / inline goal;
- an **unresolvable ref** — a `path` that does not load, or a `needs` id with no
  matching entry (the message names the id);
- a **cycle** — the message lists every goal id on the cycle
  (`a -> b -> c -> a`).

The same validation runs whether the roadmap is loaded programmatically
(`Kazi.Goal.Roadmap.load/1`) or through `kazi lint`.

## Outline goals: planning as a convergeable goal (T45.3)

A roadmap node can be an **outline phase** — a goal that carries a
`plan_expanded` predicate plus a dispatchable planning work-item. The predicate is
a DETERMINISTIC, **read-model-only** check (no harness needed to evaluate it) that
a referenced goal-set `<phase-ref>` — a roadmap ref (`kazi plan --project`) or a
single proposal ref — has been planned:

1. **exists** — the goal-set is present in the read-model;
2. **floor** — every goal passes the deterministic clarify floor with no open gaps;
3. **approved** — every member proposal is `approved`.

While the phase is unplanned the predicate is `:fail` (naming which condition), so
the loop routes work at authoring the phase's goal-set via `kazi plan`, informed
by the CONVERGED FRONTIER's evidence — the prior phase's actual results feed what
the harness is asked to plan next. Because the outline goal sits behind a `needs`
edge on the frontier it depends on, its planning work-item is scheduled only in a
LATER topological wave (`Kazi.Goal.Roadmap.frontiers/1`) — it cannot be dispatched
until that frontier converges. A STANDING roadmap apply thus triggers the
phase-N+1 planning pass automatically once phase N converges. See `kazi schema
plan_expanded`.
