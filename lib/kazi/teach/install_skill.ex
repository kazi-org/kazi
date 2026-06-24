defmodule Kazi.Teach.InstallSkill do
  @moduledoc """
  Writes the kazi Claude Code SKILL.md, opt-in (T16.2, UC-031, ADR-0024
  decision 1; restructured as a ROUTER in T26.1, ADR-0031).

  `kazi install-skill` teaches an orchestrating Claude Code agent how to drive
  kazi as a tool. The SKILL.md is a ROUTER: it recognizes four human-facing
  sub-skill verbs and routes each to the matching real `kazi` CLI command --

      plan   -> kazi plan    (author/refine the goal's acceptance predicates)
      apply  -> kazi apply   (converge the goal -- the reconcile loop)
      status -> kazi status  (read the convergence state from the read-model)
      adopt  -> kazi init     (reverse-engineer a starter goal-file from a repo)

  ADR-0031 introduced the router with a skill-verb -> CLI-verb MAP; ADR-0032 then
  renamed the CLI verbs themselves (`run` -> `apply`, `propose` -> `plan`), so the
  map is now an IDENTITY for plan/apply and a thin alias for adopt -> init. The old
  CLI verbs `run`/`propose` remain as DEPRECATED ALIASES (ADR-0032 decision 2); the
  router teaches only the primary verbs.

  The body still teaches the underlying recipe -- caller-drafts `kazi plan --json`
  -> review -> `kazi approve --json` -> `kazi apply --harness <cheap> --json
  [--stream]` -> parse the result -> branch on `next_action` -- plus the two-tier
  economics (a strong model authors the predicates, a cheap/local model runs the
  loop, kazi keeps it honest via objective termination).

  A NON-KAZI repo degrades cleanly: the router tells the agent to fall back to the
  generic `/plan` + `/apply` skills when `kazi` is not on PATH, so the global skill
  never hardcodes a kazi-only assumption (ADR-0031 consequences).

  This is CONSENT-FIRST: it writes only when the operator runs the command. A
  normal `kazi` run never touches `~/.claude`, and `brew install` only PRINTS a
  hint to run `install-skill` (the tap formula's `caveats`, a separate repo) --
  it does not auto-write. This honors the operator's own "global skills, don't
  auto-create" discipline (ADR-0024 alternatives-rejected).

  `write/1`'s target directory is INJECTABLE (`:dir`): production defaults to
  `~/.claude/skills/kazi`, but tests pass a tmp dir so they never touch the real
  `~/.claude`. The SKILL.md body references ONLY real kazi commands/flags, so the
  T16.4 coherence guard can assert it never drifts from the actual CLI surface.
  """

  # The default skill directory under the user's Claude config. The SKILL.md is
  # written at `<dir>/SKILL.md`. Tests override `:dir` with a tmp dir.
  @default_dir Path.join(["~", ".claude", "skills", "kazi"])

  # The skill's frontmatter name -- matches the directory (`skills/kazi`), the
  # Claude Code convention.
  @skill_name "kazi"

  @doc """
  Renders the kazi SKILL.md and writes it to `<dir>/SKILL.md`.

  Opts:

    * `:dir` -- the target skill directory (default `~/.claude/skills/kazi`,
      tilde-expanded). Tests pass a tmp dir so the real `~/.claude` is never
      touched.

  Returns `{:ok, path}` with the written `SKILL.md` path, or `{:error, reason}`
  if the directory could not be created or the file could not be written.
  """
  @spec write(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write(opts \\ []) do
    dir = opts |> Keyword.get(:dir, @default_dir) |> Path.expand()
    path = Path.join(dir, "SKILL.md")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, skill_md()) do
      {:ok, path}
    end
  end

  @doc """
  The default install directory (`~/.claude/skills/kazi`, tilde-expanded). Exposed
  so the CLI can report where the skill landed on a default install.
  """
  @spec default_dir() :: Path.t()
  def default_dir, do: Path.expand(@default_dir)

  @doc """
  The SKILL.md document as a string -- the ROUTER an orchestrating Claude Code
  agent learns. Exposed (not just written) so the T16.4 coherence guard can assert
  it references only real kazi commands/flags without reading the file off disk.

  The router recognizes four sub-skill verbs (`plan`/`apply`/`status`/`adopt`) and
  routes each to the matching real `kazi` CLI command; every command/flag here is a
  real kazi surface emitted by `kazi help --json` (T26.1, ADR-0031/0032).
  """
  @spec skill_md() :: String.t()
  def skill_md do
    """
    ---
    name: #{@skill_name}
    description: Drive kazi -- a reconciliation controller that converges a software goal to machine-checkable acceptance predicates -- as a tool from an orchestrating agent. A ROUTER over four verbs: plan (author the predicates), apply (converge the goal -- the reconcile loop), status (read convergence state), adopt (reverse-engineer a starter goal-file from a repo). Use when the user wants to author predicates for a goal, then have a cheap/local model grind until they objectively pass (and not declare victory early). Triggers include "converge this goal with kazi", "drive kazi", "have kazi run the loop", "plan/apply with kazi", "author acceptance predicates and reconcile", or any task where you (a strong model) set the bar and a cheaper model should reach it under objective termination.
    ---

    # Drive kazi from an orchestrating agent (router)

    kazi is a reconciliation controller: you declare a goal as machine-checkable
    acceptance predicates, and kazi drives a coding harness in a loop until those
    predicates are objectively true, the loop is stuck, or it is over budget. kazi
    is NOT a harness -- it drives one. You drive kazi by shelling out and parsing
    its `--json` output (never its prose).

    This skill is a ROUTER. The user (or you) names a sub-skill verb; you route it
    to the matching real `kazi` CLI command and drive it over `--json`:

    | sub-skill verb | routes to     | what it does                                            |
    |----------------|---------------|---------------------------------------------------------|
    | `plan`         | `kazi plan`   | author/refine the goal's acceptance predicates (authoring path). |
    | `apply`        | `kazi apply`  | converge the goal -- the reconcile loop (subsumes loop + apply + qualify for code goals; see Step 3, "coming"). |
    | `status`       | `kazi status` | read convergence/proposal state from the read-model (a pure read). |
    | `adopt`        | `kazi init`   | reverse-engineer a starter goal-file from an existing repo.        |

    The verb you TYPE, the skill, and the CLI now read the same: `plan` and `apply`
    are the primary CLI verbs (ADR-0032). `adopt` is the one human alias -- it routes
    to `kazi init`. The legacy CLI verbs `kazi run` and `kazi propose` still work as
    DEPRECATED ALIASES of `apply`/`plan`; prefer the primary verbs. The full recipe
    that `plan` and `apply` sit inside (author -> approve -> converge) is below.

    Confirm the live surface before you drive: `kazi help --json` emits the
    command/flag table and `kazi schema [<command>]` emits the versioned result
    schemas. They are generated from kazi's own command table, so they never drift.
    Prefer them over this document when in doubt.

    ### Not a kazi repo? Degrade cleanly

    The router assumes `kazi` is on PATH. If it is not (a repo that has not adopted
    kazi, or a non-engineering task), do NOT fabricate a `kazi` invocation. Fall back
    to the generic skills: use `/plan` to author the intent and `/apply` to execute
    it. Run `adopt` (`kazi init <repo-dir>`) first only when the user wants to bring
    kazi into the repo. kazi claims engineering/code goals; content, GTM, and ops work
    stays on `/plan` + `/apply`.

    ## The two-tier economics (why drive kazi at all)

    kazi sits in the MIDDLE of a three-layer stack:

    ```
      you, the orchestrator   (strong model -- plan/design, AUTHOR the predicates)
            |  drive kazi as a tool  (this recipe)
            v
          kazi                (the controller -- objective predicates + convergence loop)
            |  drives the inner harness
            v
      cheap implementer       (a cheap/local model -- opencode/codex/... -- the keystrokes)
    ```

    Spend expensive reasoning ONCE on the part that needs judgment: what "done"
    means -- the acceptance predicates. Spend cheap, local compute on the iterative
    grind of editing until those predicates pass. kazi's objective termination makes
    the split safe: the cheap implementer cannot declare victory on
    plausible-but-wrong work, because truth lives in the controller (the predicate
    vector), not in the model doing the keystrokes. You set the bar; the cheap model
    reaches for it; kazi holds the bar still. You own the per-phase model policy --
    kazi bakes in none of it; it just exposes `--harness` / `--model` per call.

    ## The loop the verbs sit inside: plan -> approve -> apply

    ### Step 1 -- author the goal-set (`plan` verb -> `kazi plan --json`)

    `plan` is the single sanctioned authoring path. It AUTHORS or REFINES a
    GOAL-SET -- the acceptance `predicates`, plus the optional `[[groups]]` that
    partition a larger goal and the `needs` edges that order the groups into
    dependency waves -- and persists it as a reviewable PROPOSAL. The proposal
    HOLDS for human approval: `plan` itself runs NOTHING and dispatches NO harness,
    so nothing touches the workspace before you approve (Step 2). It also runs a
    deterministic clarify FLOOR over the draft -- it flags a missing
    live-verification target and an unscoped goal -- so an under-specified goal is
    surfaced in the proposal, never silently accepted.

    As the orchestrator you use CALLER-DRAFTS mode (ADR-0023): you (the strong
    model) already reasoned about the goal, so YOU supply the candidate predicates
    and kazi spawns NO second/inner model to re-derive them -- it only validates
    them, applies the floor, and persists. Supply the payload inline with
    `--predicates`, or on stdin under `--json`:

    ```sh
    kazi plan --json --predicates '{
      "name": "ship a /healthz endpoint",
      "predicates": [
        {"id": "code", "provider": "test_runner", "description": "the route exists and tests pass"},
        {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
      ],
      "rationale": "a health probe for the deploy target"
    }'

    # or pipe it on stdin (under --json):
    echo "$PAYLOAD" | kazi plan --json
    ```

    The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare
    JSON array of predicate entries is also accepted and wrapped for you). A
    positional idea is OPTIONAL in caller-drafts mode -- the predicates carry the
    intent.

    WHERE the predicates come from: if a `/plan` strategy doc already exists for
    this work, DERIVE the predicates from it rather than inventing them. Each task
    in a `/plan` WBS carries an `acc:` line -- its machine-checkable acceptance
    criterion -- and those `acc:` lines ARE the predicate set: read them off the
    strategy doc, map each to a `{"id", "provider", "description"}` predicate, and
    draft those (the `/plan` -> goal-set bridge). When NO strategy doc exists, draft
    the predicates from the idea directly. Either way it stays caller-drafts: you
    supply the result and kazi spawns no model.

    For a human or a thin non-model script that has only a prose idea, kazi-drafts
    mode spawns a harness to draft the predicates instead:

    ```sh
    kazi plan "a /healthz endpoint that returns 200" --json --yes
    ```

    Under `--json` kazi is NON-INTERACTIVE: it never prompts or blocks on stdin. If
    the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
    rather than hanging -- pass `--yes` to draft best-effort, supply predicates
    (caller-drafts), or sharpen the idea.

    `plan --json` emits a single JSON object: `goal_id`, `proposal_ref` (the
    approve/reject handle), `status`, `predicates`, `rationale`, and a `clarify`
    array (the floor's open gaps, each `{id, prompt, recommended}`). All carry
    `schema_version`. Useful plan flags: `--workspace <path>`, `--strict` (refuse
    an underspecified idea non-interactively), `--adr` (also write an ADR-lite doc).

    ### Step 2 -- review and approve (`kazi approve --json`)

    Read the proposed `predicates` and the `clarify` gaps. If a gap matters (e.g.
    no live-verification predicate), re-run `kazi plan` with it closed. When
    satisfied, approve the `proposal_ref` from Step 1:

    ```sh
    kazi approve <proposal-ref> --json
    ```

    `approve --json` emits `{schema_version, proposal_ref, status: "approved",
    goal_id}`; the goal is now runnable. (`kazi reject <proposal-ref> --json`
    declines a proposal, kept for audit.) Browse the queue with
    `kazi list-proposed --json` (optionally `--status proposed|approved|rejected`).

    ### Step 3 -- converge (`apply` verb -> `kazi apply --harness <cheap> --json [--stream]`)

    Apply the approved goal with the CHEAP harness (the two-tier split). This is the
    `apply` verb -- the reconcile loop. `kazi apply` drives the goal to a TERMINAL
    VERDICT on the current release and takes a GOAL-FILE path:

    ```sh
    kazi apply <goal-file> --workspace <path> --harness opencode --model dgx/qwen3.6 --json
    ```

    `apply --json` emits ONE terminal result object on termination. The exit code
    mirrors convergence: `0` only on `converged`, non-zero otherwise. For a LONG
    convergence add `--stream` for a JSONL progress stream -- one
    `{"event": "iteration", ...}` line per loop iteration, terminated by the final
    run-result object (the one line with NO `event` field). Read lines until you see
    the object without an `event`; that is the terminal result you branch on:

    ```sh
    kazi apply <goal-file> --workspace <path> --harness opencode --json --stream
    ```

    **Parallel + standing (the native scheduler, ADR-0027).** For a goal-set that
    partitions by blast radius, add `--parallel` (optionally `--parallel N` for a
    concurrency hint): kazi drives the NATIVE SCHEDULER -- one supervised reconciler
    per partition, in `needs`-ordered waves -- to a COLLECTIVE verdict, which
    `--json` emits as one collective result object you branch on the same way (its
    `next_action` hint). A single-partition goal-set degrades to the serial loop.
    Add `--standing` to run as a CONTINUOUS reconciler that holds the predicates true
    and re-converges on drift, instead of converging once and stopping:

    ```sh
    kazi apply <goal-file> --workspace <path> --parallel --harness opencode --json
    kazi apply <goal-file> --workspace <path> --standing --harness opencode --json
    ```

    **The `--explain` read-only gate.** `kazi apply --explain` (alias `--dry-run`)
    PRINTS the computed wave schedule -- the topological `needs`-DAG frontiers and
    the blast-radius parallelism within each -- and EXITS 0 WITHOUT DISPATCHING
    anything: no harness, no lease, no worktree is touched. Under `--json` the
    schedule is emitted as JSON. Use it as the read-only pre-flight to see what a run
    WOULD do (and to catch over-constraint -- too many `needs` edges serializing
    everything) before committing to a real converge.

    **What `apply` subsumes for CODE goals (coming).** The intent (ADR-0031
    decision 1) is that for code goals `kazi apply` (with `--parallel`) REPLACES the
    manual outer loop the operator hand-assembles -- the /loop + /apply --pool
    parallel pool -- AND the separate /qualify pass: the native scheduler is the
    parallel wave executor, and "launch-ready" is not a heuristic to infer -- the
    OBJECTIVE predicate vector (including a live prod probe) IS the launch gate, so
    qualification is a facet of `apply`, not a separate verb. That subsumption claim
    is GATED ON PROOF (ADR-0031 decision 6): it is asserted only once the E21/E23
    live dogfoods (T21.12, T23.9) pass. Until then it is COMING -- the /apply --pool
    plus /claim outer loop stays the documented interop fallback (ADR-0026), and
    `kazi apply --parallel` is offered as the native path, not yet the proven
    replacement.

    ### Step 4 -- parse the result and branch on `next_action`

    `apply --json` gives you both the terminal `status` and a single derived
    `next_action` hint, so you never re-derive the branch from the predicate vector:

    | `status`      | `next_action`  | exit | What you do |
    |---------------|----------------|------|-------------|
    | `converged`   | `done`         | 0    | Finished. Ship / report. |
    | `stuck`       | `investigate`  | != 0 | Inspect the predicate vector; the same set failed N times. |
    | `over_budget` | `raise_budget` | != 0 | Raise the budget and re-run, or escalate. |
    | `error`       | `investigate`  | != 0 | Pre-loop failure (vacuous goal, unknown harness); read `error`, fix. |

    `next_action` is an orchestration HINT, not a kazi action -- you own the policy.

    ### The `status` verb -- poll between steps (`kazi status <ref> --json`)

    `kazi status <ref> --json` is a PURE read of the read-model (nothing runs or
    mutates). The `<ref>` resolves as a run's goal id first (`kind: "run"`, with the
    latest iteration's predicate vector), else a `proposal_ref` (`kind: "proposal"`,
    the lifecycle state). An unknown ref is a JSON error with a non-zero exit.

    ### The `adopt` verb -- bring kazi into a repo (`kazi init <repo-dir>`)

    `adopt` reverse-engineers a STARTER goal-file from an existing repo by stack
    detection, so a repo that has not declared predicates gets a runnable first draft.
    Route it to `kazi init`:

    ```sh
    kazi init <repo-dir> --out goal.toml
    ```

    Then review the drafted goal-file, refine it via the `plan` verb, approve, and
    `apply`. Use `adopt` once per repo to bootstrap; it is the on-ramp, not a step in
    the per-goal loop.

    ## Pin `schema_version`

    Every `--json` object carries a `schema_version` (currently **2**, bumped by
    ADR-0032 when the verbs unified). Read it off the first object you parse and
    refuse (or branch) if it is not the version you were written against:

    ```sh
    result=$(kazi apply "$GOAL" --workspace "$WS" --harness opencode --json)
    ver=$(printf '%s' "$result" | jq -r .schema_version)
    [ "$ver" = "2" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
    next=$(printf '%s' "$result" | jq -r .next_action)
    ```

    A predicate is `pass` only when it genuinely held against the real world,
    including LIVE predicates, which pass only post-deploy. The vector -- not a
    single exit code -- is what makes regression and partial progress legible.

    ## Runtime introspection (no stale docs)

    kazi self-describes, so confirm the surface at runtime rather than trusting a
    copy of this recipe:

    ```sh
    kazi help --json   | jq '.schema_version, (.commands[].name)'
    kazi schema apply  | jq '.schema_version, .fields[].name'
    ```

    `kazi help --json` lists every command with its `summary`, positional `args`,
    and `flags` (each `{name, type, description, aliases}`). `kazi schema [<command>]`
    emits the versioned result schema(s) as data. Both are generated from kazi's own
    command table, so they can never drift from what the parser accepts.
    """
  end
end
