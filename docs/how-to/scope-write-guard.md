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

## `[scope].forbidden_paths` — a HARDER `deny`, with landing-time refusal (ADR-0085)

```toml
[scope]
forbidden_paths = ["docs/plan.md", "docs/roadmap.md"]
```

`deny` above is soft: a violation fails a guard predicate, and that is the
whole guarantee — nothing stops the change from landing anyway if the loop's
convergence check is ever bypassed. `forbidden_paths` closes that gap
(kazi-org/kazi#1695: a converging grind loop committed a change to
`docs/plan.md`/`docs/roadmap.md` despite a prose exclusion list its dispatch
brief carried — prose is not a channel the grind model reads). It is enforced
TWICE:

  1. the SAME `:scope_forbidden_paths` guard predicate `deny` gets
     (`Kazi.Providers.ScopeGuard`, same diff-based detection);
  2. `Kazi.Actions.Integrate` structurally refuses to LAND a touched path:
     * **legacy commit path** (no `[integration]` block) — the touched path is
       excluded from what gets staged/committed (`git reset`-unstaged after
       staging, left modified-but-uncommitted in the working tree — never
       silently discarded);
     * **`[integration]` verify-then-ship path** (mode `commit`/`branch`/
       `pr`/`merge`) — the inner agent already committed its own work, so a
       touched path there cannot be surgically excluded without rewriting
       history; the WHOLE landing is refused instead, before any push.

An entry is an exact path, a directory prefix, or a directory prefix suffixed
`/**`/`/*` (`Kazi.ScopeDiff.under_any?/2`) — this is directory-prefix
matching, not a general glob engine (no mid-path `*`/`?` wildcards).

## `[scope].no_integration` — refuse to land at all (ADR-0085)

```toml
[scope]
no_integration = true
```

Closes kazi-org/kazi#1704: an orchestrating session told its dispatched
sub-agent not to open a PR in prose the sub-agent never saw, and the agent
opened one anyway. `no_integration = true` makes "never land" a DECLARED
goal-file contract instead: it forces this goal's `[integration]` block to the
existing `mode: :none` default regardless of what `[integration]` declares
(`Kazi.Goal.new/2`), and `Kazi.Actions.Integrate` refuses to run AT ALL for
this goal — no commit, no push, no PR, no merge, checked directly off
`scope.no_integration` so the refusal holds even for a goal struct assembled
without going through `Goal.new/2`.

## `[scope].forbidden_commands` — a best-effort tripwire, NOT a sandbox (ADR-0085)

```toml
[scope]
forbidden_commands = ["gh pr create", "gh pr merge"]
```

`Kazi.Providers.ForbiddenCommands` best-effort scans the run's dispatch
transcript for a declared pattern and fails a `:scope_forbidden_commands`
guard predicate on a hit. **This cannot stop a determined or confused model
from running the command** — a dispatched harness run under
`--permission-mode bypassPermissions` has real shell access this does not
attempt to revoke. It only makes an attempt VISIBLE, the same way any other
failing predicate is. Use `forbidden_paths`/`no_integration` above for a
guarantee that actually holds structurally; use `forbidden_commands` only as
an early-warning signal on top of them.
