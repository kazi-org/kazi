# kazi devlog

Session findings, dogfood results, and benchmarks. Append-only; newest entries
at the top. For invariants/landmines see `docs/lore.md`; for decisions see
`docs/adr/`.

## 2026-06-21 — Slice-2 creation dogfood (T2.5): kazi BUILDS a small real feature from failing acceptance criteria to green-and-live

**What was exercised.** The Slice-2 creation acceptance dogfood (UC-010, D2) —
the creation analog of the Slice-0 full-loop dogfood (T0.11/T0.12) and the
Slice-1 regression dogfood (T1.8). Where Slice 1 proves kazi catches a BAD fix,
this proves kazi makes a GOOD one: it does not just REPAIR regressed behavior, it
CREATES behavior that did not exist before. Driven end-to-end through the REAL
`Kazi.Runtime`/`Kazi.Loop` with the REAL providers (`Kazi.Providers.TestRunner`
over a real temp workspace; `Kazi.Providers.HttpProbe` over a REAL local server),
the REAL `Kazi.Harness.ClaudeAdapter` (pointed at a real local "build" binary via
its `:command` seam), the REAL `Kazi.Actions.Integrate` (a real local
rebase-merge into a bare `origin`, no GitHub) and `Kazi.Actions.Deploy` (a stub
emulating `gcloud run deploy`, no gcloud), and real SQLite read-model
persistence. Test: `test/kazi/slice2_dogfood_test.exs`. Hermetic: own Sandbox
connection, a real harness binary, a real temp git repo, a real local HTTP
server — no Go, no external network, no GitHub, no GCP, no real browser.

**The feature spec (as failing acceptance predicates).** A tiny real feature —
*GET /greeting returns 200 with a body containing `hello, kazi`* — authored as a
create-mode goal (`mode: :create`) whose three acceptance criteria are all
designed to FAIL at t0:

- `feature_built` (`tests`, acceptance): the feature source exists
  (`grep -q '^built$' greeting.feature`). RED at t0 (marker `absent`). This CODE
  criterion is what carries the loop past dispatch into integrate/deploy.
- `greeting_endpoint` (`http_probe`, acceptance): `GET /greeting` returns 200. A
  REAL request against a running stdlib `:inets`/`:httpd` server. RED at t0 — the
  route does not exist yet, so the server genuinely **404s** (the
  `create_feature.toml` "no such route yet" shape).
- `greeting_body` (`http_probe`, acceptance): `GET /greeting` body contains
  `hello, kazi`. The precise behavior kazi must CREATE. RED at t0 (no endpoint).

The "live" check is a REAL http_probe request against an actually-running local
server whose response the deploy step rewrites — "live" here means a genuinely
running service the probe hits over `127.0.0.1`, NOT Cloud Run. A pre-flight
assertion confirms all three criteria genuinely fail against the real world at t0
(so the vacuous-goal guard, T2.3, does not trip — there is real work to do).

**How the build happens (over the real seams, zero-stub in lib/).** The harness
binary is the coding agent: it performs the genuine build by writing the feature
source marker (`built`) into the workspace, flipping `feature_built` red → green.
The integrate action's `:integrator` seam really rebase-merges the built feature
onto origin's `main`. The deploy action's `:deploy_cmd` seam "ships" the feature
by creating the server's backing resource serving the greeting, so the route
comes into being live — the live http_probe criteria pass only against the
deployed feature.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=converged  iterations=4
actions=[:dispatch_agent, :integrate, :deploy]
  iter 0: feature_built=fail greeting_endpoint=fail greeting_body=fail  converged=false  # honest start: feature absent, route 404s
  iter 1: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # agent BUILT the source; route still absent
  iter 2: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # landed; still not deployed -> live still 404
  iter 3: feature_built=pass greeting_endpoint=pass greeting_body=pass  converged=true   # deployed -> route live -> whole acceptance vector holds
```

1. **Failed at t0, non-vacuously.** Every acceptance criterion was RED before
   kazi did anything (feature absent, endpoint 404). The goal was real work, not
   a vacuous "already done" — the t0 guard let it through and the first persisted
   observation is all-fail.
2. **Built the feature.** The agent dispatch made `feature_built` go green
   (`greeting.feature` = `built` in the real workspace); integrate landed it on
   origin's `main` (`git ls-tree main` shows `greeting.feature`); deploy created
   the live route serving the greeting. The full creation arc:
   dispatch (BUILD) → integrate (LAND) → deploy (SHIP).
3. **Did NOT converge before the feature existed.** The objective-termination
   guard (T0.8) held for CREATION exactly as for repair: there are observed
   states (iters 1–2) where the built CODE acceptance passed but the LIVE
   greeting had not yet flipped — and the loop did NOT converge in any of them.
   Convergence was gated on the live feature, not on code-green.
4. **Converged green-and-live, persisted in order.** Only the LAST iteration is
   marked converged; the terminal vector is objectively satisfied; a final REAL
   `:httpc` request confirms the running endpoint serves `hello, kazi`.

**Evidence.** `result.outcome == :converged`,
`result.actions == [:dispatch_agent, :integrate, :deploy]`; the workspace file
`greeting.feature` = `built`; `greeting.feature` present on origin's `main`; a
direct `:httpc` GET against the live server returning the greeting; the persisted
read-model history (4 iterations) showing the all-fail t0 start, the
code-green-but-live-red gate, and exactly one converged iteration at the end.

**Conclusion: D2 acceptance holds (hermetically).** kazi builds one small real
feature from failing acceptance predicates to green-and-live: the criteria fail
at t0, kazi dispatches a build, lands it, ships it, and converges only once the
live endpoint genuinely serves the new behavior — never declaring the feature
done before it is live.

**Honesty note — the Cloud-Run caveat.** This dogfood proves the creation arc
*hermetically*: the "live" surface is a real local `:inets` server, and the
deploy step is a stub emulating `gcloud run deploy`. Production-Cloud-Run-live
(an http_probe passing against a real Cloud Run URL after a real `gcloud`
deploy) remains **T0.12**, which is human/GCP-gated and out of scope here by
design (the task forbids Go/GCP/external network so CI stays self-contained).
So D2's "to live" is met in the local-running-service sense, not yet against
production Cloud Run; that final step is tracked by T0.12. Everything behaved as
designed on the first real run; no `lib/` change was needed.

## 2026-06-21 — Slice-1 dogfood (T1.8): naive fix regresses a coupled predicate; kazi detects + escalates

**What was exercised.** The Slice-1 acceptance dogfood (UC-007), the
trustworthiness analog of the Slice-0 full-loop dogfood (T0.11/T0.12). Driven
end-to-end through the REAL `Kazi.Loop` with the REAL `Kazi.Providers.TestRunner`
(shelling out to `grep` over a real temp workspace), the REAL
`Kazi.Harness.ClaudeAdapter` (pointed at a real local "naive fix" binary via its
`:command` seam), real SQLite read-model persistence, and Noop integrate/deploy
doubles. Hermetic: own Sandbox connection, a real harness binary, a real temp
workspace — no Go, no network, no GitHub, no cloud. Test:
`test/kazi/slice1_dogfood_test.exs`.

**The scenario (a genuine coupling, not a contrived flag).** Two CODE predicates
over the temp workspace:

- `pred_a` passes iff `a.txt` contains `ok`; starts RED (`a.txt` = `broken`).
- `pred_b` passes iff `b.txt` contains `ok`; starts GREEN (`b.txt` = `ok`).

The "naive fix" harness is a real executable run with `cd: workspace`. It fixes
`pred_a` (writes `ok` into `a.txt`) but, because the predicates are coupled,
BREAKS `pred_b` as a side effect (writes `broken` into `b.txt`). This is the
canonical "a fix for predicate A breaks predicate B" (concept §5, the case
ADR-0002 rejects a single exit code for) — observed through the real provider
over a real mutated workspace, not faked with a status script. The harness is
idempotent (same edit each dispatch), so once B is red it stays red.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=stopped  reason=:stuck  iterations=4
actions=[:dispatch_agent, :dispatch_agent, :dispatch_agent]
  iter 0: pred_a=fail pred_b=pass      # honest start: A is real work, B green
  iter 1: pred_a=pass pred_b=fail      # naive fix flipped A green AND B red
  iter 2: pred_a=pass pred_b=fail      # failing set settles on {pred_b}
  iter 3: pred_a=pass pred_b=fail      # 3rd identical observation -> stuck
REGRESSION pred_b green@0 -> red@1 status=fail attributed=[:pred_a]
stuck_failing=[:pred_b]
```

1. **Detected the regression.** The regression detector flagged `pred_b`
   green→red between observation 0 and 1, and ATTRIBUTED it to the
   `:dispatch_agent` whose failing work-list was `[:pred_a]` — i.e. the very fix
   sent to repair A is named as the cause of B breaking. Visible in `snapshot/1`
   and read back from the persisted read-model (`ReadModel.regressions/1`,
   string-keyed on-disk form).
2. **Did NOT falsely converge.** The objective-termination guard (T0.8) held:
   the whole vector was never all-pass, because the instant the naive fix made A
   pass it made B fail. `:converged` was never reached; no persisted iteration is
   marked converged. The workspace confirms the coupling really happened
   (`a.txt` = `ok`, `b.txt` = `broken`).
3. **Escalated rather than spinning forever.** The same non-empty failing set
   `{pred_b}` persisted across the stuck window (3), the human-escalation hook
   fired exactly once with `failing == {:pred_b}`, and the loop stopped
   `:stopped` / reason `:stuck`. The iteration-budget backstop (50) was never
   reached — escalation, not budget exhaustion, ended the run. Terminal outcome,
   reason, the regression flag, and `stuck_failing` are all visible in both
   `snapshot/1` and the persisted read-model.

**Evidence.** `snapshot/1` carried the regression flag, `stuck_failing =
[:pred_b]`, and terminal state `:stopped`. The read-model carried the same
regression (queryable via `ReadModel.regressions/1`), an in-order iteration
history with NO converged iteration, and an iteration showing `pred_a :pass`
while `pred_b :fail` — the coupled regression made durable.

**Conclusion: D1 acceptance holds.** kazi catches the naive fix that trades one
green predicate for another rather than declaring false success: it detects the
regression, attributes it to the causing dispatch, refuses to converge while the
regressed predicate is red, and escalates to a human via the stuck detector. The
Slice-1 trustworthy-loop acceptance is met.

**Honesty note.** Everything behaved as designed on the first real run; nothing
needed a lib/ fix. One thing worth recording: the regression is flagged once (at
the green→red edge, iter 1) and is NOT re-flagged on subsequent identical
observations — `pred_b` stays red (red→red is not a new green→red edge), so the
single persistent flag is correct, not a missed re-detection. The loop continues
to surface that flag every iteration via `snapshot/1`/the read-model until it
escalates.

## 2026-06-22 — E4 context-injection epic shipped; pool drained

**Session:** `/loop /apply --pool`. Executed E4 (ADR-0010) end-to-end across two
waves, 8 PRs, all rebase-merged with green CI and verified on integrated main.

- **Wave 13:** T4.1 (adapter `--output-format json`: real token/cost/touched →
  budget, PR #41), T4.2 (`Kazi.Context` orientation-pack builder, deterministic +
  hermetic, PR #43), T4.5 (`Kazi.Workspace` code-review-graph MCP wiring + graph
  freshness before dispatch, PR #42).
- **Wave 14:** T4.3 (stable cacheable orientation prefix in `build_prompt`, PR #44),
  T4.4 (target `.kazi/context.md` orientation file, PR #46), T4.6 (SHA-keyed
  orientation-pack cache in the read-model + migration `20260622060000`, PR #47),
  T4.8 (per-dispatch token/cost ceiling + `truncate_evidence/2` + least-privilege
  tool/permission set, PR #45), then T4.7 (`Kazi.Loop.Digest`: bounded working-set
  digest across iterations — map memory only, never the transcript, preserving
  ADR-0008 anti-anchoring, PR #48).
- **Tests:** 372 → 495 passing (+123) across the epic; format + warnings-as-errors
  clean at every merge. T4.9 (semantic-retrieval RAG) remains deferred per ADR-0005.

**Pool drained of ready work.** Remaining incomplete tasks are not pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Blocks
  **T0.12**, the headline Slice-0 dogfood (idea→live production probe), which is the
  project's success bar. This human task is the critical-path blocker.
- **T3.1 / T3.5 / T3.7** — unblocked by deps (T2.6 done) but coarse Slice-3
  placeholders (NATS leases, predicate-authoring front-end, Telegram) with
  `Est: TBD` and no acceptance criteria; need `/plan` granularization into hermetic
  subtasks before agents can execute against a checkable bar. T3.2/T3.6 sit behind
  T3.1.

**Next:** either (a) complete T0.6h (human GCP setup) to unblock the T0.12 dogfood,
or (b) `/plan` the Slice-3 epic (T3.1/T3.5/T3.7) into granular tasks for a new pool wave.
