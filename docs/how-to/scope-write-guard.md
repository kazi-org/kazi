# Scope write guard: `write_paths`, `deny`, and the collateral report (issue #860)

## The problem

`[scope].paths` is a coarse allow-list: it names the areas an agent may
*read*, but it cannot express "the agent may read anything under `ios/` but
should only *write* these areas," and it gives no signal when a change lands
somewhere no predicate ever asked about. The motivating incident: a goal
scoped to a whole platform directory converged cleanly while an inner agent
deleted an unrelated auth-config key as a side effect of an otherwise in-scope
commit — every predicate passed, and the regression was silent until a human
eyeballed the commit stats.

Three fields/features close that gap. All are additive: a goal-file
declaring none of them behaves byte-identically to before this feature.

## `[scope].write_paths` — the editable subset of `paths`

```toml
[scope]
paths       = ["ios/"]          # readable
write_paths = ["ios/Watch/"]    # editable — narrower than paths
```

`write_paths` doesn't change what the agent can physically touch (kazi does
not sandbox the filesystem in Slice 0) — it declares the INTENDED write scope
that `Kazi.CollateralReport` measures changes against (see below). Absent or
empty, no narrower write scope is declared and today's `paths`-only behavior
is unchanged.

## `[scope].deny` — paths that must never move

```toml
[scope]
deny = ["ios/Runner/Info.plist", ".github/workflows/"]
```

A `deny` path is a HARD contract: entitlements, auth config, CI workflow
files — anything this goal has no business touching, ever. Declaring `deny`
automatically synthesizes a `:scope_guard` GUARD predicate
(`Kazi.Scope.guard_predicates/1`), independent of the `[enforcement]` profile
(ADR-0042) — a deny-path guard is a scope contract, not an anti-gaming one, so
it applies to `mode = "repair"` goals too, with no `[enforcement]` table
needed.

The guard (`Kazi.Providers.ScopeGuard`) measures the diff between the run's
base ref (the merge-base with `origin/main`, falling back to the repo's root
commit) and the current working tree (`Kazi.ScopeDiff`, one `git diff` call
covers both committed-on-branch and uncommitted changes). Any changed path
under a `deny` prefix FAILS the guard, naming the offending path(s) in its
evidence. Because it is an ordinary guard predicate, the violation flows
through the SAME failing-evidence path every predicate already uses — it
shows up in the observed vector, blocks `:converged`, and is fed back to the
inner agent as failing evidence on the next dispatch. No bespoke prompt wiring
was needed for this: it is "at least soft" enforcement by construction.

## `collateral` — the terminal out-of-intent diff report

`kazi apply --json`'s terminal result carries an additive `collateral` field
(`docs/schemas/run-result.md`): every file changed this run that sits OUTSIDE
the intended write scope, net-deletion entries ranked first (the exact shape
of the motivating incident — a pure deletion in a file nothing referenced).

```json
"collateral": [
  { "path": "ios/Runner/Info.plist", "additions": 0, "deletions": 10, "net_deletion": true }
]
```

A path counts as out-of-scope when `write_paths` is declared and the path
isn't under it, or — absent `write_paths` — when no predicate's own config
plausibly references the path. `collateral` is advisory/observability only
(it never blocks convergence by itself); pair it with `deny` for a hard
guarantee on the specific paths that must never move.

See `Kazi.CollateralReport` and `Kazi.ScopeDiff` for the implementation; both
the guard and the report measure the same diff, so they can never disagree
about "what changed this run".
