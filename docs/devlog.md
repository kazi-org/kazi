# kazi devlog

Session findings, dogfood results, and benchmarks. Append-only; newest entries
at the top. For invariants/landmines see `docs/lore.md`; for decisions see
`docs/adr/`.

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
