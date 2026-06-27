# Dogfood "done" — methodology (how every number was produced)

This doc backs the **Proof** gallery at <https://kazi.sire.run/proof> (and its
README pointer). It states, for each case, the exact goal, command, kazi version,
and the captured result — so a reader can re-run it and get the same outcome. The
rule for this page is **no unverifiable claims**: every iteration count, cost, and
wall-clock figure is copied from a real `kazi apply --json` envelope recorded in
[`docs/devlog.md`](devlog.md), not invented. Where a goal-file was transcribed for
a one-off live run rather than committed, the exact predicate is reproduced below
so you can recreate it (or regenerate it with `kazi plan`, which is how it was
originally drafted).

## How to read a kazi result

Every `kazi apply --json` run ends with a terminal envelope. The load-bearing
fields these cases cite:

- `status` — `converged` (every acceptance predicate is objectively true),
  `stuck`, or `over_budget`.
- `predicates[].verdict` — `pass` / `fail` per predicate. A case counts as
  converged only when this is `pass` for every acceptance predicate.
- `iterations` — observe→act→re-observe cycles spent.
- `economy.cost_usd`, `economy.tokens` — the metered spend for the run.
- `wall_clock_s` — wall-clock duration.

A converged run also exits `0`, so it composes in CI and scripts.

## Environment common to the live cases

- **Binary**: the released macOS aarch64 binary (`kazi version` reported below per
  case), checksum-verified against `kazi_macos_aarch64.sha256`. No source build,
  no stubs.
- **Inner harness**: the real `claude` harness (Claude Code 2.1.193).
- **Workspace**: a throwaway `git init` directory, **not** the kazi repo, so each
  run is self-contained. Every acceptance predicate **fails at t0** (the target
  files do not exist yet), so convergence is real work, not a vacuous pass.

---

## Case 1 — Exact-content file (`VERSION.txt`)

**Why a prose pipeline gets this subtly wrong.** "Create `VERSION.txt` containing
`1.0.0`" looks trivially done the moment a file exists — but the byte content has
to be exact. A naive run is happy with a stray trailing line, `v1.0.0`, or
`1.0.0\n\n`. kazi's acceptance predicate compares the content exactly, so "the
file exists" is never mistaken for "done".

- **kazi version**: 1.64.2
- **Goal predicate** (`custom_script`, drafted by `kazi plan`, transcribed to a
  goal-file for the apply leg):
  - `cmd = "sh"`
  - `args = ["-c", "test -f VERSION.txt && [ \"$(cat VERSION.txt)\" = \"1.0.0\" ]"]`
- **Reproduce**:
  ```sh
  # Draft the predicate (frontier model in your session authors it):
  kazi plan "Create a file named VERSION.txt in the workspace whose contents are \
    exactly the text: 1.0.0" --workspace <ws> --yes --json
  # Transcribe the drafted cmd/args into version.goal.toml, then drive it:
  kazi apply version.goal.toml --workspace <ws> --harness claude --json
  ```
- **Captured result**: `status: converged`, predicate `pass` in **2 iterations /
  18.5 s**, `economy.cost_usd: 0.116`, `economy.tokens: 39712`. Independent
  re-check: `VERSION.txt` is the bytes `1.0.0\n` and
  `[ "$(cat VERSION.txt)" = "1.0.0" ]` exits 0 (`$( )` strips the single trailing
  newline, so exact-content holds).
- **Source**: `docs/devlog.md`, entry *2026-06-26 — T26.6* (the router end-to-end
  run: `plan → approve → status → apply`).

---

## Case 2 — Self-correcting against an opaque oracle (`solution.py`)

**Why a prose pipeline gets this subtly wrong.** The agent's first attempt at a
multi-step number-theory problem looks plausible but is *wrong*. With no objective
check, that wrong answer ships. kazi grades the output against a one-way **sha256**
oracle — the model can't read the answer out of the checker, it has to compute it
— so a wrong first attempt is caught and re-driven instead of accepted.

- **kazi version**: 1.64.1
- **Goal**: write `solution.py` that prints the sum of every `n` with
  `1 ≤ n < 1_000_000` that is a palindrome simultaneously in base 10, base 2, and
  base 8 (no leading zeros). The acceptance predicate compares the **sha256** of
  the printed integer to a stored digest (answer: `610`; the digest, not the
  number, lives in the goal-file, so the oracle leaks nothing).
- **Reproduce**:
  ```sh
  kazi apply ./goal.toml --workspace ./ws --harness claude \
    --model claude-haiku-4-5 --json
  ```
  (The inner agent needs file-edit permission; the run granted it via a one-line
  `[harness] command` wrapper script — see the "harness permission" landmine in
  the devlog entry. Each rung must allow at least **2** iterations: a
  `max_iterations = 1` budget can never converge — kazi needs a final
  re-observation after the last action.)
- **Captured result**: `status: converged`, predicate `pass`, **2 iterations /
  39.3 s**, `economy.cost_usd: 0.0768584`. The iteration trace is
  `iter=1 failing=[…] → iter=2 failing=[]`: the cheap model (Haiku 4.5) got the
  first dispatch wrong, the oracle caught it, and it self-corrected on the second.
  The written `solution.py` was independently verified to print `610` (oracle
  exit 0).
- **Source**: `docs/devlog.md`, entry *2026-06-26 — T30.4* (Run A).

---

## Case 3 — A real cross-group dependency, parallelized correctly

**Why a prose pipeline gets this subtly wrong.** Split three capabilities across
parallel agents naively and the streaming endpoint compiles against a `Widget`
type that doesn't exist yet — a broken build that "looks done" per-agent. kazi
computes the wave schedule from authored `needs` edges: it runs the two disjoint
groups concurrently but holds the dependent group until its dependency objectively
converges, then merges all three.

- **kazi version**: 1.64.2
- **Goal-file (committed, reproducible verbatim)**:
  [`priv/examples/predicate_graph_waves.toml`](../priv/examples/predicate_graph_waves.toml)
  — three groups: `result-contract` (defines `type Widget struct`), `health`
  (`/healthz`, independent), and `streaming` (`/widgets/stream`, which consumes the
  `Widget` type and declares `needs = ["result-contract"]`). Every predicate is a
  `custom_script` graded by `go test` / `grep`, `verdict = "exit_zero"`.
- **Reproduce** (against a scratch Go workspace — `git init`, `go mod init`, one
  `main.go`):
  ```sh
  # See the computed wave schedule first (pure planning, no dispatch):
  kazi apply priv/examples/predicate_graph_waves.toml --workspace <scratch> --explain --json
  # Then run it:
  kazi apply priv/examples/predicate_graph_waves.toml --workspace <scratch> \
    --parallel --harness claude --json
  ```
- **Captured result**: `{"collective":"converged","blocked":[],"next_action":"done"}`,
  exit 0. Group-iteration timeline from the loop log:
  - `result-contract` and `health` dispatch in the **same millisecond** —
    ≥2 disjoint blast-radius partitions converging concurrently under one
    `kazi apply --parallel`, single-node, NATS-free.
  - `streaming` dispatches **0.222 s after `result-contract` converged** and
    *before* `health` converged — it waited specifically for its `needs` dep, not
    a global wave barrier. All three groups reached `iter=2 failing=[]`.
  - All three Go files (`widget.go`, `health.go`, `stream.go`) merged back into the
    single workspace; the per-partition worktrees were torn down.
- **Source**: `docs/devlog.md`, entry *2026-06-26 — T21.12 + T23.9 RE-VERIFIED on
  the FIXED released binary v1.64.2*.

> Note: `kazi apply --parallel` requires the fix bundled in **v1.64.2+**; on
> earlier released binaries the `--parallel` path could not execute end-to-end
> (the honest negative is the *2026-06-26 — T21.12* devlog entry). Use a serial
> `kazi apply` on older binaries.

---

## The discipline exhibit — kazi refusing a false "done" (the founding dogfood)

This is the inverse of the cases above, and it's why their `converged` verdicts
mean something: a deterministic acceptance test where a naive fix makes one
predicate pass while **regressing another**, and kazi catches the green→red
regression instead of declaring success.

- Two coupled `custom_script` predicates over a real temp workspace: `pred_a`
  passes iff `a.txt` contains `ok` (starts red); `pred_b` passes iff `b.txt`
  contains `ok` (starts green). The "naive fix" harness fixes `a.txt` but, because
  the two are coupled, writes `broken` into `b.txt` as a side effect. Fixing A
  regresses B.
- kazi **detects** the regression (`pred_b` green→red), attributes it to the
  dispatch that made the coupled edit, and settles on the failing set `{pred_b}` —
  it never declares done. A single exit code would have hidden this (ADR-0002 is
  the decision that makes it detectable).
- **Reproduce** (deterministic, no model, no network):
  ```sh
  mix test test/kazi/slice1_dogfood_test.exs
  ```
- **Source**: `test/kazi/slice1_dogfood_test.exs` (the Slice-1 acceptance dogfood,
  plan task T1.8). This is a unit/acceptance test, labelled as such — not a live
  `kazi apply` run.

---

## Keeping the gallery honest as it grows

Each new converged dogfood = a new entry. To add one:

1. Run it on a **released** binary with `kazi apply --json` and capture the
   terminal envelope (`status`, `predicates[]`, `iterations`,
   `economy.cost_usd`/`tokens`, `wall_clock_s`).
2. Record the run in `docs/devlog.md` with the goal, command, and version.
3. Append a case object to the `cases` array in `site/src/pages/proof.astro`,
   citing the devlog entry as its source.
4. Add the matching method block here.

If a number can't be traced to a real captured run, it does not go on the page.
