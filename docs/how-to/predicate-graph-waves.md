# Predicate-graph waves (the `needs` edges + the parallel scheduler)

kazi parallelizes a goal-set across two independent axes, and a large goal usually
needs both:

- **Spatial** (E21/ADR-0027): the native scheduler partitions a goal-set by
  **blast radius** and drives one supervised reconciler per partition under a
  `DynamicSupervisor`. Disjoint partitions converge **concurrently**, single-node,
  **NATS-free** (an in-memory lease + the BEAM). `kazi apply <file> --parallel`.

- **Semantic** (E23/ADR-0028): predicate **groups** carry `needs` edges, and the
  scheduler executes that dependency DAG **topologically** -- a group dispatches
  only after every one of its `needs` deps has **objectively converged** (its
  predicates true, evidence-backed), pipelined so a group runs the moment ITS deps
  converge, with **no global wave barrier**.

Together these are kazi's codification of a hand-authored "task deps + waves"
workflow: you author the dependency edges once; kazi computes (and re-computes) the
schedule. This guide shows how to express the edges and how to read the schedule.

## Express the dependency with `needs`

`needs` is an optional array on a `[[group]]` entry: the group ids that must
converge **before** this group. It is **distinct from `parent`** -- `parent`
drives budget rollup and reporting (ADR-0020); `needs` declares execution order
(ADR-0028). A group may carry both, unrelated to one another.

```toml
[[group]]
id = "result-contract"
name = "Result contract"
# no needs -> frontier 1 (runs immediately)

[[group]]
id = "health"
name = "Health endpoint"
# no needs -> also frontier 1; disjoint files from result-contract -> runs in parallel

[[group]]
id = "streaming"
name = "Streaming endpoint"
needs = ["result-contract"]   # frontier 2: dispatches only after result-contract converges
```

The `needs` graph is validated at **load** (T23.1): every referenced id must be a
declared group, no self-edge, and no cycle (a DAG is required). An unknown id, a
self-edge, or a cycle is a hard load error -- the same drift guard as `parent`.

`needs` is the one input kazi **cannot derive**. Blast-radius partitioning gives it
*spatial* disjointness ("these groups touch different files"), but spatial
disjointness is not logical independence -- `streaming` can consume
`result-contract`'s output while editing entirely different files. That precedence
is human/LLM judgment; kazi computes everything downstream of it. Over-declaring
`needs` re-serializes and loses parallelism, so declare only real dependencies --
and use `--explain` (below) to see the cost.

See `priv/examples/predicate_graph_waves.toml` for a complete, runnable goal-file.

## See the computed schedule before running it

`kazi apply <file> --explain` (alias `--dry-run`) prints the computed wave
schedule -- the topological `needs`-DAG frontiers and the blast-radius parallelism
within each -- and **exits 0 without dispatching anything**. Use it to confirm the
schedule (and to catch over-constraint) before a real run:

```sh
kazi apply priv/examples/predicate_graph_waves.toml --workspace <scratch-repo> --explain --json
```

For the example above the schedule is:

```
Frontier 1 (concurrent):  result-contract  ||  health
Frontier 2 (after rc):    streaming
```

Partition quality follows the blast radius each group's terms resolve to. With a
code-review-graph present, the radius is the graph's `--impacted` set; without one,
kazi falls back to a file-scan repo map scoped to the paths your group's terms
mention. Groups whose terms (a group's `partition_terms`, else its group id) map to
**disjoint** paths land in separate partitions and run concurrently; groups whose
terms hit the **same** file merge into one partition and serialize. If `--explain`
shows two groups you expect to be disjoint collapsed into one partition, their terms
are resolving to overlapping paths -- name the groups (or set `partition_terms`)
after the distinct files each touches, or refresh a stale graph, before claiming
concurrency.

## Run it (parallel, NATS-free) and read the result

```sh
kazi apply priv/examples/predicate_graph_waves.toml --workspace <scratch-repo> --parallel --json
```

`--json` emits the versioned collective result: each group's readiness and
convergence state, the topological order taken, and -- if a dep group goes
`stuck`/`over_budget` -- the **blocked sub-DAG with the blocking dep named** (the
scheduler escalates rather than hanging silently). The live `/dag` LiveView renders
the same DAG with per-group state during a run (running / ready / blocked /
converged), read-only.

Two adaptive properties fall out of "readiness = objective convergence":

- **Re-gating on regression**: if a converged dep later regresses, its dependents
  return to not-ready and re-converge -- the DAG is re-evaluated against observed
  state each cycle, not planned once.
- **No slowest-in-wave tax**: a downstream group starts the instant ITS deps
  converge, not when its whole frontier finishes.

## Dogfood runbook (plan tasks T23.9 + T21.12)

The example goal-file is also the dogfood fixture proving both open dogfood tasks
in one run: T23.9 (predicate-graph waves) and T21.12 (native parallelism). Run it
against a **scratch** service -- never the kazi repo itself.

### 1. Prepare the scratch target

```sh
SCRATCH=$(mktemp -d)/widget-svc
mkdir -p "$SCRATCH" && cd "$SCRATCH"
git init -q && go mod init example.com/widget-svc
printf 'package main\nfunc main() {}\n' > main.go     # a main so `go test ./...` runs
git add -A && git commit -qm "seed: empty service (capabilities absent at t0)"
```

All predicates fail here at t0 (no widget.go / health.go / stream.go), so the
vacuous-goal guard (T2.3) passes and the failing set is the work-list.

### 2. Confirm the schedule, then run it

```sh
kazi apply priv/examples/predicate_graph_waves.toml --workspace "$SCRATCH" --explain --json   # save: the order taken
kazi apply priv/examples/predicate_graph_waves.toml --workspace "$SCRATCH" --parallel --json | tee /tmp/collective.json
```

While it runs, open `/dag` and screenshot the transitions: frontier-1 both
**running** with `streaming` **blocked** -> `result-contract` **converged** ->
`streaming` **running** -> all **converged**.

### 3. Force a blocked-dep escalation

Re-run against a fresh scratch dir with `result-contract` unable to converge (a
tiny iteration budget) and confirm the collective JSON reports
`result-contract` terminal `stuck`/`over_budget`, `streaming.blocked_by =
"result-contract"`, `health` still finishing, and **no hang**.

### 4. Record the evidence (Definition of Done: report honestly)

Append to `docs/devlog.md` for each task -- and be honest if anything fell short:

- **T21.12**: partition count, concurrency observed (overlapping wall-clock from
  the JSON timestamps or the `/dag` screenshots), collective convergence, merge
  result.
- **T23.9**: order taken (the `--explain` frontiers), intra-frontier parallelism,
  the blocked-dep escalation from step 3.

Then mark `[x] T21.12` / `[x] T23.9` in `docs/plans/E21.md` / `docs/plans/E23.md`
with the `Done:` date and a one-line pointer to the devlog entry.

## See also

- `docs/adr/0027-kazi-owns-parallelization-native-scheduler.md` -- the spatial scheduler.
- `docs/adr/0028-dependency-aware-partitioning-predicate-graph-waves.md` -- the `needs` DAG.
- `docs/adr/0020-hierarchical-predicate-grouping.md` -- the `[[group]]` taxonomy `needs` extends.
- `priv/examples/grouped_taxonomy.toml` -- a group taxonomy without `needs`.
