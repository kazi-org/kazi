# Per-task model tiering in the pool (the cheap-inner-loop recipe, L2)

A pooled `/apply` session can run the INNER convergence loop on a cheap/local
harness so the pool runs cheaper, while kazi's OBJECTIVE predicates keep the
cheap model honest. This is the model-tiering option of L2 ("objective done +
convergence loop per task") in "kazi under `/apply --pool`" (ADR-0026).

The split is simple: the STRONG model (the orchestrating session) spends its
expensive reasoning ONCE on what "done" means -- it authors the predicates. The
CHEAP model spends its compute on the iterative grind of editing until those
predicates pass. kazi holds the bar still in between, so a cheap implementer
cannot declare victory on plausible-but-wrong work.

This doc is the tiering ADDENDUM to two recipes; it does NOT restate the JSON
contract or the per-task loop:

- `docs/orchestrator-recipe.md` (T15.8) -- the CANONICAL recipe + the `--json`
  field shapes, `schema_version`, and runtime introspection. Read it for the
  contract.
- `docs/drive-kazi-pooled-task.md` (T20.4) -- the full per-task pool loop (claim
  -> bridge -> propose -> approve -> run -> branch) with the guards. Read it for
  how a pool session applies the contract per task.

Read THIS for the one decision those recipes leave to the orchestrator: which
harness/model drives the inner loop, and the honest caveat on doing it cheap.

> Every kazi command and flag below is real -- the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime rather than trusting a stale copy.


## 1. The two-tier economics

kazi sits in the MIDDLE of a three-layer stack (concept ss4, ADR-0023):

```
  orchestrator session  (strong model -- AUTHORS predicates, owns model policy)
        |  drives kazi as a tool  (the pool-task recipe)
        v
      kazi               (the controller -- objective predicates + convergence loop)
        |  drives the inner harness per --harness/--model
        v
  cheap implementer      (opencode -> local Qwen, codex, claw, ... -- the keystrokes)
```

Spend the expensive brain ONCE, on judgment -- the acceptance predicates. Spend
the cheap brain on the grind. The orchestrator owns the per-phase model policy;
kazi bakes NONE of it in -- it just exposes the levers (`--harness` / `--model`
per call) and stays a pure tool. Objective termination makes the split safe:
truth lives in the controller, not in the model doing the keystrokes.

In a pool of K sessions, K loops grinding on a cheap/local harness can be much
cheaper than K loops on a strong cloud model -- but only when the cheap harness
actually converges the task in a usable window (sec. 4).


## 2. The tiered invocation

Two tiers, two `kazi` calls. The ONLY difference from the un-tiered pool recipe
is the harness/model on the `run` call.

### Tier 1 -- the strong session AUTHORS the predicates (caller-drafts)

The orchestrating session has already reasoned about the task, so it supplies
the predicates; kazi spawns NO inner model (ADR-0023 caller-drafts, the single
authoring path). This is where the expensive reasoning is spent:

```sh
# bridge the plan task's acc: line -> a caller-drafts payload (T20.1)
mix run --no-start priv/scripts/acc_to_predicates.exs "$ACC" > /tmp/acc-predicates.json

# propose: floor + persist, NO model spawned
kazi plan --json --predicates "$(cat /tmp/acc-predicates.json)"

# review the clarify gaps (sharpen acc: + re-bridge if a live target is missing),
# then approve the proposal_ref the propose result returned
kazi approve <proposal-ref> --json
```

The propose/approve mechanics, the `clarify` floor, and the goal-file note (run
takes a PATH, not the goal id) are unchanged -- see
`docs/drive-kazi-pooled-task.md` sections 2.Step-1..3.

### Tier 2 -- the CHEAP harness drives the inner loop

Run the approved goal-file with a cheap/local harness. `--harness` selects the
profile; `--model` overrides the goal-file's harness model:

```sh
# cheap/local: opencode wired to a locally-hosted model
kazi apply <goal-file> --workspace <ws> --harness opencode --model local/qwen3.6 --json

# follow a long convergence live (one JSONL line per iteration, terminal object last)
kazi apply <goal-file> --workspace <ws> --harness opencode --model local/qwen3.6 --json --stream
```

`--harness` accepts the registered profile ids: `claude` (default), `opencode`,
`codex`, `antigravity`, `claw` (`Kazi.Harness.Registry.ids/0`). `run --json`
emits ONE terminal result object; the exit code mirrors convergence (`0` ONLY on
`converged`). The session branches on the terminal `status` / `next_action` and
MERGES ONLY on `converged` -- the branch table is in
`docs/drive-kazi-pooled-task.md` section 3. Confirm flags at runtime:

```sh
kazi help --json | jq '.commands[] | select(.name=="run") | .flags'
```

Harness tiers differ in fidelity (ADR-0016, ADR-0022), and the choice is honest
about it:

- `opencode` / `codex` -- non-interactive, machine-parseable stdout (NDJSON);
  `--model` selects the provider/model; budget tokens reported or estimated.
- `claw` -- BEST-EFFORT only: no documented JSON output and NO model flag
  (ADR-0022; its profile's `supported_opts` is `[:command]`, so `--model` does
  not apply). kazi runs it with a raw-stdout parser and DEGRADED cost/structured
  extraction, labelled so -- never a brittle scrape pretending to be structured.

Whatever the tier, kazi's predicate vector is the same objective bar; a weaker
or cheaper implementer changes how long convergence takes, not what counts as
done.


## 3. Why the cheap tier stays honest (no false converge)

The cheap model cannot fake done. Termination is the controller's, evidence-
backed -- the false-completion class ADR-0026 hardens. Concretely (the guards
live in `lib/kazi/loop.ex`; the pool recipe section 4 details them):

- A red predicate after the cheap implementer's pass is just the next
  observation's work-list -- the loop RE-DISPATCHES, it does not terminate.
- A live (`http_probe` / `prod_log`) predicate passes ONLY post-deploy, against
  the real world -- a cheap model "looking confident" never satisfies it.
- The stuck / regression / flake / budget guards turn a non-converging cheap run
  into a reported `stuck` / `over_budget`, not a silent false done.

So a fixture task driven by the cheap harness has exactly two honest outcomes:
it CONVERGES (every predicate genuinely held, incl. the live probe), or it
yields a truthful non-converge (`stuck` / `over_budget` / capped). There is no
third "the cheap model said it's fine" path.


## 4. The honest caveat: end-to-end value is gated by inner-harness speed

Cheap per-dispatch dollars are real, but the END-TO-END win is gated by the
cheap harness's SPEED and quality, not by kazi. This is measured, not
hypothetical:

- **T8.11 / 2026-06-22 (heterogeneous dogfood).** Claude authored a tiny broken
  Go fixture; kazi drove `opencode --model local-ollama/qwen3.6:35b-a3b-q8_0`. The
  WIRING was proven end to end -- kazi observed the objective failure, persisted
  iteration 0, dispatched opencode -> the local GPU host, and objective termination held
  (kazi could not declare success while the predicate failed). But opencode ran
  ~40 min on iteration 1 and never produced an edit, so the goal did NOT converge
  in a usable window. The bottleneck is the LOCAL MODEL's agentic throughput
  (several slow model calls per turn on the q8_0 35B), not kazi.

- **2026-06-24 (A/B/C token benchmark, arm C).** kazi correctly observed the
  failure and dispatched opencode -> the local Qwen, but the 35B q8_0 did not return
  within ~6 min (reconfirming T8.11). Per-dispatch cost is ~$0 (local compute) --
  the cheaper story in $ STRUCTURE -- but it is bottlenecked by inner-harness
  throughput. The "cheaper" headline still needs a multi-iteration benchmark on a
  FASTER local model.

- **claw** is best-effort / no-JSON by design (ADR-0022) -- a demo-grade tier,
  not a converge-in-a-window bet.

**The takeaway (the landmine).** "Strong model plans, cheap/local model
implements" is mechanically sound and kazi's correctness guarantee holds
regardless of implementer quality -- but its PRACTICALITY is gated by local-model
speed. A local ~35B q8_0 model via opencode was too slow for an interactive convergence
loop. To make a tiered pool task actually converge cheap, use a FASTER local
model (smaller / lower-quant, or a faster server), or accept long wall-clock for
batch-style runs. What you must NOT do is read slowness as a reason to relax the
bar: a tiered task either converges via the cheap harness OR returns an honest
"wiring proven, too slow" result like the opencode smoke -- NEVER a false
converge, because the predicates are objective.

Pick the tier per task: tier DOWN to a cheap/local harness when the task is a
mechanical grind a fast local model can chew through; keep the strong harness
(`--harness claude`, the default) when latency matters more than per-dispatch
dollars. The orchestrator owns that policy; kazi just runs whichever harness you
name and holds the same bar.


## See also

- `docs/orchestrator-recipe.md` (T15.8) -- the canonical recipe + the `--json`
  contract this addendum tiers.
- `docs/drive-kazi-pooled-task.md` (T20.4) -- the full per-task pool loop and the
  `next_action` branch table; this doc only swaps the harness/model on `run`.
- `docs/adr/0026-kazi-under-apply-pool.md` -- L2 (objective done + convergence
  loop, "optionally tier the inner loop to a cheap/local harness").
- `docs/adr/0016-generic-harness-profiles.md`,
  `docs/adr/0022-harness-onboarding-conformance.md` -- the harness profiles and
  the conformance tiers (opencode / codex first-class; claw best-effort / no-JSON).
- `docs/devlog.md` (2026-06-22 T8.11, 2026-06-24 arm C) -- the honest
  local-model-speed findings cited above.
- `lib/kazi/cli.ex` -- `run --harness <id> --model <m> --json [--stream]` (the
  real flags); `lib/kazi/harness/registry.ex` -- the profile ids.
