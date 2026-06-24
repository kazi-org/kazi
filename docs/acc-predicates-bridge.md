# The `acc:` → predicates bridge (kazi-gated `/apply --pool`)

This is the copy-pasteable procedure for a pooled `/apply` session to turn its
plan task's `acc:` line into objective kazi predicates and gate its own merge on
convergence — L1 ("verification gate") of "kazi under `/apply --pool`"
(ADR-0026). It is the first concrete enabler the kazi repo owns for that ADR.

> Every kazi command and flag below is real — the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime rather than trusting a stale copy.

## Why

A pooled session today decides for itself when its task is "done" — a prose
Definition of Done enforced by trust + CI. ADR-0026 replaces that with an
OBJECTIVE gate: convert the task's `acc:` acceptance criteria into machine-checked
predicates, let kazi persist them and run them, and land the PR only when kazi
reports convergence (including a live probe). The single authoring path is
caller-drafts (ADR-0023): the session SUPPLIES the predicates, so kazi spawns NO
inner model to author them — it applies the deterministic clarify floor,
persists, and gates.

## The two halves

```
  docs/plan.md task `acc:` line
        |  Kazi.Pool.AccBridge.acc_to_predicates/1   (half 1 — this repo)
        v
  caller-drafts predicates JSON
        |  kazi propose --json   (caller-drafts; floor + persist, NO model — half 2)
        v
  a proposed goal  →  kazi approve  →  kazi run   (the convergence gate)
```

`Kazi.Pool.AccBridge` (in `lib/kazi/pool/acc_bridge.ex`) is the thin,
DETERMINISTIC, HERMETIC helper that does half 1: pure parsing, same input → same
output, no I/O. It is NOT a `kazi` CLI subcommand (avoiding `lib/kazi/cli.ex`);
the runner `priv/scripts/acc_to_predicates.exs` exposes it.

## The mapping rules

The `acc:` text is split on `;` (the clause separator real WBS `acc:` lines use)
and each clause is classified to a provider kind:

| clause shape | provider | config emitted |
| --- | --- | --- |
| `ExUnit ...`, `mix test`, "tests pass / green" | `test_runner` | `{"cmd":"mix","args":["test"]}` when a `mix test`/ExUnit signal is present |
| `` `mix format` clean ``, `--check-formatted` | `test_runner` | `{"cmd":"mix","args":["format","--check-formatted"]}` |
| `--warnings-as-errors` clean | `test_runner` | `{"cmd":"mix","args":["compile","--warnings-as-errors"]}` |
| `npx playwright test` / playwright | `test_runner` | `{"cmd":"npx","args":["playwright","test"]}` |
| "the endpoint returns `<status>`", `GET /path returns 200` | `http_probe` | `{"path"\|"url":...,"expect_status":<code>}` (a full URL wins; only a path → relative `path`) |
| "a prod log line ...", "the live predicate passes" | `prod_log` | `{}` |
| anything else | `test_runner` (DESCRIBED) | `{}` — the clause text is kept as `description`; NO command/status is invented |

Two deliberate non-fabrication rules:

- A clause that is not mechanically mappable becomes a best-effort DESCRIBED
  `test_runner` predicate carrying the clause text — never silently dropped, but
  no unverifiable specifics fabricated. The session (or kazi's clarify floor)
  fills in the check.
- An endpoint clause with no pinned status code does NOT get an invented status;
  it stays a described predicate.

## The procedure

```sh
# 0. The task's acc text (everything after `acc:` in the WBS line).
ACC='ExUnit -- the importer yields grouped predicates; `mix format` clean; the endpoint returns 200'

# 1. Bridge it to a caller-drafts predicates payload (pure; --no-start keeps
#    stdout clean — the bridge needs no app boot).
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" > /tmp/acc-predicates.json

# 2. Feed it to kazi caller-drafts. kazi applies the clarify FLOOR (flags a missing
#    live-verification target + scope), persists the proposal, and spawns NO inner
#    model. Read the JSON draft (proposal_ref + the clarify gaps).
kazi propose --json --predicates "$(cat /tmp/acc-predicates.json)"
#    …or pipe it (kazi reads stdin under --json):
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" | kazi propose --json

# 3. Review the floor. If `clarify` flags `live-target`, sharpen the acc (name the
#    deployed URL / add a prod_log clause) and re-bridge — the gate is only honest
#    with a live predicate (ADR-0002, ADR-0026).

# 4. Approve, then run as the MERGE gate. Land the PR only on convergence.
kazi approve <proposal-ref> --json
kazi run --goal <goal-id> --json      # gate: merge only when kazi reports converged
```

## Determinism + hermeticity

`acc_to_predicates/1` is pure: the same `acc:` line always produces the same
payload (ids are derived from clause position + a short content digest, no clock,
no randomness), and it reads nothing but its argument. That is what lets the gate
be reproducible — the predicates a session proposes are a pure function of the
plan task it claimed.

## Scope (what this is NOT)

- It is L1 only — the verification gate. The objective-done loop (L2),
  blast-radius leasing (L3), and shared observability (L4) are later ADR-0026
  layers.
- It does not add a `kazi` CLI subcommand. A `kazi propose --from-acc` flag (or a
  `/apply --verify-with-kazi` gate in the global skill) is a deliberate follow-up
  (T20.2+).
