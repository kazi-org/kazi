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
  CLI verbs `run`/`propose` were REMOVED in v0.6.0 (T27.9); `apply`/`plan` are the
  only verbs, and the router teaches them.

  The body still teaches the underlying recipe -- caller-drafts `kazi plan --json`
  -> review -> `kazi approve --json` -> `kazi apply --harness claude --model
  <cheap-claude-id> --json [--stream]` -> parse the result -> branch on `next_action`
  -- plus the two-tier economics (a FRONTIER model authors the predicates, a CHEAP
  Claude model runs the loop via in-family tiering, kazi keeps it honest via objective
  termination). In-family Claude tiering is the DEFAULT (ADR-0033/0035); local/BYOM
  via opencode is the secondary privacy add-on.

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
    description: Drive kazi -- a reconciliation controller that converges a software goal to machine-checkable acceptance predicates -- as a tool from an orchestrating agent. A ROUTER over four verbs: plan (author the predicates), apply (converge the goal -- the reconcile loop), status (read convergence state), adopt (reverse-engineer a starter goal-file from a repo). Use when the user wants to author predicates for a goal, then have a cheap Claude model (in-family tiering, the default; local/BYOM via opencode is the secondary privacy option) grind until they objectively pass (and not declare victory early). Triggers include "have kazi drive this until done" (the canonical invocation phrase), "converge this goal with kazi", "drive kazi", "have kazi run the loop", "plan/apply with kazi", "author acceptance predicates and reconcile", or any task where you (a strong model) set the bar and a cheaper model should reach it under objective termination.
    ---

    # Drive kazi from an orchestrating agent (router)

    kazi is a reconciliation controller: you declare a goal as machine-checkable
    acceptance predicates, and kazi drives a coding harness in a loop until those
    predicates are objectively true, the loop is stuck, or it is over budget. kazi
    is NOT a harness -- it drives one.

    ## How to drive kazi: MCP first, JSON-CLI fallback

    PREFER the MCP server. If you speak MCP (Claude Code, Codex, Cursor), wire kazi
    as an MCP server and drive its self-describing tools -- `kazi_plan`,
    `kazi_approve`, `kazi_apply`, `kazi_status`, `kazi_list_proposed` -- whose
    input/output schemas teach you the surface at ZERO prose cost. The installed
    binary serves it over stdio via the `kazi mcp` verb (ADR-0044). The canonical
    client config is the binary verb:

    ```json
    #{Kazi.MCP.ClientConfig.inline()}
    ```

    `kazi init --with-mcp` writes exactly this `.mcp.json` into a repo for you, and
    `mix kazi.mcp` is the development entry point that starts the SAME server.

    FALLBACK -- the JSON-CLI shell-out. When MCP is unavailable, drive kazi by
    shelling out and parsing its `--json` output (never its prose). The same
    plan -> approve -> apply recipe applies; the rest of this skill teaches it as
    CLI invocations, which map one-to-one onto the MCP tools above.

    ## The invocation phrase

    When the user says "have kazi drive this until done" (the canonical
    invocation phrase, the Context7 "use context7" pattern), that IS the request
    to drive kazi: author the acceptance predicates for the task with the `plan`
    verb, then converge them with the `apply` verb until they are objectively
    true. This phrase is one of the skill's triggers, so it routes here whenever
    the kazi skill is installed; treat it as "set the bar, then reconcile to it".

    This skill is a ROUTER. The user (or you) names a sub-skill verb; you route it
    to the matching real `kazi` CLI command and drive it over `--json`:

    | sub-skill verb | routes to     | what it does                                            |
    |----------------|---------------|---------------------------------------------------------|
    | `plan`         | `kazi plan`   | author/refine the goal's acceptance predicates (authoring path). |
    | `apply`        | `kazi apply`  | converge the goal -- the reconcile loop (subsumes loop + apply + qualify for code goals; see Step 3, "coming"). |
    | `status`       | `kazi status` | read convergence/proposal state from the read-model (a pure read). |
    | `adopt`        | `kazi init`   | reverse-engineer a starter goal-file from an existing repo.        |

    The verb you TYPE, the skill, and the CLI now read the same: `plan` and `apply`
    are the CLI verbs (ADR-0032). `adopt` is the one human alias -- it routes to
    `kazi init`. The legacy CLI verbs `run`/`propose` were REMOVED in v0.6.0 (T27.9):
    use `apply`/`plan`. The full recipe that `plan` and `apply` sit inside (author
    -> approve -> converge) is below.

    Confirm the live surface before you drive: `kazi help --json` emits the
    command/flag table and `kazi schema [<command>]` emits the versioned result
    schemas. They are generated from kazi's own command table, so they never drift.
    Prefer them over this document when in doubt.

    ### Where /plan and /tidy sit (the code on-ramp)

    For a CODE goal the on-ramp is exactly these four verbs -- `plan` / `apply` /
    `status` / `adopt`. Do NOT route a code goal through a separate `/loop` or
    `/qualify` pass: `kazi apply` IS the reconcile loop, and "launch-ready" is the
    OBJECTIVE predicate vector (including any live prod probe), not a heuristic to
    infer afterward (ADR-0031). Two general skills stay OUTSIDE kazi and keep their
    own roles:

    - `/plan` is the INTENT layer ABOVE kazi -- it authors the strategy (ADRs, use
      cases, the WBS) and each task's `acc:` line. Those `acc:` lines feed the
      `plan` verb: derive the predicates from them (the `/plan` -> goal-set bridge
      in Step 1). `/plan` decides WHAT to build; kazi makes it objective and runs it.
    - `/tidy` is HYGIENE, orthogonal to convergence -- git/worktree/scratch sweeping.
      It is not part of the converge loop; run it when you want repo hygiene, not to
      reach "done".

    (`/loop` and `/qualify` remain available as GENERAL skills for non-code work;
    the kazi code on-ramp simply does not route to them.)

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
      you, the orchestrator   (FRONTIER model -- plan/design, AUTHOR the predicates)
            |  drive kazi as a tool  (this recipe)
            v
          kazi                (the controller -- objective predicates + convergence loop)
            |  drives the inner harness
            v
      cheap implementer       (a CHEAP Claude model -- the keystrokes)
    ```

    Spend expensive reasoning ONCE on the part that needs judgment: what "done"
    means -- the acceptance predicates. Spend cheap compute on the iterative grind of
    editing until those predicates pass. kazi's objective termination makes the split
    safe: the cheap implementer cannot declare victory on plausible-but-wrong work,
    because truth lives in the controller (the predicate vector), not in the model
    doing the keystrokes. You set the bar; the cheap model reaches for it; kazi holds
    the bar still. You own the per-phase model policy -- kazi bakes in none of it; it
    just exposes `--harness` / `--model` per call.

    **The DEFAULT recipe is in-family Claude tiering (ADR-0033/0035).** You are a
    FRONTIER Claude model (e.g. `claude-opus-4-8`) and you already AUTHOR the
    predicates in this very session; run the grind on a CHEAP Claude model via
    `kazi apply --harness claude --model <cheap-claude-id>`. The cheap tier is
    `claude-haiku-4-5` (step up to `claude-sonnet-5` for harder slices). This needs
    only a Claude API key -- no local model, no special hardware -- so the economics
    apply to anyone running Claude Code. The cost win is still BEING MEASURED; treat
    it as the intended economics, not a measured figure.

    **Local / BYOM is the SECONDARY privacy add-on.** If your code must never leave
    your hardware, run the grind on a local model instead --
    `kazi apply --harness opencode --model <local-model>` (e.g. a local Qwen/Llama via
    opencode). Same two-tier shape, no cloud; explicitly secondary to the in-family
    default above.

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

    ### Step 3 -- converge (`apply` verb -> `kazi apply --harness claude --model <cheap-claude-id> --json [--stream]`)

    Apply the approved goal with the CHEAP tier (the two-tier split). This is the
    `apply` verb -- the reconcile loop. `kazi apply` drives the goal to a TERMINAL
    VERDICT on the current release and takes either the APPROVED `prop-...`
    proposal-ref from Step 2 (loaded straight from the read-model -- no goal-file
    reconstruction, ADR-0049) or a goal-file path. The DEFAULT is in-family
    Claude tiering: you authored on a frontier model, so grind on a cheap Claude model:

    ```sh
    kazi apply <proposal-ref> --workspace <path> --harness claude --model claude-haiku-4-5 --json
    ```

    `apply --json` emits ONE terminal result object on termination. The exit code
    mirrors convergence: `0` only on `converged`, non-zero otherwise. For a LONG
    convergence add `--stream` for a JSONL progress stream -- one
    `{"event": "iteration", ...}` line per loop iteration, terminated by the final
    run-result object (the one line with NO `event` field). Read lines until you see
    the object without an `event`; that is the terminal result you branch on:

    ```sh
    kazi apply <goal-file> --workspace <path> --harness claude --model claude-haiku-4-5 --json --stream
    ```

    SECONDARY (privacy / no-cloud): to keep the grind on local hardware, swap the
    harness/model for a local model via opencode -- same loop, no cloud:

    ```sh
    kazi apply <goal-file> --workspace <path> --harness opencode --model <local-model> --json
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
    kazi apply <goal-file> --workspace <path> --parallel --harness claude --model claude-haiku-4-5 --json
    kazi apply <goal-file> --workspace <path> --standing --harness claude --model claude-haiku-4-5 --json
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

    ### Escalate-on-stuck: the bounded model ladder (the DEFAULT adaptive recipe)

    Static cheap-tiering (above) always grinds on one cheap model. The ADAPTIVE
    refinement (ADR-0035) starts on the cheapest model and steps UP only when kazi
    reports the SAME slice is not progressing -- so you pay frontier rates only for
    the slices that actually need them. The escalation policy lives ENTIRELY here in
    the skill: kazi reports per-invocation state, YOU (the skill) own the ladder and
    the counter. kazi-core has NO model-selection logic (ADR-0035 decision 1).

    **The ladder (capped at the frontier).** Three rungs, cheapest first; it STOPS at
    the top -- it never escalates past the frontier:

    ```
    claude-haiku-4-5  ->  claude-sonnet-5  ->  claude-opus-4-8   (STOP; do not escalate past Opus)
    ```

    **The trigger (which `--json` fields).** After each `kazi apply --harness claude
    --model <rung> --json` on a slice, read the terminal result object and branch on
    these fields (the T30.3 mapping, `docs/tiering-signals.md`):

    - `goal_id` -- the SLICE id, stable across the successive invocations you make on
      one slice. KEY your rung counter by `goal_id` (this counter is the SKILL's own
      state -- never a kazi field; ADR-0035).
    - `status` -- `converged` -> slice done (reset). `stuck` or `over_budget` -> this
      rung did NOT converge -> escalate. `error` -> a misconfig (vacuous goal,
      unknown harness); read `error` and FIX the goal, do NOT escalate the model.
    - `next_action` -- the derived hint: `done` (stop), `investigate` (stuck ->
      escalate), `raise_budget` (over_budget -> raise budget AND/OR step up).
    - `predicates[]` -- confirm it is the SAME slice still failing (the same
      unmet-predicate set), so you escalate against the same bar, not a new slice.
    - `reason` / `budget_spent.exceeded` -- on `over_budget`, name the budget
      dimension so you can choose "raise budget on the same model" vs "step up".

    **The trigger, in one line:** on a result for the slice's `goal_id` whose
    `status` is `stuck` or `over_budget` (equivalently `next_action` is `investigate`
    or `raise_budget`) -- i.e. NOT `converged` and NOT `error` -- with the same
    failing `predicates[]` still unmet, increment the per-`goal_id` rung counter and
    re-dispatch the SAME slice with the next `--model` UP the ladder.

    **Reset on a fresh slice.** A NEW slice means a NEW `goal_id`. Start it fresh on
    the cheapest rung (`claude-haiku-4-5`); the rung counter is per-`goal_id`, so a
    fresh slice has no carried-over rung.

    **Bounded by kazi.** Escalation rides ON TOP of kazi's own budget/stuck
    termination -- it never overrides a terminal verdict. Each rung is one
    `kazi apply`, which kazi itself bounds (it returns `stuck`/`over_budget` rather
    than looping forever), and the ladder is capped at `claude-opus-4-8`. So the
    escalation loop cannot run unboundedly: at worst it makes three bounded rungs and
    stops at the frontier.

    **Disable -> degenerates to static tiering.** Turn escalation OFF by pinning the
    `--model` to one rung and never stepping it up; the recipe collapses to the
    static cheap-tiering above (always `claude-haiku-4-5`, or always whatever single
    rung you pin). The ladder is the ADD-ON, not a requirement.

    Copy-paste recipe (the ladder, the trigger, the reset, the cap -- POSIX sh):

    ```sh
    # The capped ladder (cheapest -> frontier). Escalation STOPS at the last entry.
    ladder="claude-haiku-4-5 claude-sonnet-5 claude-opus-4-8"

    goal_file="$1"   # the approved slice's goal-file (a fresh slice starts at rung 1)
    rung=1           # SKILL state: the per-goal_id rung index (1-based), reset per slice

    while :; do
      model=$(printf '%s\\n' $ladder | sed -n "${rung}p")
      result=$(kazi apply "$goal_file" --workspace "$WS" \\
                 --harness claude --model "$model" --json)

      ver=$(printf '%s' "$result" | jq -r .schema_version)
      [ "$ver" = "2" ] || { echo "unexpected schema_version: $ver" >&2; exit 1; }

      status=$(printf '%s' "$result" | jq -r .status)
      case "$status" in
        converged)
          echo "slice converged on $model"; break ;;          # RESET happens for the NEXT slice (fresh goal_id, rung=1)
        error)
          printf '%s' "$result" | jq -r .error >&2; exit 1 ;;  # misconfig: FIX the goal, do NOT escalate
        stuck|over_budget)
          # same slice did not converge -> step UP the ladder, CAPPED at the frontier
          last=$(printf '%s\\n' $ladder | wc -w)
          if [ "$rung" -ge "$last" ]; then
            echo "exhausted the ladder at the frontier ($model); not converged" >&2; exit 1
          fi
          rung=$((rung + 1)) ;;                                # SKILL-side counter; never a kazi field
      esac
    done
    ```

    Add `--stream` to react WITHIN a rung (escalate before a rung fully terminates):
    watch the streamed per-iteration `predicates[]` -- the same failing set across
    every observation is no-progress this rung. This is strictly additive; the
    terminal `status` already suffices for the ladder (see `docs/tiering-signals.md`).

    ### The `status` verb -- report convergence (`kazi status <ref> --json`)

    `status` REPORTS a goal's convergence state from the read-model -- it never runs
    or mutates anything, it just reads the persisted projection. `kazi status <ref>
    --json` resolves `<ref>` as a run's goal id first (`kind: "run"`, with the latest
    iteration's predicate vector), else as a `proposal_ref` (`kind: "proposal"`, the
    lifecycle state). An unknown ref is a JSON error with a non-zero exit. Use it to
    poll a long convergence between steps, or to answer "where did this goal land?"
    after the fact.

    For a human watching multiple goals at once, the SAME read-model is rendered by
    kazi's LiveView dashboard: start the app's web endpoint and open its root URL
    (`http://localhost:4000/` by default) to see the live convergence view instead of
    polling `status` by hand. The dashboard is a READ of the same projection -- it
    drives nothing. (There is no separate `kazi` dashboard command; the CLI surface
    for state is `kazi status`, and the dashboard is the web view of it.)

    ### The `adopt` verb -- bring kazi into a repo (`kazi init <repo-dir>`)

    `adopt` reverse-engineers a STARTER goal-set from an existing repo by
    deterministic stack detection, so a repo that has not declared predicates gets a
    runnable first draft to refine. Route it to `kazi init`:

    ```sh
    kazi init <repo-dir> --out goal.toml
    ```

    `init` writes a starter goal-file (default `<repo>/kazi.goal.toml`, or `--out
    <file>`). The detection is deterministic; pass `--enrich` to additionally let a
    harness propose live predicates from discovered endpoints (off by default).
    Then review the drafted goal-set, refine it via the `plan` verb, approve, and
    `apply`. Use `adopt` once per repo to bootstrap; it is the on-ramp, not a step in
    the per-goal loop.

    ## Pin `schema_version`

    Every `--json` object carries a `schema_version` (currently **2**, bumped by
    ADR-0032 when the verbs unified). Read it off the first object you parse and
    refuse (or branch) if it is not the version you were written against:

    ```sh
    result=$(kazi apply "$GOAL" --workspace "$WS" --harness claude --model claude-haiku-4-5 --json)
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
