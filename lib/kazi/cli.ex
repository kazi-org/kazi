defmodule Kazi.CLI do
  @moduledoc """
  The `kazi` command-line entry point (T0.10, UC-004): load a goal-file and drive
  it to convergence against an explicit target workspace.

      kazi apply <goal-file> --workspace <path>

  This is the operator-facing seam over the real Slice-0 wiring. It does no
  reconciling itself — it parses argv, loads the goal via `Kazi.Goal.Loader`,
  hands it to `Kazi.Runtime.run/2`, and reports the loop's terminal outcome. The
  exit status mirrors convergence: `0` on `:converged`, non-zero otherwise, so the
  CLI composes in scripts and CI the same way the loop's own contract reads
  (concept §1, §5).

  ## Verbs (T27.1/T27.9, ADR-0032)

  `apply` (converge a goal) and `plan` (author intent) are the ONLY verbs,
  matching the operator's `/apply` and `/plan` vocabulary. The former deprecated
  aliases `run`/`propose` were REMOVED in v0.6.0 (T27.9): they no longer parse and
  now produce an "unknown command" error. `--json` stdout stays JSON-only (T15.7).

  ## Authoring surface (T3.5c, UC-017, ADR-0011)

  The CLI also exposes the idea → acceptance-predicate authoring flow over
  `Kazi.Authoring` (T3.5a/b): a human hands kazi a prose idea, reviews the drafted
  goal, and approves it into a runnable goal.

      kazi plan "<idea>"           # draft a goal from a prose idea (status proposed)
      kazi list-proposed           # review the proposal queue
      kazi approve <proposal-ref>  # proposed → approved (then runnable by `kazi apply`)
      kazi reject <proposal-ref>   # proposed → rejected (declined, kept for audit)

  These commands never reach into a running reconciliation; they only drive the
  one WRITE path the operator surfaces share (ADR-0011 §2). `plan` and `approve`
  print the `proposal-ref` an operator pipes between the steps; `approve` returns a
  goal `kazi apply` then drives to convergence.

  ## Building & running (escript)

      mix escript.build          # produces the ./kazi binary
      ./kazi apply priv/examples/deploy_target.toml --workspace /path/to/target
      ./kazi --help

  ## Read-model on startup

  The application supervision tree starts `Kazi.Repo` (SQLite read-model). The CLI
  boots the app and ensures that DB exists and is migrated *before* a run, so a
  fresh checkout converges on the very first invocation instead of crashing on a
  missing/locked database. If the read-model cannot be opened or migrated, the run
  degrades to `persist?: false` with a warning rather than aborting — the
  convergence loop is the product; persistence is a projection (concept §7).

  `main/1` is the escript `main_module` entry (see `mix.exs`); it terminates the
  VM with the computed exit code. The pure, testable core is `run/1`, which
  returns the exit code instead of halting so it can be exercised end-to-end.
  """

  alias Kazi.{Adopt, Authoring, Goal, ReadModel, Runtime}
  alias Kazi.Authoring.Clarify
  alias Kazi.ContextStore
  alias Kazi.ContextStore.{GistCLI, Snippet}
  alias Kazi.Authoring.Clarify.Question
  alias Kazi.Authoring.RationaleAdr
  alias Kazi.ContextStore.GistInit
  alias Kazi.Economy.{BudgetSuggestion, History}
  alias Kazi.Export.Obsidian
  alias Kazi.Fleet
  alias Kazi.Goal.DepGraph
  alias Kazi.Goal.Group
  alias Kazi.Goal.GroupLint
  alias Kazi.Harness.ChildSupervisor
  alias Kazi.Memory.SemanticIndex
  alias Kazi.Partition
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.ReadModel.ProposedMemory
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Reconcile.FirstPassRate
  alias Kazi.Reconcile.GherkinImporter
  alias Kazi.Teach.InstallHooks
  alias Kazi.Teach.InstallSkill

  @typedoc "Process exit code: 0 on convergence, non-zero otherwise."
  @type exit_code :: non_neg_integer()

  # The versioned machine-result contract version (ADR-0023 decision 2). Shared by
  # every --json surface — `apply` (T15.3), `status` (T15.5), and the authoring
  # transitions (T15.6) — so a breaking change to any of them bumps one number an
  # orchestrator pins. Defined here (before first use) so the helpers throughout
  # the module can reference it.
  #
  # Version 2 (ADR-0032, T27.3): the result contract's command key was renamed
  # `run` -> `apply` and `propose` -> `plan` (the verbs were unified across the
  # CLI, skill, and docs). The deprecated `run`/`propose` aliases were REMOVED in
  # v0.6.0 (T27.9); `apply`/`plan` are the only verbs.
  @run_schema_version 2

  # =============================================================================
  # command table — the SINGLE source of truth for the command/flag surface
  # =============================================================================
  #
  # T16.1 (ADR-0024 decision 2): `kazi help --json` is GENERATED from this table,
  # not hand-maintained, so adding a command/flag here automatically updates the
  # machine-readable surface every agent introspects (the coherence guard T16.4
  # keeps the skill/AGENTS.md honest against it). The same two structures drive the
  # parser:
  #
  #   * `@switches` IS the `OptionParser` `strict:` keyword list `parse/1` uses, so
  #     a flag's type is declared exactly once.
  #   * `@commands` lists each command with its positional args and the SUBSET of
  #     `@switches` it accepts; `help --json` joins the two (a flag's type comes
  #     from `@switches`) so the emitted surface can never drift from what the
  #     parser actually recognizes.
  #
  # Adding a command: add a `@commands` entry. Adding a flag: add it to `@switches`
  # and list its atom on the commands that accept it. `help --json` updates with no
  # extra work.
  @switches [
    workspace: :string,
    env: :string,
    standing: :boolean,
    debrief: :boolean,
    status: :string,
    enrich: :boolean,
    with_mcp: :boolean,
    with_gist: :boolean,
    out: :string,
    dir: :string,
    local: :boolean,
    uninstall: :boolean,
    harness: :string,
    model: :string,
    effort: :string,
    permission_mode: :string,
    allowed_tools: :string,
    yes: :boolean,
    strict: :boolean,
    adr: :boolean,
    predicates: :string,
    replace: :boolean,
    discover: :boolean,
    obsidian: :string,
    json: :boolean,
    stream: :boolean,
    parallel: :boolean,
    parallelism: :integer,
    explain: :boolean,
    dry_run: :boolean,
    fleet: :boolean,
    fleet_concurrency: :integer,
    pause_between_waves: :boolean,
    resume: :string,
    check: :boolean,
    provider: :string,
    budget: :integer,
    context_store: :string,
    context_budget: :integer,
    session_name: :string,
    allow_primary_workspace: :boolean,
    allow_duplicate_run: :boolean,
    allow_workspace_collision: :boolean,
    no_preflight: :boolean,
    in_place: :boolean,
    base: :string,
    strict_landing: :boolean,
    rediscovery: :string,
    port: :integer,
    bind: :string,
    nats_bin: :string,
    nats_port: :integer,
    nats_host: :string,
    nats_token: :string,
    topic: :string,
    sev: :string,
    scope: :string,
    peek: :boolean,
    full: :boolean,
    team: :string,
    all: :boolean,
    project: :string,
    machine: :string,
    timeout: :integer,
    since: :string,
    attention: :boolean,
    roadmap: :string,
    goal: :string,
    into: :string,
    lower: :string,
    write: :string,
    reap: :boolean,
    help: :boolean,
    version: :boolean
  ]

  @aliases [h: :help, v: :version]

  # T51.2/#1060 (ADR-0067): the `bus` verbs and the valid `post` kinds --
  # defined here (above `parse/1`) so both the `--help` interception below and
  # `parse_bus/2` read the SAME lists; no duplicated/drifting copies.
  @bus_verbs ~w(post read peek who board tell status get watch join leave name hook)
  @bus_kinds ~w(fact announce note intent)
  @default_bus_kind "fact"

  # One-line flag descriptions for the machine surface. Every flag a command lists
  # in `@commands` MUST have an entry here (the help-json test asserts this), so
  # `help --json` never emits a flag with no documentation.
  @flag_docs %{
    workspace:
      "Target workspace where edits/integrate/deploy run (falls back to the goal-file's [scope] workspace).",
    env:
      "Deploy environment to target (e.g. staging / prod); selects the goal/deploy's per-env target.",
    standing:
      "Run as a STANDING (continuous/maintenance) reconciler instead of converging and stopping.",
    into:
      "`spec import` only (T40.2, ADR-0050): the target goal-file the imported Scenarios' `test_runner` predicates are UPSERTED into (required). When the file exists its groups/predicates are merged (same-id predicates replaced in place, not duplicated); when it does not, it is created from the import. Under --json the result carries the written `into` path and the upserted predicate ids.",
    lower:
      "`spec import` only (T49.11, ADR-0054 d3): the lowering mode for TAGGED Scenarios — `test_runner` (default; byte-identical to today) or `scenario` (a Scenario tagged @interface:web lowers to a `scenario` predicate on the browser surface, @interface:cli to the cli surface, wiring the runtime scenario provider / demonstrate-then-pin ADR-0064). Untagged Scenarios and other-interface tags stay `test_runner` regardless.",
    write:
      "`approve` only (T39.3, ADR-0049): materialize the approved goal as a loadable goal-file at <path>, so a file-based / version-controlled workflow can `apply <path>` and get the SAME goal `apply <ref>` runs. Under --json the result carries the written `path`. Absent, approve is unchanged.",
    reap:
      "`orphans` only (T54.5, issue #1073): actually KILL each orphaned harness process group (TERM then KILL) instead of only listing it. Read-only without it.",
    debrief:
      "Opt into post-dispatch debrief capture (ADR-0058): append one capped debrief question to the dispatch prompt and persist the agent's structured answer as hypothesis rows. Overrides the goal-file's [economy] debrief field.",
    status:
      "Filter `list-proposed` (goal proposals) or `memory list-proposed` (harvested memory proposals, ADR-0063) to one lifecycle state (proposed / approved / rejected). Default: all.",
    enrich:
      "`init` only: opt into harness enrichment (off by default) to propose live predicates.",
    with_mcp:
      "`init` only: also write the canonical kazi MCP client config to the repo's .mcp.json ({command:\"kazi\",args:[\"mcp\"]}), so an MCP harness drives kazi natively (ADR-0044).",
    with_gist:
      "`init` only: opt THIS repo into the Gist context store — verify `gist doctor`, write .kazi/context.toml, register the `gist serve` MCP server in .mcp.json, and recommend KAZI_GIST_DSN. Project-local only; never touches global config (ADR-0045).",
    out:
      "`init`: output goal-file (default <repo>/kazi.goal.toml). `plan render`: write the generated markdown roadmap plan to this file instead of stdout (T45.5); the file is GENERATED — hand-edits are overwritten on the next render.",
    dir:
      "`install-skill` / `install-hooks`: target directory -- the skill directory for `install-skill` (default ~/.claude/skills/kazi), the settings directory for `install-hooks` (default ~/.claude). Injected to a tmp dir in tests.",
    local:
      "`install-hooks` only (ADR-0071 decision 3): target the repo's LOCAL, uncommitted .claude/settings.local.json instead of the user-level ~/.claude/settings.json. The installer NEVER writes a committed project settings file (ADR-0034).",
    uninstall:
      "`install-hooks` only: remove exactly the hook entries a previous install added -- every other key/entry is preserved, and uninstall right after a fresh install restores the pre-install bytes exactly.",
    harness:
      "Coding harness to drive: claude (default) or opencode. Overrides the goal-file/app config.",
    model:
      "Model the harness should use, e.g. local/qwen3.6. Overrides the goal-file's [harness] model.",
    effort:
      "Reasoning effort level the claude harness should use, e.g. low / medium / high (forwards claude --effort). Claude-only; overrides the goal-file's [harness] effort.",
    permission_mode:
      "`apply` only: permission mode the claude harness should run with, e.g. auto / acceptEdits / bypassPermissions / plan (forwards claude --permission-mode). Defaults to auto: a headless dispatch against a workspace that has not been through Claude Code's interactive trust dialog has every tool call silently denied while still exiting 0, and kazi's ephemeral partition worktree is a new path every run so the dialog can never be pre-accepted. Note acceptEdits allows edits but NOT Bash, so a goal whose predicates need git cannot converge under it. Claude-only; overrides the goal-file's [harness] permission_mode.",
    allowed_tools:
      "`apply` only: comma/space-separated tool allow-list the claude harness may use, e.g. \"Write,Bash,Edit\" (forwards claude --allowed-tools). Claude-only; overrides the goal-file's [harness] allowed_tools.",
    yes: "`plan` only: skip the interactive clarify questions and draft best-effort.",
    strict: "`plan` only: refuse an underspecified idea non-interactively instead of guessing.",
    adr:
      "`plan` only: also write an ADR-lite rationale doc under docs/adr/ for the drafted goal.",
    predicates:
      "`plan` only (caller-drafts): a proposal payload the caller already authored; kazi spawns no model. A payload \"goal_id\"/\"idea\" names the goal and its idea verbatim (T39.1, ADR-0049); absent, they are derived from \"id\"/\"name\" or generated.",
    replace:
      "`plan` only: allow re-proposing onto a proposal_ref that already holds an APPROVED proposal (default: refused, to protect against silently discarding an approved goal's audit trail).",
    discover:
      "`plan` (kazi-drafts, T45.6/UC-059): opt-in; attaches best-effort discovery evidence (stack detection, `.feature` use-cases, a public-surface codebase scan) to the drafted proposal, visible via `kazi status <proposal-ref> --json`; caller-drafts (--predicates/--project) bypass it, and any discovery step failing degrades to a plain draft with a warning, never a hard error. `init` (T41.4/UC-053): opt-in; writes a starter goal-file whose SOLE predicate is the manifest-coverage check (`spec_coverage`), scoped to the target repo -- RED on a repo with no `.feature` files yet. Off by default (mirrors --enrich); it only AUTHORS the goal, it never dispatches a harness -- run `kazi apply` on the written goal to converge it.",
    obsidian:
      "`export` only: the target directory for the Obsidian vault (group/predicate notes + Mermaid).",
    json:
      "Emit a single JSON object to stdout instead of human prose (the machine surface; NON-INTERACTIVE).",
    stream: "`apply --json` only: emit a JSONL progress stream, one event per loop iteration.",
    parallel:
      "`apply` only: drive the PARALLEL scheduler over the partitioned goal-set instead of the serial loop; under --json emits the collective result. An optional `--parallel N` records a concurrency hint.",
    explain:
      "`apply` only: PRINT the computed wave schedule (the topological `needs`-DAG frontiers + the blast-radius parallelism within each) and EXIT 0 WITHOUT EXECUTING — dispatches nothing, so over-constraint is visible before a run. Also reports the per-partition worktree isolation plan (T59.9, #937): each partition's own git worktree, never the --workspace root, so isolation is inspectable up front. Under --json emits the schedule as JSON. Alias of --dry-run.",
    dry_run:
      "`apply` only: alias of --explain — print the computed schedule and exit 0 without dispatching anything.",
    fleet:
      "`apply` only (T50.4/T50.5, ADR-0065 decision 3): treat the positional argument as a fleet — a DIRECTORY of *.goal.toml files (non-recursive, sorted) or a manifest .toml file ([[member]] path = \"...\" entries) — instead of a single goal-file. Builds a fleet DAG (explicit [metadata] depends_on edges + inferred scope-overlap serialization) and EXECUTES it through the partition scheduler one level up: each member goal runs in its own kazi-owned task worktree off the shared --workspace base, dispatching the instant its deps settle (pipelined frontiers), landing converged work on the base per the serial landing, with a registry row per member and an honest-unknown economy rollup in the terminal object. With --explain: print the schedule and dispatch nothing.",
    fleet_concurrency:
      "`apply --fleet` only (T50.5): cap how many fleet member goals RUN at once (a counting-semaphore gate around the member runner; DAG readiness/frontier semantics are untouched). Default: unbounded within a frontier — every ready member runs concurrently, the same behavior as a needs-DAG goal's groups.",
    pause_between_waves:
      "`apply` only (T50.3, ADR-0065 decision 3, issue #936): the supervised-checkpoint mode. With --parallel on a needs-DAG/group goal, or with --fleet, stop STARTING new groups once the current frontier settles (in-flight groups finish, by pipelining), persist a resume checkpoint to the read-model, and exit 0 with a `paused` collective carrying a resume_token — continue later with --resume <token>. Rejected without --parallel/--fleet (a serial loop has no wave boundaries); on a flat goal-set with no frontiers it is a no-op, mirroring frontier_complete.",
    resume:
      "`apply` only (T50.3, ADR-0065 decision 3): continue a run previously paused by --pause-between-waves from its persisted checkpoint — settled groups keep their terminal statuses; execution continues from the next frontier to the collective verdict. Pass the SAME goal-file (or --fleet source) plus the resume_token the paused result carried: a changed goal-set REFUSES loudly ('goal file changed since pause; re-run instead') rather than resuming against different work, and an unknown token is a clear error, never a silent fresh run. Composes with --pause-between-waves to advance one frontier at a time.",
    check:
      "`apply` only (issue #805): observe-only mode — evaluate the predicate vector EXACTLY ONCE via the real provider path and exit; never dispatches a harness, integrates, or deploys. All-pass exits 0 (`status: \"pass\"`, NOT the vacuous_goal error a normal run would give); any failing predicate exits 1 (`status: \"fail\"`) carrying predicates[] with captured evidence for the failures. For merge gates (ADR-0026) and release qualification.",
    provider:
      "`context` only: the context-store provider to proxy to (currently `gist`, the default). The provider stays independently usable; this is a thin wrapper so users learn one CLI (ADR-0045).",
    budget:
      "`context search`: cap the search result at N bytes (the byte budget the provider fits ranked snippets into). Default: the provider's own default. `memory recall`: cap the result at N TOKENS (ADR-0062's budgeted-recall guarantee, ~4 chars/token). Default: 0 (empty result).",
    context_store:
      "`apply` only: opt into the context store for the run — index oversized failing evidence and inject budget-fitted snippets instead of inlining it each iteration (currently `gist`). Off by default; absent, the dispatch + result are byte-identical (ADR-0045).",
    context_budget:
      "`apply` only: the per-iteration retrieval budget (bytes) the context store fits snippets into. Default 6000. Ignored without `--context-store`.",
    session_name:
      "`apply`: a human-readable label for the driving session, recorded on the run's fleet-registry row and shown on the mission control fleet dashboard so concurrent runs are tellable apart. `plan`: the same label, recorded on the proposal so a later `kazi approve`/`kazi apply` (possibly from a DIFFERENT session) can trace a run back to who planned it. `bus` (T55.5): the sender identity every bus verb carries on presence and message headers. Falls back to the KAZI_SESSION_NAME environment variable, then to CLAUDE_CODE_SESSION_ID (auto-detected when kazi runs as a Claude Code subprocess) when the flag is absent; for `bus`, all three absent falls back to a stable derived id (see docs/session-bus.md), elsewhere it leaves the run unlabeled (unchanged behavior).",
    allow_primary_workspace:
      "`apply` only: run against a workspace that is a git repo's PRIMARY (non-linked) worktree anyway. Without this flag, an executing apply refuses such a workspace (issue #937): the dispatched agent's shell can reset/clean the whole checkout, and a primary checkout routinely holds untracked state -- other sessions' files, goal-files, editor config -- that a wipe destroys. Prefer a dedicated task worktree (git worktree add); pass this flag only when you accept that risk (e.g. a throwaway clone). Read-only modes (--check, --explain) never need it.",
    allow_duplicate_run:
      "`apply` only: start this run even when the run registry already shows a LIVE run (status running, fresh heartbeat) for the same goal id. Without this flag, an executing apply refuses the duplicate -- a second concurrent apply of one goal burns a second budget and races the first's edits. Zombie rows never block (a dead run's heartbeat goes stale within ~90s); pass this flag only for a deliberate re-run alongside a live one.",
    allow_workspace_collision:
      "`apply` only (T59.7, issue #937): start this run even when the run registry already shows a LIVE run (status running, fresh heartbeat) for a DIFFERENT goal holding the SAME resolved workspace. Without this flag, an executing apply refuses -- N different goals dispatched against one shared --workspace cross-contaminate each other's commits. This complements --allow-duplicate-run (which covers a second run of the SAME goal). Zombie rows never block (a dead run's heartbeat goes stale within ~90s); pass this flag only for deliberate co-tenancy you know is safe.",
    no_preflight:
      "`apply` only (T44.9): SKIP the base-dispatchability preflight run before the first dispatch. By default an executing apply first verifies the base can receive the work -- command-backed predicates' tools are installed, and (per the goal's [integration] mode) `gh auth status` succeeds for pr/merge and `git push --dry-run` succeeds for branch/pr/merge -- plus that no stale worktree from a dead run of this goal is lying around; any failure REFUSES dispatch with a named, actionable error instead of burning a budget that can never land. Pass this flag to bypass ALL those checks (e.g. an offline run, or a base you know is fine). Read-only modes (--check, --explain) never run preflight.",
    in_place:
      "`apply` only (T50.1, ADR-0065 decision 1): edit --workspace directly instead of kazi's default of creating a kazi-owned task worktree off its HEAD and editing there. Without this flag, --workspace is the base the run integrates ONTO, not the edit site itself -- the dispatched agent's shell, and every predicate, runs inside a worktree kazi creates and removes on every terminal state (converged / stuck / over_budget / error / crash). Pass this flag to reproduce pre-T50.1 direct-edit behavior byte-identically (e.g. a throwaway clone where isolation buys nothing). A non-git workspace always runs in place -- worktree isolation needs a git repo.",
    base:
      "`apply` only (T50.8, ADR-0065 decision 5): the git ref the kazi-owned task worktree is created FROM (e.g. origin/main), instead of the default — the workspace's current HEAD. Passing it states intent: the stale-base warning (emitted when the defaulted HEAD base is behind its locally-known upstream) is silenced. The ref must already resolve in the local ref store — kazi NEVER fetches; an unknown ref is an error naming it, not a network call. Contradicts --in-place (there is no worktree to base): the combination is rejected.",
    strict_landing:
      "`apply` only (issue #1407): couple the exit code to landing, not just convergence. By DEFAULT the exit code mirrors convergence alone (0 on `:converged`, even when the worktree-isolated serial landing FAILS — a converged-but-unlanded run still exits 0; the surviving task branch and the `integration.landed == false` evidence remain visible in the result and a stderr warning). Pass --strict-landing to restore the pre-#1407 behavior: a converged-but-unlanded run downgrades the exit code to 1, for a caller (e.g. a CI gate) that wants a landing failure to fail the invocation outright. Has no effect on an in-place run (nothing to land) or when landing succeeds.",
    port:
      "`dashboard` only: TCP port to bind the standalone fleet-mode web endpoint to. Default 4050.",
    bind:
      "`dashboard` only: interface to bind (default 127.0.0.1 -- loopback only). Set explicitly to bind a non-loopback address; overriding is loud (printed at boot), never silent.",
    nats_bin:
      "`daemon start` only (T51.2, ADR-0067 decision point 2): explicit path to the `nats-server` binary the daemon supervises for the session bus. Default: resolved from PATH. Neither found -- `daemon start` fails with one clear line naming the missing binary; the daemon never runs busless.",
    nats_port:
      "`daemon start` only (T51.2): TCP port the supervised nats-server binds. Default 4223 (deliberately non-standard -- never collides with an operator's own NATS on 4222). Discovered by bus clients through the daemon's control-socket ping, never guessed.",
    nats_host:
      "`daemon start` only (T51.3, ADR-0067 cross-machine): connects to a REMOTE nats-server at this host instead of spawning a local one -- the promised 'or connects to an external one via config'. Needs no local nats-server binary. Combine with --nats-port for the remote's port and --nats-token if the shared bus requires one. See docs/session-bus.md (\"Cross-machine setup\").",
    nats_token:
      "`daemon start` only (T51.3): shared auth token for the session bus, e.g. `--nats-token <token>` or `KAZI_NATS_TOKEN`. Optional (default: no auth, today's behavior) -- the machine SPAWNING the bus passes it to nats-server's `-auth`; every machine CONNECTING (`--nats-host`) must pass the SAME token. Without one, a cross-machine bus is unauthenticated on the LAN.",
    topic:
      "`bus post` only: an optional free-text topic tag on the posted message (default none).",
    sev:
      "`bus post` only: message severity, `info` (default) or `interrupt`. `bus read`'s digest prints `interrupt` messages verbatim; everything else is summarized.",
    scope:
      "`bus post`/`bus read`/`bus tell` only: `machine` (default) or `project` (the current repo's canonical toplevel path, slugged) -- which bus subject tree the call addresses.",
    peek:
      "`bus read` only (issue #1059): non-destructive -- NAKs instead of acking, so the pending messages are shown but NOT consumed; a subsequent `bus read`/`bus peek` still sees them. Equivalent to `bus peek`.",
    full:
      "`portfolio` (E64/T64.3): restore the COMPLETE per-bucket ledger instead of the default bounded sitrep (each bucket's top-3 one-liners + '+N more'); every tracked entry is listed. " <>
        "`bus read`/`bus peek`/`bus watch` (T55.1, ADR-0072): under --json return EVERY pending message unabridged instead of the default bounded digest -- the documented debugging escape. Without it, --json returns the digest envelope (`kazi schema bus`): verbatim lines only for directed (kind msg) and sev interrupt messages, one-line stubs for bodies over the 1024-byte render threshold, exact count lines per {kind, topic} for everything else, at most 40 lines regardless of backlog size.",
    team:
      "`bus who` only (issue #1069): filter the presence roster to members of this named team (sessions register with `bus join <team>`).",
    all:
      "`bus who` only: include presence entries older than the 10-minute TTL (hidden by default so closed sessions age out of the roster instead of looking active; a TTL-stale entry whose process is verified alive locally is always shown, as `idle` -- T55.11).",
    project:
      "`bus who` only (T55.11): filter the roster to sessions whose cwd is this directory or lives under it (expanded to an absolute path) -- replaces the `who | grep <path>` pipeline.",
    machine:
      "`bus who` only (T55.11): filter the roster to sessions recorded by this machine (exact hostname match).",
    timeout:
      "`bus watch` only (issue #1091): maximum seconds to block waiting for a message (default 300). On expiry `bus watch` prints a one-line notice and exits 3.",
    since:
      "`bus watch` only (T54.9, issue #1097): what counts as a NEW message -- `now` (default) anchors to the stream's current last sequence so only messages posted AFTER the watch starts are delivered (pending backlog is left for `bus read`/`bus peek`); `all` restores the pre-T54.9 drain-first behavior (anything already pending returns immediately); a numeric stream sequence anchors there precisely.",
    attention:
      "`bus board` only (T60.3, issue #1156): render ONLY the NEEDS OPERATOR section of the human board -- the fleet-wide list of sessions with a live `waiting-on-operator` fact, oldest first. --json is unaffected: the full board (including `attention`) is always returned; this only trims the human render.",
    roadmap:
      "`dashboard` only (T47.2, ADR-0056/ADR-0070): path to a goal-file whose declared groups are the roadmap's goal-level `needs` edges. Mission Control loads it through `KaziWeb.Starmap.GoalSource` and GROUPS the fleet grid into needs-DAG wave sections (`Kazi.Goal.DepGraph.frontiers/1`, the SAME computation `kazi apply --explain` prints). Only takes effect on a FRESH standalone boot -- advisory (ignored, with a printed warning) when this process already serves the endpoint, like --port/--bind. Absent, mission control keeps its flat-grid fallback (unchanged behavior). An unloadable goal-file is a loud boot error (non-zero exit), never a silently-empty roadmap.",
    goal:
      "`economy` only: restrict the run-economics history aggregate to one goal_ref. Default: aggregate across every goal on this read-model (ADR-0058).",
    help: "Show this help and exit.",
    version: "Print the kazi version and exit.",
    rediscovery:
      "`economy` only (T48.10, ADR-0058 decision 3): fold the goal's recorded per-iteration `tools` counters into a RANKED, REPORT-ONLY rediscovery-pressure candidate list (which tool category keeps recurring across dispatches instead of falling off after the first). A goal with no recorded tool-use stream reports `unknown`, never a fabricated empty ranking (ADR-0046). Feeds nothing back into a dispatch prompt."
  }

  # The command table. Each entry: a one-line summary, the positional args (name +
  # whether required), and the flags (the `@switches` atoms) it accepts. `help
  # --json` renders this verbatim; the parser dispatches on the same names below.
  #
  # T27.1/T27.9 (ADR-0032): `apply`/`plan` are the ONLY verbs. The deprecated
  # `run`/`propose` aliases were REMOVED in v0.6.0 (T27.9); the table lists only the
  # live commands, so the coherence guard (T16.4) and the shipped skill/AGENTS.md
  # reference only verbs that exist. `help --json`/`schema` (T27.4) report the
  # surface generated from this table.
  @commands [
    %{
      name: "apply",
      summary:
        "Drive a goal to convergence against a target workspace, from a goal-file path or an APPROVED proposal's prop-... ref (T39.2, ADR-0049).",
      args: [%{name: "goal-file|proposal-ref", required: true}],
      flags: [
        :workspace,
        :env,
        :standing,
        :debrief,
        :harness,
        :model,
        :effort,
        :permission_mode,
        :allowed_tools,
        :json,
        :stream,
        :parallel,
        :explain,
        :dry_run,
        :fleet,
        :fleet_concurrency,
        :pause_between_waves,
        :resume,
        :check,
        :context_store,
        :context_budget,
        :session_name,
        :allow_primary_workspace,
        :allow_duplicate_run,
        :allow_workspace_collision,
        :no_preflight,
        :in_place,
        :base,
        :strict_landing
      ]
    },
    %{
      name: "status",
      summary:
        "Report a run/proposal's current state from the read-model (a pure read); with no <ref>, list every currently LIVE run (the pre-upgrade check, issue #971).",
      args: [%{name: "ref", required: false}],
      flags: [:json]
    },
    %{
      name: "orphans",
      summary:
        "List runs whose recorded harness child process is STILL alive -- a dispatch that outlived its controller (issue #1073/#857). Read-only by default; `--reap` sends TERM then KILL to each orphaned process group.",
      args: [],
      flags: [:reap, :json]
    },
    %{
      name: "portfolio",
      summary:
        "Sitrep: 'where are we / how is it going?' (E64, #1427). One headline line of counts + percentages across the five buckets (done / in-progress / blocked / todo / planned), then each bucket's top-3 one-liners + '+N more' (blocked entries name their blocker; in-progress entries carry an honest predicates-green rate, never a projected date). --full restores the complete ledger. Composed ONLY from kazi's own objective surfaces (proposals, the run registry, the attention queue, the roadmap DAG). No manual curation.",
      args: [],
      flags: [:full, :json]
    },
    %{
      name: "init",
      summary:
        "Adopt a repo by stack detection and write a starter goal-file (incl. a learned [budget] suggestion when local history has one, ADR-0058).",
      args: [%{name: "repo-dir", required: true}],
      flags: [:out, :discover, :enrich, :with_mcp, :with_gist, :workspace]
    },
    %{
      name: "install-skill",
      summary:
        "Write the kazi Claude Code skill (opt-in) so an orchestrating agent knows the recipe.",
      args: [],
      flags: [:dir]
    },
    %{
      name: "install-hooks",
      summary:
        "Register the session-bus delivery hooks in the Claude Code settings (opt-in, ADR-0071/T60.3): SessionStart + UserPromptSubmit + Notification run `kazi bus hook <event>`. Merge-never-clobber and idempotent -- an operator's own hooks/keys survive byte-identically; `--uninstall` removes exactly what was added. Default target is the user-level ~/.claude/settings.json; `--local` targets the repo's LOCAL (uncommitted) .claude/settings.local.json.",
      args: [],
      flags: [:dir, :local, :uninstall]
    },
    %{
      name: "mcp",
      summary: "Start the kazi MCP server over stdio (the same server `mix kazi.mcp` starts).",
      args: [],
      flags: []
    },
    %{
      name: "dashboard",
      summary:
        "Boot the standalone fleet-mode web endpoint (mission control: every registered run, read-only, no goal loop) against the shared read-model.",
      args: [],
      flags: [:port, :bind, :roadmap]
    },
    %{
      name: "daemon",
      summary:
        "Lifecycle for the long-lived per-machine kazi daemon (ADR-0067, T51.1/T51.2): `daemon start|stop|status|restart` over a local Unix-socket control plane with a version handshake (`status --json` reports `schema_vsn`, the daemon's stamped read-model schema version, for the ADR-0068 skew handshake); `start` also supervises nats-server for the session bus and migrates the read-model ONCE before serving any write (T52.4, migrate-before-serve). `restart` (T52.4) is stop-then-start -- the operator's one-command schema-skew remedy -- and errors clearly if no daemon was running. Convergence never depends on the daemon.",
      args: [%{name: "subcommand", required: true}],
      flags: [:json, :nats_bin, :nats_port, :nats_host, :nats_token]
    },
    %{
      name: "bus",
      summary:
        "Session bus verbs (ADR-0067, T51.2): `bus post|read|peek|who|board|tell|status|get|watch|join|leave|name|hook` over the daemon-supervised NATS JetStream bus. Requires a running `kazi daemon` -- each verb prints a one-line no-daemon error (exit 1) when it isn't. `bus <verb> --help` prints that verb's own usage. `bus post` with no <kind> defaults to `fact`; an explicit unknown kind is a usage error enumerating the valid kinds. `bus board` (T55.4/T55.8, ADR-0073) renders CURRENT STATE -- last-value fact per topic + the live roster + claim ownership read live from refs/claims/* -- cursor-free and idempotent (consumes nothing, safe to read every turn), bounded by the same digest rules as read. `bus watch` blocks until a NEW message arrives (issues #1091/#1097; `--since <seq|now|all>` anchors what counts as new, exit 3 on timeout); `bus join` (argless, T65.1/#1430: DERIVES the team from the git origin as a `t-<host>-<org>-<repo>` slug -- a fixed `t-` prefix so no team slug can begin with `-`; `bus join -- <team>` is the explicit cross-repo override, recorded `derived=false`; join also returns a daemon-ASSIGNED short name `<team>-a/b/c...` allocated atomically through the KV bucket, T65.3)/`bus leave` manage team membership (issue #1069), with `bus tell @<team>` fanning out to members and `bus who --team <t>` filtering the roster. `bus tell` prints the message's id and `bus status <id>` answers `pending|consumed` from the recipient's ack state, while `bus who` shows each session's un-read inbox depth (T55.12) -- a tell's success means QUEUED, never seen. `bus read|peek|watch --json` return the bounded DIGEST by default (T55.1, ADR-0072; shape via `kazi schema bus`); `--full` is the documented escape returning every message unabridged. `bus get <id>` is the deliberate pull for a stubbed body (ADR-0072 d3): a direct stream fetch by id that consumes NOTHING (no cursor disturbed), printing a bounded preview by default and the whole body under `--full`.",
      args: [%{name: "subcommand", required: true}],
      flags: [
        :json,
        :topic,
        :sev,
        :scope,
        :peek,
        :full,
        :team,
        :all,
        :project,
        :machine,
        :timeout,
        :since,
        :session_name,
        :attention
      ]
    },
    %{
      name: "economy",
      summary:
        "Read-only run economics (ADR-0058): aggregate persisted run-end economics into p50/p95 percentiles by goal shape/model/harness, or --rediscovery <goal> for a ranked rediscovery-pressure candidate report.",
      args: [],
      flags: [:goal, :rediscovery, :json]
    },
    %{
      name: "plan",
      summary:
        "Draft a goal of acceptance predicates from a prose idea (or caller-supplied predicates); includes a learned [budget] suggestion when local history has one (ADR-0058). `plan render <roadmap>` instead renders a roadmap DAG as a GENERATED markdown plan (T45.5).",
      args: [%{name: "idea|render <roadmap>", required: false}],
      flags: [
        :workspace,
        :yes,
        :strict,
        :adr,
        :json,
        :predicates,
        :replace,
        :discover,
        :session_name,
        :project,
        :out
      ]
    },
    %{
      name: "list-proposed",
      summary: "List the proposal queue, optionally filtered by lifecycle state.",
      args: [],
      flags: [:status, :json]
    },
    %{
      name: "approve",
      summary: "Transition a proposal proposed → approved (then runnable by `kazi apply`).",
      args: [%{name: "proposal-ref", required: true}],
      flags: [:json, :write]
    },
    %{
      name: "reject",
      summary: "Transition a proposal proposed → rejected (declined, kept for audit).",
      args: [%{name: "proposal-ref", required: true}],
      flags: [:json]
    },
    %{
      name: "export",
      summary:
        "Export a goal's group tree + verdicts to an Obsidian vault (notes + Mermaid rollup).",
      args: [%{name: "goal-file", required: true}],
      flags: [:obsidian, :json]
    },
    %{
      name: "lint",
      summary:
        "Advisory group-name check on a goal-file (exit 0 even with warnings); or validate a roadmap artifact's DAG (cycles, unresolvable refs — non-zero on a broken roadmap).",
      args: [%{name: "goal-file|roadmap", required: true}],
      flags: [:json]
    },
    %{
      name: "spec",
      summary:
        "Behavior-spec tier (ADR-0050, T40.2): `spec import <feature-file>... --into <goal-file>` derives one `test_runner` acceptance predicate per Gherkin Scenario (grouped by Feature) and UPSERTS them into the goal-file — re-importing the same spec is an upsert, not a duplicate. `--lower scenario` (T49.11, ADR-0054 d3) lowers @interface:web/@interface:cli-tagged Scenarios to runtime `scenario` predicates instead. `--json` emits the upserted predicate ids.",
      args: [
        %{name: "subcommand", required: true},
        %{name: "feature-file", required: false}
      ],
      flags: [:into, :lower, :json]
    },
    %{
      name: "context",
      summary:
        "Thin wrapper over the context-store provider: `context index|search|stats` (ADR-0045).",
      args: [
        %{name: "subcommand", required: true},
        %{name: "args", required: false}
      ],
      flags: [:provider, :budget, :json]
    },
    %{
      name: "memory",
      summary:
        "Budgeted FTS recall (`memory recall <query>`, ADR-0062) and the gated-harvest promotion queue (`memory list-proposed` / `approve` / `reject`, ADR-0063).",
      args: [
        %{name: "subcommand", required: true},
        %{name: "args", required: false}
      ],
      flags: [:workspace, :budget, :status, :json]
    },
    %{
      name: "help",
      summary: "Show usage. With --json, emit the command/flag surface as a single JSON object.",
      args: [],
      flags: [:json]
    },
    %{
      name: "schema",
      summary:
        "Emit the versioned --json result schema(s), a predicate-provider config schema (e.g. custom_script), or an artifact schema (e.g. roadmap).",
      args: [%{name: "command", required: false}],
      flags: [:json]
    },
    %{
      name: "version",
      summary: "Print the kazi version.",
      args: [],
      flags: [:json]
    }
  ]

  @usage """
  kazi — drive a goal to convergence against a target workspace.

  USAGE:
      kazi apply <goal-file> --workspace <path> [--harness <id>] [--model <m>] [options]
      kazi apply <proposal-ref> --workspace <path> [options]   # run an APPROVED proposal, no goal-file
      kazi apply <goal-file> --workspace <path> --json [--stream]
      kazi apply <goal-file> --workspace <path> --parallel [N] [--json] # parallel scheduler
      kazi apply <goal-file> --workspace <path> --explain [--json]      # print the schedule, run nothing
      kazi apply <goal-file> --workspace <path> --check [--json]        # observe the vector once, dispatch nothing
      kazi apply <goal-file> --workspace <path> [--in-place] [--base <ref>]  # workspace = the BASE; --in-place edits it directly (ADR-0065)
      kazi apply <goal-file> --workspace <path> --parallel --pause-between-waves  # pause at each wave boundary with a resume_token
      kazi apply <goal-file> --workspace <path> --resume <token>        # continue a paused run from its checkpoint
      kazi apply <roadmap-file> --workspace <path> [--explain] [--json] # run a roadmap's goals in needs order (T45.4, ADR-0075)
      kazi apply --fleet <dir|manifest> --workspace <path> [--fleet-concurrency N]  # a DAG of goal-files (ADR-0065)
      kazi status <ref> [--json]
      kazi orphans [--reap] [--json]               # list runs whose harness child is still alive (#1073); --reap kills them
      kazi portfolio [--full] [--json]             # sitrep: headline % + bucketed summaries + honest rate (E64, #1427); --full = full ledger
      kazi economy [--goal <ref>] [--json]         # run-economics history: p50/p95 by goal-shape/model/harness (ADR-0058)
      kazi economy --rediscovery <goal> [--json]   # ranked rediscovery-pressure report (ADR-0058)
      kazi init <repo-dir> [--out <file>] [--discover] [--enrich] [--with-mcp] [--with-gist]
      kazi install-skill [--dir <path>]           # write the Claude Code skill (opt-in)
      kazi install-hooks [--local] [--uninstall]  # register session-bus delivery hooks in the Claude Code settings (opt-in, ADR-0071)
      kazi mcp                                     # start the MCP server over stdio (ADR-0044)
      kazi plan "<idea>" [--workspace <path>] [--yes] [--strict] [--adr] [--json]
      kazi plan --json [--predicates <json>] [--replace]   # caller-drafts (predicates supplied)
      kazi plan render <roadmap-file> [--out <path>]       # render the roadmap DAG as a GENERATED markdown plan (T45.5)
      kazi list-proposed [--status <proposed|approved|rejected>] [--json]
      kazi approve <proposal-ref> [--json]
      kazi reject <proposal-ref> [--json]
        (authoring verbs -- plan / list-proposed / approve / reject -- need the
         release binary or `mix`; the escript build lacks the SQLite NIF)
      kazi export <goal-file> --obsidian <dir> [--json]   # write an Obsidian vault
      kazi lint <goal-file|roadmap> [--json]      # advisory group-name warnings; or validate a roadmap DAG (cycles, refs)
      kazi context index <label> <file> [--provider gist] [--json]   # index an artifact
      kazi context search "<query>" [--budget N] [--provider gist] [--json]
      kazi context stats [--provider gist] [--json]                  # byte accounting
      kazi memory recall "<query>" [--budget N] [--json]              # budgeted FTS recall (ADR-0062)
      kazi memory list-proposed [--status <state>] [--json]           # harvested memory proposals (ADR-0063)
      kazi memory approve <proposal-ref> [--json]                     # promote into its routed corpus file
      kazi memory reject <proposal-ref> [--json]                      # decline (kept for audit)
      kazi daemon start [--nats-bin <path>] [--nats-port <n>]  # boot the session-bus daemon (foreground)
      kazi daemon status [--json]                  # ping the running daemon (--json includes schema_vsn, the daemon's read-model schema version)
      kazi daemon stop                             # clean shutdown
      kazi daemon restart [--nats-bin <path>] [--nats-port <n>]  # stop-then-start (schema-skew remedy); errors if none was running
      kazi bus post [<kind>] <text> [--topic <t>] [--sev info|interrupt] [--scope machine|project] [--json]  # <kind> defaults to `fact`
      kazi bus tell <session>|<nickname>|@<team> <text> [--sev info|interrupt] [--scope machine|project] [--json]
      kazi bus watch [--timeout <seconds>] [--since <seq|now|all>] [--json]  # block until a NEW message arrives (#1091/#1097)
      kazi bus join [--json]                             # derive team from git origin + daemon-assigned name (T65.1/T65.3); `join -- <team>` for explicit
      kazi bus leave [--json]
      kazi bus name <alias> [--json]                     # attach an alias on top of the assigned name (T55.5/T65.3)
      kazi bus read [--peek] [--since <cursor>] [--json]   # --peek: show pending messages WITHOUT consuming them; --since <seq>: replay from a point
      kazi bus peek [--json]                       # non-destructive read (issue #1059)
      kazi bus who [--team <t>] [--project <dir>] [--machine <host>] [--all] [--json]   # roster with liveness (active|idle)
      kazi bus board [--scope machine|project] [--json]   # current state: facts + roster + claim ownership (T55.4/T55.8)
      kazi bus hook <event>                        # harness hook entry point (session-start | turn | notification) -- ALWAYS exits 0 silently
      kazi bus <verb> --help                       # per-verb usage
      kazi help [--json]                          # --json: the command/flag surface
      kazi schema [<command>]                      # --json result schema(s), a provider schema (custom_script), or an artifact schema (roadmap)

  ARGUMENTS:
      <goal-file>            Path to a TOML goal-file (see Kazi.Goal.Loader).
                             `apply` also accepts a `prop-...` proposal-ref in
                             this position (T39.2, ADR-0049): an APPROVED
                             proposal is loaded from the read-model and run
                             directly — no goal-file reconstruction. A
                             non-approved or unknown ref is a clear error; an
                             existing file path always behaves as before.
      <repo-dir>             A repo root to adopt — kazi detects the stack and
                             writes a starter goal-file (T5.5, UC-023, ADR-0013).
      <idea>                 A prose idea to draft into a goal of acceptance
                             predicates (T3.5a, UC-017).
      <proposal-ref>         A proposal's review handle (printed by `plan`).
                             `approve`/`reject` transition it; `apply` runs an
                             approved one directly.
      <ref>                  `status` only: a run's goal id (recorded iterations)
                             or a proposal-ref to report the current state of.

  OPTIONS:
      --workspace <path>     Target workspace where edits/integrate/deploy run
                             (or, for `plan`, where the harness drafts the
                             goal). Falls back to the goal-file's [scope]
                             workspace.
      --out <path>           `init` output goal-file (default
                             <repo>/kazi.goal.toml).
      --dir <path>           `install-skill` / `install-hooks`: target directory
                             — the skill directory for `install-skill` (default
                             ~/.claude/skills/kazi), the settings directory for
                             `install-hooks` (default ~/.claude). Opt-in,
                             consent-first — a normal `kazi` run never writes to
                             ~/.claude (ADR-0024/0071). Injected to a tmp dir in
                             tests.
      --local                `install-hooks` only (ADR-0071): target the repo's
                             LOCAL, uncommitted .claude/settings.local.json
                             instead of the user-level ~/.claude/settings.json.
                             The installer NEVER writes a committed project
                             settings file (ADR-0034).
      --uninstall            `install-hooks` only: remove exactly the hook
                             entries a previous install added. Every other
                             key/entry is preserved; run right after a fresh
                             install it restores the pre-install bytes exactly.
      --enrich               `init` only: opt into harness enrichment (OFF by
                             default) to propose live predicates from discovered
                             endpoints. The deterministic detection always stands.
      --with-mcp             `init` only: also write the canonical kazi MCP client
                             config to the repo's .mcp.json
                             ({command:"kazi",args:["mcp"]}) so an MCP-speaking
                             harness drives kazi natively (ADR-0044). Additive —
                             preserves any servers already declared.
      --with-gist            `init` only: opt THIS repo into the Gist context
                             store (ADR-0045). Verifies `gist doctor`, writes the
                             project-local .kazi/context.toml naming the provider,
                             additively registers the `gist serve` MCP server in
                             .mcp.json, and recommends setting KAZI_GIST_DSN for
                             cross-iteration persistence. PROJECT-LOCAL ONLY — it
                             never mutates a global agent config (~/.claude). When
                             `gist` is not installed it reports the missing dep and
                             exits non-zero (the goal-file is still written).
      --env <name>           Deploy environment to target, e.g. staging / prod
                             (T3.3d). Selects the goal/deploy's per-env target;
                             requires the goal-file's deploy config to define an
                             `envs` map for that environment.
      --standing             Run as a STANDING (continuous/maintenance)
                             reconciler (UC-016): instead of converging and
                             stopping, hold the goal's predicates true forever,
                             re-converging whenever one drifts. Overrides the
                             goal-file's `standing` field.
      --debrief              Opt into post-dispatch debrief capture (ADR-0058):
                             append one capped debrief question to the dispatch
                             prompt and persist the agent's structured answer as
                             hypothesis rows (never read back into a prompt).
                             Overrides the goal-file's `[economy] debrief` field.
      --status <state>       Filter `list-proposed` to one lifecycle state
                             (proposed / approved / rejected). Default: all.
      --goal <ref>           `economy` only: restrict the run-economics history
                             aggregate to one goal_ref. Default: every goal on
                             this read-model (ADR-0058).
      --yes                  `plan` only: skip the interactive clarify
                             questions and draft best-effort (also implied when
                             no TTY is attached, e.g. piped/CI).
      --strict               `plan` only: when run non-interactively, refuse an
                             underspecified idea (exit non-zero) instead of
                             guessing. Interactively, the clarify questions resolve
                             it.
      --adr                  `plan` only: additionally write an ADR-lite
                             rationale doc under docs/adr/ for the drafted goal.
      --predicates <json>    `plan` only (caller-drafts, ADR-0023): a proposal
                             payload — {"name","predicates":[...],"rationale"} —
                             the CALLER already authored. kazi spawns NO model:
                             it applies the deterministic clarify floor (flags a
                             missing live-verification target + scope), persists,
                             and gates approval. Alternatively supply it on stdin
                             under --json. The orchestrator's drive mode. A
                             payload "goal_id" names the goal verbatim and a
                             payload "idea" is persisted as the proposal's idea
                             (T39.1, ADR-0049); absent those, the goal id /
                             proposal_ref are derived from the payload's own
                             "id"/"name" (#787/#793), not a hardcoded
                             placeholder, so distinct payloads coexist.
      --replace              `plan` only: allow re-proposing onto a proposal_ref
                             that already holds an APPROVED proposal (#787/#793).
                             Default: refused, so a new draft never silently
                             discards an approved goal's audit trail.
      --discover             `plan` only (kazi-drafts, T45.6/UC-059): opt-in;
                             attaches best-effort discovery evidence (stack
                             detection, `.feature` use-cases, a public-surface
                             codebase scan) to the drafted proposal, visible via
                             `kazi status <proposal-ref> --json`. Caller-drafts
                             (--predicates/--project) bypass it entirely; any
                             discovery step failing degrades to a plain draft with
                             a warning, never a hard error.
      --json                 Emit a single JSON object to stdout instead of human
                             prose (the machine surface, ADR-0023). Implies
                             NON-INTERACTIVE: kazi never prompts/blocks on stdin
                             under --json; a command that would need interactive
                             input errors loudly (JSON error + non-zero exit).
                             Human output is the default.
      --stream               `apply --json` only: emit a JSONL progress stream — one
                             JSON event per loop iteration on stdout, terminated by
                             the final run-result object — so an orchestrator
                             monitors a long convergence without blocking (T15.4).
      --parallel [N]         `apply` only (T21.8, ADR-0027): drive the PARALLEL
                             SCHEDULER (`Kazi.Scheduler.run_goals/2`) over the
                             goal-set partitioned by blast radius, instead of the
                             serial single-goal loop — kazi-native parallelism, no
                             `/apply --pool` needed. Under --json it emits the
                             VERSIONED COLLECTIVE result (per-partition status + the
                             collective verdict + a next_action hint) documented in
                             docs/schemas/collective-result.md; it is NON-INTERACTIVE
                             under --json. A single-partition goal-set (one goal / no
                             blast radius) degrades to the serial behavior. The
                             optional `N` records a concurrency hint (parallelism is
                             otherwise by partition count).
      --pause-between-waves  `apply` only (T50.3, ADR-0065, issue #936): the
                             supervised-checkpoint mode. With --parallel on a
                             `needs`-DAG/group goal, or with --fleet, stop STARTING
                             new groups once the current frontier settles (in-flight
                             groups finish), persist a resume checkpoint to the
                             read-model, and exit 0 with a `paused` collective
                             carrying a resume_token. Rejected without
                             --parallel/--fleet (a serial loop has no wave
                             boundaries); a flat goal-set with no frontiers is a
                             no-op.
      --resume <token>       `apply` only (T50.3, ADR-0065): continue a run paused
                             by --pause-between-waves from its checkpoint — settled
                             groups keep their terminal statuses; execution
                             continues from the next frontier. Pass the SAME
                             goal-file (or --fleet source): a changed goal-set
                             refuses loudly rather than resuming different work; an
                             unknown token is a clear error, never a fresh run.
      --explain              `apply` only (T23.6, ADR-0028): PRINT the computed wave
      --dry-run              SCHEDULE and exit 0 WITHOUT EXECUTING. kazi computes
                             the topological `needs`-DAG frontiers (each frontier =
                             the groups whose every `needs` dep is satisfied by the
                             prior frontiers) and, within each frontier, the
                             blast-radius PARTITIONING (the parallelism), then prints
                             them and dispatches NOTHING — so over-constraint (too
                             many `needs` edges serializing everything) is VISIBLE
                             before a run. A goal with NO `needs` shows ONE frontier
                             (everything parallel); a chain shows N frontiers. It
                             also reports the per-partition worktree ISOLATION plan
                             (T59.9, #937): each partition's own git worktree, under
                             the managed base dir, NEVER the --workspace root — so a
                             caller can CONFIRM isolation before a long grind. Pure
                             planning: no reconciler/harness/lease is touched. Under
                             --json the schedule is emitted as a JSON object;
                             NON-INTERACTIVE. `--dry-run` is an alias of `--explain`.
      --check                `apply` only (issue #805): observe-only mode. Evaluates
                             the goal's FULL predicate vector EXACTLY ONCE via the
                             real provider path and exits — never dispatches a
                             harness, integrates, or deploys. All-pass exits 0 with
                             `status: "pass"` (the vacuous_goal guard does NOT apply
                             here — a check confirming an already-green vector is the
                             point, not a misconfigured goal); any failing predicate
                             exits 1 with `status: "fail"`, carrying `predicates[]`
                             plus captured evidence for the failures. For merge gates
                             (ADR-0026 L1) and release qualification — a cheap,
                             objective "does the vector hold" read. Under --json emits
                             a single JSON object; NON-INTERACTIVE.
      --write <path>         `approve` only: materialize the approved goal as a
                             loadable goal-file at <path> (T39.3, ADR-0049), so a
                             file-based / version-controlled workflow can
                             `apply <path>` and get the SAME goal `apply <ref>`
                             runs. Under --json the result carries the written
                             `path`. Absent, approve behaves exactly as before.
      --obsidian <dir>       `export` only: write an Obsidian vault to <dir> — one
                             note per group and per predicate, [[wikilinked]]
                             parent↔child, tagged with the verdict (intended/
                             built/pending), plus an OVERVIEW note carrying the
                             per-group rollups and a Mermaid diagram (T12.6,
                             ADR-0020).
      --harness <id>         Coding harness to drive (T8.7, ADR-0016): `claude`
                             (default) or `opencode`. Overrides the goal-file's
                             [harness] table and the app config.
      --model <provider/model>
                             Model the harness should use, e.g.
                             `local/qwen3.6` for opencode. Overrides the goal-file's
                             [harness] model.
      --provider <name>      `context` only (T35.7, ADR-0045): the context-store
                             provider the `context` subcommands proxy to. Currently
                             `gist` (the default), the CLI adapter to the `gist`
                             binary. A thin wrapper so users learn one CLI; the
                             provider stays independently usable.
      --budget <N>           `context search` only: cap the search result at N bytes
                             (the byte budget the provider fits ranked snippets
                             into). Default: the provider's own default.
      --rediscovery <goal>   `economy` only (T48.10, ADR-0058 decision 3): fold
                             the goal's recorded per-iteration `tools` counters
                             into a RANKED, REPORT-ONLY rediscovery-pressure
                             candidate list (which tool category -- file reads /
                             search calls / graph queries -- keeps recurring
                             across dispatches instead of falling off after the
                             first). A goal with no recorded tool-use stream
                             reports `unknown`, never a fabricated empty
                             ranking (ADR-0046 honest-unknown). Feeds NOTHING
                             back into a dispatch prompt -- purely advisory
                             until the T48.12 benchmark gate measures a real
                             win.
      --help, -h             Show this help and exit.
      --version, -v          Print the kazi version and exit.

  EXAMPLES:
      kazi apply priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target
      kazi apply priv/examples/deploy_target.toml --workspace ./target --env prod
      kazi apply priv/examples/standing_maintenance.toml --workspace ./svc --standing
      kazi apply my.goal.toml --workspace ./svc --harness opencode --model local/qwen3.6
      kazi init ./my-service --out my-service.goal.toml
      kazi init ./my-service --with-mcp            # also write .mcp.json (canonical kazi MCP config)
      kazi init ./my-service --with-gist           # opt this repo into the Gist context store (ADR-0045)
      kazi install-skill
      kazi install-hooks                           # opt into session-bus delivery (ADR-0071); --uninstall reverts
      kazi mcp                                     # an MCP client runs this as its server command
      kazi apply my.goal.toml --workspace ./svc --json --stream
      kazi status cli-e2e --json
      kazi plan "a /healthz endpoint that returns 200"
      kazi list-proposed --status proposed
      kazi approve prop-a-healthz-endpoint-3f9c1a2b4d5e
      kazi export priv/examples/grouped_taxonomy.toml --obsidian ./vault
      kazi lint priv/examples/grouped_taxonomy.toml
      kazi context index workspace-docs ./docs/concept.md --provider gist
      kazi context search "session cookie" --budget 4000 --json
      kazi context stats --json
      kazi economy --json
      kazi economy --rediscovery cli-e2e --json
  """

  @doc """
  Escript entry point. Parses `argv`, runs, and halts the VM with the resulting
  exit code (`0` converged, non-zero otherwise / on error).

  Wrapped in `Kazi.SwapDiagnosis.guard/1` (issue #856): an exception raised
  while the installed release has changed underneath this VM is reported as
  one clear line instead of a misleading stack trace; any other exception is
  re-raised unchanged.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    Kazi.StartupWatchdog.with_watchdog(fn ->
      Kazi.SwapDiagnosis.guard(fn -> run(argv) end)
    end)
    |> System.halt()
  end

  @doc """
  The testable core: parse `argv`, execute the command, print a human-readable
  result, and return the exit code (without halting). `IO` is used directly so
  tests can capture stdout via `ExUnit.CaptureIO`.

  `inject_opts` are extra options the CLI threads into its underlying API for the
  `apply` and `plan` commands. Production callers (the escript `main/1` and
  `mix kazi.apply`) pass none; the Tier-2 boundary tests use them to point the
  existing injectable seams at local stubs — exactly as `Kazi.RuntimeTest` /
  `Kazi.AuthoringTest` do — without the CLI ever naming a concrete harness/action:

    * for `apply`, merged into `Kazi.Runtime.run/2` (`:adapter_opts`, `:integrator`,
      `:deploy_cmd`, `:deploy_params`, …).
    * for `plan`, merged into `Kazi.Authoring.propose/2` (`:harness`,
      `:adapter_opts`), so the e2e test drafts via a stub harness with no real
      `claude`.

  Returns `0` on success (convergence / a recorded proposal / approval), a
  non-zero code on a stopped loop, a load/usage error, or an internal failure.
  """
  @spec run([String.t()], keyword()) :: exit_code()
  def run(argv, inject_opts \\ []) when is_list(argv) and is_list(inject_opts) do
    # T39.4 (ADR-0049 decision 4, issue #804): under `--json`, stdout must carry
    # EXACTLY one JSON object (JSONL under `--stream`) on every entrypoint —
    # release, escript, `mix run`. `config/config.exs` already routes the default
    # `:logger` handler to stderr, but a dev/`mix run` environment can point a
    # handler back at stdout (a local logger config, a dependency's setup), and
    # then a mid-run log line (Ecto's "Migrations already up" was the observed
    # leak) lands ahead of the JSON object and breaks a `jq` parse. Redirect any
    # stdout-writing handler to stderr BEFORE parse/dispatch, so every log fired
    # during the run goes to stderr. Non-`--json` runs are untouched.
    if "--json" in argv, do: Kazi.Logging.StderrRedirect.redirect()

    case parse(argv) do
      {:help, flags} ->
        # T16.1 (ADR-0024 decision 2): under --json emit the command/flag surface
        # GENERATED from the command table (so any agent can introspect kazi at
        # runtime); the human usage prose otherwise (the default).
        emit(json?(flags), help_json(), fn -> IO.puts(@usage) end)
        0

      {:bus_help, verb} ->
        # #1060: per-verb `bus <verb> --help` -- always human prose (a `--help`
        # request has no accompanying `--json` intent here; `bus_help_text/1`
        # is the single source both this and `docs/session-bus.md` describe).
        IO.puts(bus_help_text(verb))
        0

      {:schema, command, _flags} ->
        # T16.1 (ADR-0024 decision 2): emit the versioned result schema(s) for
        # `--json` output. `schema` is JSON-only — it has no human prose surface —
        # so it always emits the schema object (the `--json` flag is accepted but
        # redundant).
        execute_schema(command)

      {:version, flags} ->
        # T15.1 (ADR-0023): the first command to prove the --json seam end-to-end.
        # Human (default): `kazi <vsn>`. Machine (--json): a single JSON object.
        emit(json?(flags), %{kazi: version(), schema_version: @run_schema_version}, fn ->
          IO.puts("kazi #{version()}")
        end)

        0

      {:run, goal_file, opts} ->
        execute_run(goal_file, opts, inject_opts)

      {:status, ref, opts} ->
        execute_status(ref, opts)

      {:orphans, opts} ->
        execute_orphans(opts)

      {:portfolio, opts} ->
        execute_portfolio(opts)

      {:init, source, opts} ->
        execute_init(source, opts, inject_opts)

      {:install_skill, opts} ->
        execute_install_skill(opts, inject_opts)

      {:install_hooks, opts} ->
        execute_install_hooks(opts, inject_opts)

      {:mcp, _opts} ->
        execute_mcp(inject_opts)

      {:dashboard, opts} ->
        execute_dashboard(opts, inject_opts)

      {:daemon, subcommand, args, opts} ->
        execute_daemon(subcommand, args, opts, inject_opts)

      {:bus, subcommand, args, opts} ->
        execute_bus(subcommand, args, opts)

      {:propose, idea, opts} ->
        execute_propose(idea, opts, inject_opts)

      {:plan_render, roadmap, opts} ->
        execute_plan_render(roadmap, opts)

      {:list_proposed, opts} ->
        execute_list_proposed(opts)

      {:approve, proposal_ref, opts} ->
        execute_approve(proposal_ref, opts)

      {:reject, proposal_ref, opts} ->
        execute_reject(proposal_ref, opts)

      {:export, goal_file, opts} ->
        execute_export(goal_file, opts)

      {:lint, goal_file, opts} ->
        execute_lint(goal_file, opts)

      {:spec_import, paths, opts} ->
        execute_spec_import(paths, opts)

      {:context, subcommand, args, opts} ->
        execute_context(subcommand, args, opts, inject_opts)

      {:memory, subcommand, args, opts} ->
        execute_memory(subcommand, args, opts)

      {:economy, opts} ->
        execute_economy(opts)

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}\n")
        IO.puts(:stderr, @usage)
        2
    end
  end

  # =============================================================================
  # argv parsing
  # =============================================================================

  @typedoc false
  @type parsed ::
          {:help, keyword()}
          | {:schema, String.t() | nil, keyword()}
          | {:version, keyword()}
          | {:run, Path.t(), keyword()}
          | {:status, String.t() | nil, keyword()}
          | {:orphans, keyword()}
          | {:portfolio, keyword()}
          | {:init, Path.t(), keyword()}
          | {:install_skill, keyword()}
          | {:install_hooks, keyword()}
          | {:mcp, keyword()}
          | {:dashboard, keyword()}
          | {:daemon, String.t(), [String.t()], keyword()}
          | {:bus, String.t(), [String.t()], keyword()}
          | {:bus_help, String.t()}
          | {:propose, String.t(), keyword()}
          | {:plan_render, Path.t(), keyword()}
          | {:list_proposed, keyword()}
          | {:approve, String.t(), keyword()}
          | {:reject, String.t(), keyword()}
          | {:export, Path.t(), keyword()}
          | {:lint, Path.t(), keyword()}
          | {:spec_import, [Path.t()], keyword()}
          | {:context, String.t(), [String.t()], keyword()}
          | {:memory, String.t(), [String.t()], keyword()}
          | {:economy, keyword()}
          | {:error, String.t()}

  @doc """
  Parses `argv` into a command. Exposed for unit testing the argument boundary.

  Returns one of:

    * `{:help, opts}` — `--help` was requested.
    * `{:run, goal_file, opts}` — the `apply` subcommand with its positional
      goal-file and `opts`
      (`[workspace: path | nil, env: name | nil, standing: boolean | nil,
      debrief: boolean | nil]`).
      `:env` is the T3.3d deploy-environment selector. `:standing` is `nil` when
      `--standing` was not given (the goal-file's own `standing` field then
      decides); `true` forces standing mode (T3.4d). `:debrief` is `nil` when
      `--debrief` was not given (the goal-file's own `[economy] debrief` field
      then decides); `true` forces debrief capture on (T48.11, ADR-0058 §3).
    * `{:propose, idea, opts}` — the `plan` subcommand (T3.5c) with its
      positional prose idea and `opts` (`[workspace: path | nil]`).
    * `{:plan_render, roadmap, opts}` — the `plan render <roadmap>` subcommand
      (T45.5, UC-059) with `opts` (`[out: path | nil]`, the optional file target).
    * `{:list_proposed, opts}` — the `list-proposed` subcommand with `opts`
      (`[status: state | nil]`, an optional lifecycle-state filter).
    * `{:approve, proposal_ref, opts}` / `{:reject, proposal_ref, opts}` — the
      approval transitions over a proposal's review handle (T3.5b); `opts` carries
      `[json: boolean]` (T15.6, ADR-0023 decision 2).
    * `{:economy, opts}` — the `economy` subcommand (T48.8, ADR-0058) with
      `opts` (`[goal: goal_ref | nil, json: boolean]`, an optional goal_ref
      filter over the aggregated run-economics history).
    * `{:error, message}` — a usage error (unknown command, missing goal-file).
  """
  @spec parse([String.t()]) :: parsed()
  def parse(argv) when is_list(argv) do
    # The `strict:` switch table and `aliases:` are the `@switches`/`@aliases`
    # data structures (the single source of truth `help --json` also reads, T16.1),
    # so a flag is declared exactly once and the documented surface cannot drift
    # from what the parser actually recognizes.
    #
    # T21.8 (ADR-0027): `--parallel` is a BOOLEAN trigger, but its public form takes
    # an OPTIONAL integer — `--parallel [N]`. A bare integer immediately after
    # `--parallel` is rewritten to the internal `--parallelism N` switch so both
    # `--parallel` and `--parallel 4` parse (and `4` is never mistaken for a stray
    # positional). The user-facing flag stays `--parallel`; `--parallelism` is the
    # internal carrier of its optional value.
    {flags, positionals, invalid} =
      OptionParser.parse(normalize_parallel(argv), strict: @switches, aliases: @aliases)

    cond do
      # #1060: `kazi bus <verb> --help` prints that VERB's own usage (signature +
      # flags + enumerated kinds), not the generic block below -- intercepted
      # here, ahead of the generic `flags[:help]` branch, since `--help` sets
      # `flags[:help]` regardless of its position in argv.
      flags[:help] && match?(["bus", verb | _] when verb in @bus_verbs, positionals) ->
        {:bus_help, Enum.at(positionals, 1)}

      flags[:help] ->
        {:help, flags}

      flags[:version] ->
        {:version, flags}

      invalid != [] ->
        {:error, "unknown option #{format_invalid(invalid)}"}

      true ->
        parse_command(positionals, flags)
    end
  end

  # T21.8: rewrite `--parallel N` (N a bare integer) to `--parallel --parallelism N`
  # so the boolean `--parallel` trigger keeps its optional integer form without N
  # leaking into the positionals. A lone `--parallel` (no following integer) is left
  # untouched. Only the FIRST integer immediately after `--parallel` is consumed.
  defp normalize_parallel(argv) do
    Enum.flat_map_reduce(argv, false, fn
      "--parallel", _prev_parallel? ->
        {["--parallel"], true}

      token, true ->
        case Integer.parse(token) do
          {_n, ""} -> {["--parallelism", token], false}
          _ -> {[token], false}
        end

      token, false ->
        {[token], false}
    end)
    |> elem(0)
  end

  # T27.1/T27.9 (ADR-0032): `apply` is the ONLY convergence verb (the deprecated
  # `run` alias was removed in v0.6.0). It parses to the `{:run, ...}` tuple — the
  # internal handler name is unchanged; only the user-facing verb is `apply`.
  defp parse_command(["apply", goal_file | rest], flags),
    do: parse_run(goal_file, rest, flags)

  defp parse_command(["apply"], _flags),
    do: {:error, "the `apply` command requires a <goal-file> argument"}

  # T16.1 (ADR-0024 decision 2): `kazi help` is the positional form of `--help`
  # (the leading `--help` flag is already handled in `parse/1`). Under --json it
  # emits the command/flag surface — derived from the command table — so any agent
  # can introspect kazi at runtime.
  defp parse_command(["help" | rest], flags) do
    case rest do
      [] -> {:help, json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # `kazi version` is the positional form of `--version`/`-v` (the leading flag is
  # already handled in `parse/1`). Listed in the command table so `help --json`
  # reports it; dispatched here so the table stays honest (the coherence guard
  # T16.4 fails if a listed command is not really dispatched).
  defp parse_command(["version" | rest], flags) do
    case rest do
      [] -> {:version, flags}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T16.1 (ADR-0024 decision 2): `kazi schema [<command>]` emits the versioned
  # result schema(s) for `--json` output (the schemas under docs/schemas/). With a
  # command it emits that command's schema; with none it emits all of them. The
  # optional positional <command> is the command whose schema to return.
  defp parse_command(["schema" | rest], flags) do
    case rest do
      [] -> {:schema, nil, json: flags[:json] || false}
      [command] -> {:schema, command, json: flags[:json] || false}
      [_ | extra] -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T15.5 (ADR-0023 decision 2): `status <ref>` reports a run/proposal's current
  # state from the read-model. The positional <ref> is a goal_ref (a run's goal
  # id) or a proposal_ref; --json switches to the machine surface.
  defp parse_command(["status", ref | rest], flags) do
    case rest do
      [] -> {:status, ref, json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # Issue #971: `status` with NO ref is the pre-upgrade check — list every
  # currently LIVE run (see `execute_status/2`'s nil-ref branch) rather than
  # erroring, so an operator can run this before installing a newer
  # burrito-built binary.
  defp parse_command(["status"], flags),
    do: {:status, nil, json: flags[:json] || false}

  # Issue #1073/#857: `kazi orphans` lists runs whose recorded harness child pid
  # is STILL alive -- a dispatch that outlived its controller. Read-only by
  # default; `--reap` TERM/KILLs each orphaned process group.
  defp parse_command(["orphans" | rest], flags) do
    case rest do
      [] -> {:orphans, reap: flags[:reap] || false, json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T60.4 (#1160): `kazi portfolio` -- the fleet's planned/in-progress/stuck/
  # complete state, grouped by repo. No args; --json is the only flag.
  defp parse_command(["portfolio" | rest], flags) do
    case rest do
      [] -> {:portfolio, json: flags[:json] || false, full: flags[:full] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T5.5 adopt: `kazi init <repo-dir>` reverse-engineers a starter goal-file by
  # deterministic stack detection (ADR-0013). --out is the output file; --enrich
  # opts into harness enrichment (off by default); --with-mcp also writes the
  # canonical kazi MCP client config to the repo's .mcp.json (T33.3, ADR-0044);
  # --with-gist opts the repo into the Gist context store (T35.8, ADR-0045).
  defp parse_command(["init", repo_dir | rest], flags) do
    case rest do
      [] ->
        {:init, repo_dir,
         out: flags[:out],
         discover: flags[:discover],
         enrich: flags[:enrich],
         with_mcp: flags[:with_mcp],
         with_gist: flags[:with_gist],
         workspace: flags[:workspace]}

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["init"], _flags),
    do: {:error, "the `init` command requires a <repo-dir> argument"}

  # T16.2 (ADR-0024 decision 1): `kazi install-skill` writes the kazi Claude Code
  # skill so an orchestrating agent already knows the plan → approve → apply
  # recipe. OPT-IN/consent-first — only this explicit command writes, and only
  # under `--dir` (a tmp dir in tests) or the default ~/.claude/skills/kazi. A
  # normal `kazi` run never touches ~/.claude.
  defp parse_command(["install-skill" | rest], flags) do
    case rest do
      [] -> {:install_skill, dir: flags[:dir]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T55.2 (ADR-0071 decisions 1/3/6): `kazi install-hooks` registers the
  # session-bus delivery hooks (SessionStart + UserPromptSubmit -> `kazi bus
  # hook <event>`) in the Claude Code settings. OPT-IN/consent-first, the same
  # contract as `install-skill`: only this explicit command writes harness
  # config; a normal `kazi` run never touches it. `--dir` targets a tmp dir in
  # tests; `--local` targets the LOCAL (uncommitted) settings.local.json;
  # `--uninstall` removes exactly what an install added.
  defp parse_command(["install-hooks" | rest], flags) do
    case rest do
      [] ->
        {:install_hooks,
         dir: flags[:dir], project: flags[:local] || false, uninstall: flags[:uninstall] || false}

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T33.1 (ADR-0044): `kazi mcp` starts the MCP server over stdio — the SAME
  # `Kazi.MCP.Server` that `mix kazi.mcp` starts, shared via `Kazi.MCP.Stdio`.
  # It is a long-running stdio server, NOT a `--json` command: it takes no flags
  # and reads line-delimited JSON-RPC from stdin, so any extra argument is a usage
  # error.
  defp parse_command(["mcp" | rest], _flags) do
    case rest do
      [] -> {:mcp, []}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T46.4 (ADR-0057): `kazi dashboard` boots the standalone fleet-mode web
  # endpoint (mission control) with NO goal loop in the process — a read-only
  # projection over the shared read-model + run registry. `--port`/`--bind`
  # (and, as of T47.2, `--roadmap`) only take effect on a FRESH boot of the
  # endpoint (a dev/test process that already supervises it keeps its existing
  # bind; see `execute_dashboard/2`).
  defp parse_command(["dashboard" | rest], flags) do
    case rest do
      [] -> {:dashboard, port: flags[:port], bind: flags[:bind], roadmap: flags[:roadmap]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T51.1 (ADR-0067 decision point 1): `kazi daemon start|stop|status` -- the
  # long-lived per-machine daemon's lifecycle, over its Unix-socket control
  # plane. Wired like `dashboard`/`memory` above: a required subcommand, no
  # positional args beyond it, `--json` carried through.
  defp parse_command(["daemon" | rest], flags), do: parse_daemon(rest, flags)
  defp parse_command(["bus" | rest], flags), do: parse_bus(rest, flags)

  # T3.5c authoring: `plan "<idea>"` drafts a goal from a prose idea. The idea
  # is a single positional argument (quote it in the shell); only --workspace is
  # carried through (where the harness drafts the goal).
  # T15.2 (ADR-0023 decision 4): in caller-drafts mode the predicates are supplied
  # (--predicates / stdin) so the positional idea is OPTIONAL — `kazi plan
  # --json` with predicates and no idea is the orchestrator's entry point.
  # T27.1/T27.9 (ADR-0032): `plan` is the ONLY authoring verb (the deprecated
  # `propose` alias was removed in v0.6.0). It parses to the `{:propose, ...}`
  # tuple — the internal handler name is unchanged; only the verb is `plan`.
  #
  # T45.5 (ADR-0075, UC-059): `plan render <roadmap>` is a SUBCOMMAND of `plan`
  # (not a new verb — the help-json command set stays `plan`), matched before the
  # authoring form so the `render` token is never mistaken for a prose idea. It
  # renders the roadmap DAG as a generated markdown plan to stdout (or --out).
  defp parse_command(["plan", "render", roadmap | rest], flags) do
    case rest do
      [] -> {:plan_render, roadmap, out: flags[:out]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["plan", "render"], _flags),
    do: {:error, "the `plan render` command requires a <roadmap-file> argument"}

  defp parse_command(["plan" | rest], flags), do: parse_propose(rest, flags)

  # T3.5c authoring: `list-proposed` lists the proposal queue, optionally filtered
  # by --status (proposed / approved / rejected).
  # T15.6 (ADR-0023 decision 2): --json carries through so the queue emits as a
  # single JSON object an orchestrator drives the state machine on.
  defp parse_command(["list-proposed" | rest], flags) do
    case rest do
      [] -> {:list_proposed, status: flags[:status], json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T3.5c authoring: `approve <proposal-ref>` / `reject <proposal-ref>` drive the
  # T3.5b transitions over a proposal's review handle.
  # T15.6 (ADR-0023 decision 2): --json carries through so the transition reports a
  # machine-readable success/error.
  defp parse_command(["approve", proposal_ref | rest], flags),
    do: approval_command(:approve, proposal_ref, rest, flags)

  defp parse_command(["approve"], _flags),
    do: {:error, "the `approve` command requires a <proposal-ref> argument"}

  defp parse_command(["reject", proposal_ref | rest], flags),
    do: approval_command(:reject, proposal_ref, rest, flags)

  defp parse_command(["reject"], _flags),
    do: {:error, "the `reject` command requires a <proposal-ref> argument"}

  # T12.6 (ADR-0020 decision 5): `export <goal-file> --obsidian <dir>` loads the
  # goal-file, walks its group tree + predicate verdicts, and writes an Obsidian
  # vault to <dir>. --obsidian names the target directory (required); --json
  # switches to a machine-readable summary of what was written.
  defp parse_command(["export", goal_file | rest], flags) do
    case rest do
      [] -> {:export, goal_file, obsidian: flags[:obsidian], json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["export"], _flags),
    do: {:error, "the `export` command requires a <goal-file> argument"}

  # T12.7 (ADR-0020 decision 3, the second net): `lint <goal-file>` loads the
  # goal-file and fuzzy-warns on near-duplicate group NAMES. ADVISORY — it never
  # fails (exit 0 even with warnings); --json switches to a machine-readable list
  # of warnings.
  defp parse_command(["lint", goal_file | rest], flags) do
    case rest do
      [] -> {:lint, goal_file, json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["lint"], _flags),
    do: {:error, "the `lint` command requires a <goal-file> argument"}

  # T40.2 (ADR-0050): `spec import <feature-file>... --into <goal-file>` exposes
  # `Kazi.Reconcile.GherkinImporter` as a CLI entrypoint — the sub-verb shape
  # mirrors `context`/`memory`/`bus`. `--into` (the target goal-file) is required;
  # one or more `.feature` positionals follow the `import` sub-verb. --json carries
  # through so the upserted predicate ids emit as one object (ADR-0023).
  defp parse_command(["spec" | rest], flags), do: parse_spec(rest, flags)

  # T35.7 (ADR-0045): `context index|search|stats` — a THIN wrapper over the
  # `Kazi.ContextStore` provider so users learn one CLI (the provider stays
  # independently usable). The subcommand is a required positional; the remaining
  # positionals are the subcommand's own args (a label + file for index, a query
  # for search, none for stats). `--provider`/`--budget`/`--json` are carried
  # through to `execute_context/4`, which proxies to the resolved provider.
  defp parse_command(["context" | rest], flags), do: parse_context(rest, flags)

  defp parse_command(["memory" | rest], flags), do: parse_memory(rest, flags)

  # T48.8 (ADR-0058 decision 2 precursor) + T48.10 (ADR-0058 decision 3):
  # `economy [--goal <ref>] [--json]` aggregates the persisted run-end
  # economics (T48.7) into p50/p95 history groups; `economy --rediscovery
  # <goal> [--json]` instead folds the goal's recorded per-iteration tool
  # counters into a ranked, report-only rediscovery-pressure candidate list.
  # Both are pure reads over the same command -- no positional argument,
  # `--rediscovery` selects which view renders.
  defp parse_command(["economy" | rest], flags) do
    case rest do
      [] ->
        case flags[:rediscovery] do
          nil -> {:economy, goal: flags[:goal], json: flags[:json] || false}
          goal_ref -> {:economy, rediscovery: goal_ref, json: flags[:json] || false}
        end

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command([other | _], _flags),
    do:
      {:error,
       "unknown command #{inspect(other)} (try `apply`, `status`, `init`, `install-skill`, `install-hooks`, `mcp`, `dashboard`, `daemon`, `bus`, `plan`, `list-proposed`, `approve`, `reject`, `export`, `lint`, `context`, `economy`, `schema`, or `help`)"}

  defp parse_command([], _flags),
    do: {:error, "no command given (expected `apply <goal-file> --workspace <path>`)"}

  # The `context` parse body. The subcommand (index / search / stats) is required;
  # an unknown one is a clear usage error (NOT an "unknown command", which would
  # mis-hint at the top-level verbs). The remaining positionals stay as the
  # subcommand's own args — validated in `execute_context/4`, where the surface
  # (a JSON error envelope under --json) is consistent with the other commands.
  @context_subcommands ~w(index search stats)

  defp parse_context([sub | rest], flags) when sub in @context_subcommands,
    do: {:context, sub, rest, context_flags(flags)}

  defp parse_context([sub | _], _flags),
    do:
      {:error,
       "unknown context subcommand #{inspect(sub)} (expected `index`, `search`, or `stats`)"}

  defp parse_context([], _flags),
    do: {:error, "the `context` command requires a <subcommand> (`index`, `search`, or `stats`)"}

  # The flag bundle the `context` subcommands share: the provider selector
  # (default `gist`), the search byte budget, and the machine-surface toggle.
  defp context_flags(flags) do
    [
      provider: flags[:provider] || "gist",
      budget: flags[:budget],
      json: flags[:json] || false
    ]
  end

  # ADR-0062 (`recall`) + ADR-0063 Slice 3 (`list-proposed` / `approve` /
  # `reject`, the gated-harvest promotion verbs): the `memory` parse body.
  # An unknown subcommand is a clear usage error, not the top-level
  # "unknown command".
  defp parse_memory(["recall" | rest], flags), do: {:memory, "recall", rest, memory_flags(flags)}

  defp parse_memory(["list-proposed" | rest], flags) do
    case rest do
      [] -> {:memory, "list-proposed", [], status: flags[:status], json: flags[:json] || false}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_memory([sub, proposal_ref | rest], flags) when sub in ~w(approve reject) do
    case rest do
      [] -> {:memory, sub, [proposal_ref], memory_flags(flags)}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_memory([sub], _flags) when sub in ~w(approve reject),
    do: {:error, "the `memory #{sub}` command requires a <proposal-ref> argument"}

  defp parse_memory([sub | _], _flags),
    do:
      {:error,
       "unknown memory subcommand #{inspect(sub)} " <>
         "(expected `recall`, `list-proposed`, `approve`, or `reject`)"}

  defp parse_memory([], _flags),
    do:
      {:error,
       "the `memory` command requires a <subcommand> (`recall`, `list-proposed`, `approve`, `reject`)"}

  # T40.2 (ADR-0050): the `spec` parse body. Only `import` is implemented; it
  # requires `--into <goal-file>` and one or more `.feature` positionals. An
  # unknown sub-verb or a missing `--into`/feature file is a clear usage error.
  defp parse_spec(["import" | paths], flags) do
    into = flags[:into]

    cond do
      into in [nil, ""] ->
        {:error, "the `spec import` command requires --into <goal-file>"}

      paths == [] ->
        {:error, "the `spec import` command requires at least one <feature-file>"}

      true ->
        case parse_lower(flags[:lower]) do
          {:ok, lower} ->
            {:spec_import, paths, into: into, lower: lower, json: flags[:json] || false}

          {:error, message} ->
            {:error, message}
        end
    end
  end

  defp parse_spec([sub | _], _flags),
    do: {:error, "unknown spec subcommand #{inspect(sub)} (expected `import`)"}

  defp parse_spec([], _flags),
    do: {:error, "the `spec` command requires a <subcommand> (`import`)"}

  # The `--lower` flag value → the importer's `:lower` mode atom. Absent defaults
  # to `:test_runner` (byte-identical to a pre-lowering import). Only the two
  # documented modes are accepted; an unknown value is a clear usage error rather
  # than a silent fall-through to the default (T49.11, ADR-0054 d3).
  defp parse_lower(nil), do: {:ok, :test_runner}
  defp parse_lower("test_runner"), do: {:ok, :test_runner}
  defp parse_lower("scenario"), do: {:ok, :scenario}

  defp parse_lower(other),
    do: {:error, "unknown --lower mode #{inspect(other)} (expected `test_runner` or `scenario`)"}

  defp memory_flags(flags) do
    [
      workspace: flags[:workspace] || ".",
      budget: flags[:budget],
      json: flags[:json] || false
    ]
  end

  # T51.1: `daemon start|stop|status [--json]`; T52.4 adds `restart`
  # (stop-then-start, the operator's one-command schema-skew remedy, ADR-0068
  # point 2). No positional args beyond the subcommand.
  @daemon_subcommands ~w(start stop status restart)

  defp parse_daemon([sub | rest], flags) when sub in @daemon_subcommands do
    case rest do
      [] ->
        {:daemon, sub, [],
         json: flags[:json] || false,
         nats_bin: flags[:nats_bin],
         nats_port: flags[:nats_port],
         nats_host: flags[:nats_host],
         nats_token: flags[:nats_token] || System.get_env("KAZI_NATS_TOKEN")}

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_daemon([sub | _], _flags),
    do:
      {:error,
       "unknown daemon subcommand #{inspect(sub)} (expected `start`, `stop`, `status`, or `restart`)"}

  defp parse_daemon([], _flags),
    do:
      {:error,
       "the `daemon` command requires a <subcommand> (`start`, `stop`, `status`, `restart`)"}

  # T51.2 (ADR-0067 decision point 4)/#1060: `bus post|read|peek|who|tell` --
  # `post`/`tell` take a required positional (kind+text, or session+text);
  # `read`/`peek`/`who` take none. Validated further in `execute_bus/3` (arg
  # counts differ per verb; `post`'s <kind> is validated/defaulted there too).
  defp parse_bus([sub | rest], flags) when sub in @bus_verbs,
    do: {:bus, sub, rest, bus_flags(flags)}

  defp parse_bus([sub | _], _flags),
    do:
      {:error,
       "unknown bus subcommand #{inspect(sub)} (expected `post`, `read`, `peek`, `who`, `board`, `tell`, `status`, `get`, `watch`, `join`, `leave`, `name`, `hook`)"}

  defp parse_bus([], _flags),
    do:
      {:error,
       "the `bus` command requires a <subcommand> (`post`, `read`, `peek`, `who`, `board`, `tell`, `status`, `get`, `watch`, `join`, `leave`, `name`, `hook`)"}

  defp bus_flags(flags) do
    [
      json: flags[:json] || false,
      topic: flags[:topic],
      sev: flags[:sev] || "info",
      scope: flags[:scope] || "machine",
      peek: flags[:peek] || false,
      full: flags[:full] || false,
      team: flags[:team],
      all: flags[:all] || false,
      project: flags[:project],
      machine: flags[:machine],
      timeout: flags[:timeout],
      since: flags[:since],
      # T55.5: an explicit --session-name heads the sender-identity resolution
      # chain (ADR-0067 point 2) for every bus verb.
      session_name: flags[:session_name],
      # T60.3: `bus board` only -- trims the HUMAN render to the NEEDS
      # OPERATOR section; --json is unaffected (bus_flags is shared across
      # every verb, so this is simply ignored by every other verb).
      attention: flags[:attention] || false
    ]
  end

  # #1060: the one-line usage error for an explicit, unrecognized `bus post` kind
  # -- enumerates the valid kinds so the failure is self-documenting.
  @spec unknown_bus_kind_error(String.t()) :: String.t()
  defp unknown_bus_kind_error(kind),
    do:
      "unknown bus kind #{inspect(kind)} (expected one of: #{Enum.join(@bus_kinds, ", ")}; omit <kind> to default to #{@default_bus_kind})"

  # #1060: per-verb `bus <verb> --help` usage text -- the single source both
  # `run/2`'s `{:bus_help, verb}` branch and `docs/session-bus.md` describe.
  @spec bus_help_text(String.t()) :: String.t()
  defp bus_help_text("post") do
    """
    kazi bus post [<kind>] <text> [--topic <t>] [--sev info|interrupt] [--scope machine|project] [--json]

    Publish `text` to the session bus. <kind> is OPTIONAL and defaults to
    `#{@default_bus_kind}`; an explicit <kind> must be one of: #{Enum.join(@bus_kinds, ", ")}.
    Directed sends use `bus tell` (kind `msg` is reserved). `text` over 1024
    bytes is rejected client-side before any daemon connection is attempted.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("tell") do
    """
    kazi bus tell <session>|<nickname>|@<team> <text> [--sev info|interrupt] [--scope machine|project] [--json]

    Publish `text` directed at a recipient -- only that session's `bus read`/
    `bus peek`/`bus watch` sees it, regardless of either side's --scope (issue
    #1065). The recipient resolves in order (T55.5, ADR-0073): an @-prefixed
    team name (every member receives it, issue #1069), an exact session id on
    the roster, then a nickname assigned with `bus name`. `text` over 64 KiB is
    rejected client-side.

    Prints the message's id (T55.12) -- `bus status <id>` answers what became
    of it. Success here means STORED AND QUEUED, not seen: the bus is
    advisory, and a live recipient is always free to ignore a message.

    Unaddressable and unlikely-to-be-read recipients differ (T55.12):

      * no presence row AND no durable inbox -- a one-line ERROR naming the
        live roster; nothing is sent.
      * a row whose liveness is `dead-reaping` (T55.11), or no row but a
        durable inbox left over from before it aged out -- a WARNING on
        stderr, and the message is queued anyway. The verdict comes from the
        recipient's machine sweep, and the operator may know better (a session
        restarting under the same name); refusing here would trade a silent
        send for a silent refusal. Confirm with `bus status <id>`.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("status") do
    """
    kazi bus status <id> [--json]

    Answer what became of the directed message `<id>` (the id `bus tell`
    prints) -- read from the RECIPIENT's durable consumer ack state (T55.12):

      * `pending` -- stored and queued, but not acked: the recipient has not
        read yet, or only peeked (a peek never consumes).
      * `consumed` -- the recipient's `bus read` acked it. Delivered AND
        drained, which is as far as the bus can honestly see; whether the
        session acted on it is not something an ack can know.

    For a `tell @<team>` fan-out, `recipients` breaks the verdict out per
    member and the top-line state is `consumed` only once EVERY live member
    acked. Consumes nothing -- checking a message's status never disturbs the
    recipient's cursor, so it is safe to poll.

    An id that is not in the stream (never posted, or aged out of the 30-day
    retention) is a one-line error, as is an id naming a broadcast `bus post`
    -- delivery status needs one recipient whose ack state can answer for it.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("get") do
    """
    kazi bus get <id> [--full] [--json]

    Fetch the FULL body of the message `<id>` (the JetStream stream sequence a
    digest line or stub carries) -- the deliberate pull for a stubbed body
    (T55.6, ADR-0072 decision 3). When the digest collapses a large body into a
    one-line stub, this is how a session that has decided the body is worth the
    context spends it, on purpose.

    A direct stream GET by id -- NO consumer, so `get` consumes NOTHING and
    never advances anyone's read cursor: a subsequent `bus read` still delivers
    that same message normally. Contrast `bus read`, which acks and consumes.

    Prints the message's id/kind/topic/size header, then its body. By default
    the body is bounded to a cheap 1024-byte preview (the same threshold that
    stubbed it); `--full` prints it unabridged. Under --json the result is a
    versioned envelope `{ok, schema_version, message: {id, scope, kind, topic,
    sev, session, machine, ts, bytes, text, truncated}}` (`truncated` is true
    when the default preview cut the body; `--full` returns the whole `text`).

    An id that is not in the stream (never posted, or aged out of the 30-day
    retention) is a one-line error, never a crash.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("read") do
    """
    kazi bus read [--peek] [--full] [--since <cursor>] [--json]

    Pull and ACK this session's durable consumer -- prints a digest. The
    DAEMON assembles that digest (T55.7, ADR-0072 d5): it pulls the consumer,
    aggregates, and enforces the bound server-side, so the CLI, the MCP tools,
    and the installed hook all render the same bytes and a deep backlog costs
    the same as a shallow one.

    Under --json the SAME digest is the default (T55.1, ADR-0072), as a
    versioned envelope (schema_version; shape via `kazi schema bus`): verbatim
    lines only for directed (kind `msg`) and `sev: interrupt` messages,
    one-line stubs for bodies over the 1024-byte render threshold (ALL kinds
    -- the body stays in the stream, addressable by its `id`), exact count
    lines per {kind, topic} for everything else -- carrying the LAST value for
    a `fact` topic, since a fact states what is true now -- bounded to 40
    lines regardless of backlog size. Every message and digest line carries
    the message's JetStream stream sequence as its public `id`.

    `--full` is the documented escape: every pending message unabridged. It is
    the one mode the daemon does not assemble (there is no digest to assemble,
    and its size is unbounded), so it reads the consumer directly.

    `--peek` (issue #1059) makes the read NON-DESTRUCTIVE: pending messages
    are shown but not consumed, so a subsequent `bus read`/`bus peek` still
    sees them. Equivalent to `bus peek`.

    `--since <cursor>` (T55.7) replays from a point: consume only messages
    whose `id` is past <cursor>, leaving everything at or before it pending
    for a later read. A debugging escape -- `<cursor>` is a numeric stream
    sequence (`now`/`all` are `bus watch` anchors and are not accepted here).

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("peek") do
    """
    kazi bus peek [--full] [--json]

    Non-destructive read (issue #1059): shows this session's pending messages
    WITHOUT consuming them -- a subsequent `bus peek`/`bus read` still sees
    them. Equivalent to `bus read --peek`. Under --json it returns the same
    bounded digest envelope as `bus read` (T55.1, ADR-0072; shape via
    `kazi schema bus`); `--full` returns every message unabridged.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("who") do
    """
    kazi bus who [--team <name>] [--project <dir>] [--machine <host>] [--all] [--json]

    List current presence (session, machine, pid, liveness, team, inbox depth,
    last-seen age, cwd) from the short-TTL KV bucket every bus call upserts
    into.

    Inbox depth (T55.12): `inbox=N` counts the DIRECTED messages queued and
    un-read for that session (its own tells plus its team's fan-out) -- shown
    only when non-zero on the TTY, always present under --json. A depth that
    climbs against a live session means tells are landing but nobody is
    draining them; against a `dead-reaping` one, it is the backlog a
    replacement session will never see. Broadcast (`bus post`) traffic is not
    counted -- inbox answers "how many messages addressed to this session are
    waiting".

    Liveness (T55.11): `active` -- the session itself made a bus call
    recently; `idle` -- its process is verified alive on its machine but
    quiet (the daemon's presence sweep re-heartbeats such rows, so an alive
    session never ages out of the roster); `dead-reaping` -- its pid is
    verifiably gone or was reused by a different process (rows record pid +
    process start time), and the sweep removes the row on its next pass.

    Entries idle past the presence TTL (#{Kazi.Bus.session_ttl_s()} seconds)
    with no verifiably-alive process are hidden -- closed sessions age out
    instead of looking active; pass --all to include them. Under --json the
    result carries `ttl_s` and each session's `seen_s`.

    --team <name> filters to that team's members (issue #1069);
    --project <dir> filters to sessions whose cwd is <dir> or under it;
    --machine <host> filters to sessions on that machine.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("board") do
    """
    kazi bus board [--scope machine|project] [--attention] [--json]

    Render the CURRENT STATE of the bus (ADR-0073): the last-value `fact` per
    topic, the live roster (names, teams, liveness), and claim ownership in one
    shot. Where `read`/`peek`/`watch` answer "what CHANGED since I last looked"
    -- a delta of pending messages -- the board answers "what is true right now".

    CURSOR-FREE and idempotent: unlike `read`, the board CONSUMES NOTHING and
    keeps no cursor, so a session may call it every turn (it is what a
    session-start hook injects) without draining a message a later `read`/`watch`
    was counting on. Posting three facts on one topic shows ONE line -- the
    latest value, not three.

    Bounded by the same digest rules as `read` (ADR-0072): an oversize fact body
    renders as a one-line stub carrying its id (the body stays addressable in the
    stream), and the fact section is at most 40 lines regardless of topic count,
    the tail folding into one overflow line. Under --json: `{ok, schema_version,
    board: {facts, roster, claims, claims_available, total_facts,
    total_sessions, total_claims}}` (shape: `kazi schema bus`).

    The `claims` section (T55.8, ADR-0073 point 2) is a live projection of
    `refs/claims/*` read at source -- `{task, owner, host, age_s}` per claim,
    with NO daemon in that path. When the claim remote is unreachable it degrades
    to one honest line ("claims: unavailable (remote unreachable)",
    `claims_available:false` under --json) rather than a possibly-stale table.

    --scope machine (default) or project selects which bus subject tree to
    project. The facts and roster need a running `kazi daemon` -- `bus board`
    prints a one-line no-daemon error (exit 1) otherwise.

    NEEDS OPERATOR (T60.3, issue #1156): the same fact section also surfaces a
    fleet-wide attention view -- any session whose `Notification` hook fired
    (a harness blocked on a human) has a `waiting-on-operator: <summary>
    (since <ts>)` fact on its own `attention-<session>` topic, and the SAME
    session's `turn` hook clears it (posts `"none"`) on its very next prompt,
    so a resumed session drops out again automatically. Under --json this is
    always present as `board.attention` (oldest-waiting first) and
    `board.total_attention`, alongside the unchanged `facts`/`roster`. --attention
    trims the HUMAN render to ONLY this section (--json is unaffected -- the
    full board is always returned).
    """
  end

  defp bus_help_text("watch") do
    """
    kazi bus watch [--timeout <seconds>] [--since <seq|now|all>] [--full] [--json]

    Block until a NEW message arrives for this session, then consume and
    print it -- the no-poll-loop alternative to running `bus read` in a
    loop (issue #1091). The call sleeps on the session's scope, directed,
    and team subjects and wakes on the first arrival. Default timeout 300
    seconds; on expiry prints a one-line notice and exits 3, so scripts
    can always tell a timeout from an arrival. Under --json the result
    renders through the same bounded digest envelope as `bus read`
    (T55.1, ADR-0072); `--full` returns the messages unabridged.

    --since anchors what counts as new (T54.9, issue #1097):
      now   (default) only messages posted AFTER the watch starts; any
            backlog already pending (e.g. shown by an earlier `bus peek`)
            never satisfies the watch and stays consumable by
            `bus read`/`bus peek`.
      all   the drain-first behavior: anything already pending, backlog
            included, returns immediately.
      <seq> a numeric stream sequence to anchor at precisely -- pending
            messages with a greater sequence return immediately.

    Watching also refreshes this session's presence, so a watcher never
    ages out of `bus who`.

    The wake contract (T55.13): an IDLE session has no turn boundary to
    deliver into, so park this verb as a BACKGROUND TASK of your harness --
    arrival (exit 0) wakes the session with the message already in hand,
    timeout (exit 3) means re-park. Keep the `--since now` default: with
    `--since all` a park fires instantly on backlog and degenerates into
    the poll loop this verb exists to replace. Full contract, and when to
    use harness-native agent teams instead: `docs/session-bus.md`.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("join") do
    """
    kazi bus join [--json]                # derive the team from git origin
    kazi bus join -- <team> [--json]      # explicit team (cross-repo override)

    Register this session under a team. ARGLESS (T65.1, #1430): the team is
    DERIVED from the workspace's `git remote get-url origin` -- ssh/https/scp
    forms of one repo normalize to a single `t-<host>-<org>-<repo>` slug, so
    two checkouts (or machines) of the same repo land in the SAME team with no
    typed string. The fixed `t-` prefix means a team slug can never begin with
    `-`. With no origin remote the team falls back to the repo-root path slug
    (still `t-` prefixed) with a one-line machine-local notice.

    An explicit `bus join -- <team>` still works verbatim (existing teams keep
    functioning) and is recorded `derived=false` -- the deliberate cross-repo
    override. `bus who --team <team>` lists members and `bus tell @<team>
    <text>` reaches every member's read/peek/watch. Membership survives across
    bus calls and ages out with presence (rejoin after long idles); `bus
    leave` clears it.

    DAEMON-ASSIGNED NAME (T65.3, #1430): join also assigns this session its
    next-free short name for the team (`<team>-a`, `<team>-b`, ... in order) and
    prints it (`joined <team> as <team>-a`), so the session's name comes from the
    join output. The allocation is ATOMIC through the KV bucket (create-if-absent
    optimistic concurrency), so concurrent joiners never receive the same name. A
    re-join is idempotent and returns the SAME assigned name. Attach extra
    human aliases on top with `bus name <alias>`.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("leave") do
    """
    kazi bus leave [--json]

    Clear this session's team membership (issue #1069). Presence itself
    remains until its TTL lapses.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  defp bus_help_text("name") do
    """
    kazi bus name <alias> [--json]

    Bind a durable, addressable name to this session's UUID (T55.5, ADR-0073;
    durable bindings T65.2, #1430): carried on presence across every later bus
    call, rendered by `bus who`, accepted by `bus tell <alias>`, and stored
    in a TTL-less KV bucket so the binding SURVIVES a daemon restart (names no
    longer drop back to raw UUIDs on a bounce).

    ATTACHES an alias on top of any daemon-assigned name (T65.3, #1430): when the
    session already has an assigned name from `bus join`, THAT stays canonical in
    `bus who` and the alias is an additional resolvable name; both reach the
    session via `bus tell`. A session that never joined takes the alias as its
    presence label directly.

    Identity is the UUID; the name is a unique label bound to it. A rename
    updates the one presence row (never a second). Binding a name already held
    by a DIFFERENT session is a hard error naming the holder -- names are never
    silently stolen; re-binding your OWN name is idempotent.

    RENAME with a grace window (T65.4, #1430): when this changes the session's
    presence label, the OLD name lingers as a resolvable tombstone-alias for a
    bounded window (default 10 minutes, `config :kazi, :bus_rename_grace_s`). An
    in-flight `bus tell <old-name>` inside the window still lands on the session
    and the sender's ack notes the rename with the current name; after the window
    the old name errors, naming the current name as a hint. (Attaching an alias
    to an assigned-name session does NOT change the label, so it tombstones
    nothing -- the old name stays live.)

    A nickname cannot be empty, contain whitespace, start with `@` (reserved
    for teams), or equal a different live session's id.

    Prefer setting the name at launch when you can: the resolution chain is
    `--session-name` > `KAZI_SESSION_NAME` > a harness-provided session env
    var > a stable fallback id, so `KAZI_SESSION_NAME=<role> <harness>`
    names every kazi invocation in the session with no per-session setup.

    Requires a running `kazi daemon` -- prints a one-line no-daemon error
    (exit 1) otherwise.
    """
  end

  # T55.2 (ADR-0071 decision 2): the harness hook entry point install-hooks
  # registers. The --help text is the ONE place the events are documented on
  # the CLI surface itself -- the command's own contract is silence.
  defp bus_help_text("hook") do
    """
    kazi bus hook <event>

    The harness hook entry point `kazi install-hooks` registers (ADR-0071,
    T60.3). Events: `session-start` (Claude Code's SessionStart -- registers
    presence, joins the project-scope team, and injects the current board),
    `turn` (Claude Code's UserPromptSubmit -- injects the bounded digest of
    traffic since the session's last turn, COMPLETELY SILENT when the bus is
    quiet, and clears this session's attention fact every turn), and
    `notification` (Claude Code's Notification, T60.3/issue #1156 -- posts a
    `waiting-on-operator` fact on this session's attention topic when the
    harness blocks on a human; NEVER injects anything, so it is exempt from
    the binding rule below by construction -- see `bus board --attention` and
    docs/session-bus.md).

    Contract: ALWAYS exits 0 and never blocks a session. With no daemon
    running, or an unknown/missing <event>, it prints nothing and returns
    immediately. A hard ~2s wall-clock bound applies even to a HUNG daemon --
    a slow or stalled daemon can never tax or break a turn. Injected content
    is framed as UNTRUSTED, provenance-stamped, advisory external input, never
    a command channel (ADR-0067 point 7).
    """
  end

  # T39.3 (ADR-0049): `approve --write <path>` materializes the approved goal to a
  # loadable goal-file. Scoped to `approve` — `reject` never writes a goal-file.
  defp approval_command(:approve, proposal_ref, [], flags),
    do: {:approve, proposal_ref, json: flags[:json] || false, write: flags[:write]}

  defp approval_command(command, proposal_ref, [], flags),
    do: {command, proposal_ref, json: flags[:json] || false}

  defp approval_command(_command, _proposal_ref, extra, _flags),
    do: {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}

  # The `apply` parse body (parses to the internal `{:run, ...}` tuple).
  defp parse_run(goal_file, rest, flags) do
    case rest do
      # T3.3d deploy wiring: carry the optional --env selector alongside workspace.
      # T3.4d standing wiring: carry the --standing flag through to the run.
      # T8.7 harness wiring: carry --harness/--model through to the resolved adapter.
      [] ->
        {
          :run,
          goal_file,
          # T15.3 (ADR-0023 decision 2): --json switches `apply` to its machine
          # surface — the versioned result contract instead of the human report.
          # T15.4 (ADR-0023 decision 3): --stream emits the JSONL progress stream
          # (one event per iteration) before the final run-result object. Only
          # meaningful under --json.
          # T21.8 (ADR-0027): --parallel routes `apply` to the parallel scheduler;
          # the optional --parallel N records a concurrency hint (:parallelism).
          # T23.6 (ADR-0028): --explain / --dry-run is the PURE PLANNING surface —
          # print the computed wave schedule and dispatch NOTHING. The two spellings
          # are aliases; either sets :explain so the surface is one branch.
          # T36.6 (ADR-0047): the Claude-only reasoning-effort lever, threaded the
          # same way --model is. Forwarded to Kazi.Runtime, which folds it into
          # adapter_opts (CLI > goal-file [harness] effort) for the claude profile.
          # (issue #769): --permission-mode / --allowed-tools, threaded the same
          # way, so a headless claude dispatch against an untrusted workspace can
          # be pre-authorized instead of getting every tool call silently denied.
          # T35.5 (ADR-0045 §8): --context-store/--context-budget must survive the
          # parse layer or maybe_put_context_store/2 never sees them — the store
          # silently stayed off (and an unknown name never warned, deep review L11).
          # (issue #805): --check is observe-only, checked in run_goal/4 before any
          # execution branch (see explain above).
          workspace: flags[:workspace],
          env: flags[:env],
          standing: flags[:standing],
          debrief: flags[:debrief],
          harness: flags[:harness],
          model: flags[:model],
          effort: flags[:effort],
          permission_mode: flags[:permission_mode],
          allowed_tools: flags[:allowed_tools],
          context_store: flags[:context_store],
          context_budget: flags[:context_budget],
          session_name: flags[:session_name],
          allow_primary_workspace: flags[:allow_primary_workspace] || false,
          allow_duplicate_run: flags[:allow_duplicate_run] || false,
          allow_workspace_collision: flags[:allow_workspace_collision] || false,
          no_preflight: flags[:no_preflight] || false,
          in_place: flags[:in_place] || false,
          base: flags[:base],
          strict_landing: flags[:strict_landing] || false,
          json: flags[:json] || false,
          stream: flags[:stream] || false,
          parallel: flags[:parallel] || false,
          parallelism: flags[:parallelism],
          explain: flags[:explain] || flags[:dry_run] || false,
          fleet: flags[:fleet] || false,
          fleet_concurrency: flags[:fleet_concurrency],
          pause_between_waves: flags[:pause_between_waves] || false,
          resume: flags[:resume],
          check: flags[:check] || false
        }

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # The `plan` parse body (parses to the internal `{:propose, ...}` tuple).
  # T15.2: with no positional idea, only caller-drafts mode is valid (predicates
  # supplied via --predicates / stdin under --json); otherwise the missing-idea
  # usage error stands, so the existing human surface is unchanged.
  defp parse_propose([idea | rest], flags) do
    case rest do
      [] -> {:propose, idea, propose_opts(flags)}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_propose([], flags) do
    if flags[:predicates] || flags[:json] do
      {:propose, "", propose_opts(flags)}
    else
      {:error, "the `plan` command requires an <idea> argument (quote it)"}
    end
  end

  # The shared option bundle for the `plan` subcommand (both modes).
  # T15.2: `:predicates` carries the caller-drafts payload; `:json` switches the
  # surface.
  defp propose_opts(flags) do
    [
      workspace: flags[:workspace],
      yes: flags[:yes] || false,
      strict: flags[:strict] || false,
      adr: flags[:adr] || false,
      json: flags[:json] || false,
      predicates: flags[:predicates],
      replace: flags[:replace] || false,
      discover: flags[:discover] || false,
      session_name: flags[:session_name],
      project: flags[:project]
    ]
  end

  # =============================================================================
  # JSON render seam (T15.1, ADR-0023 decision 1)
  # =============================================================================
  #
  # The machine surface is OPT-IN and additive: human-readable output stays the
  # DEFAULT; `--json` swaps a command to a single JSON object on stdout. The seam
  # is one helper so each command CAN emit JSON without re-deriving the branch —
  # `propose`/`run`/`status` grow their own schemas in T15.2/T15.3/T15.5, all on
  # this same `emit/3`. Exit codes are computed by the caller and stay stable
  # across `--json`; the renderer only chooses the OUTPUT shape, never the code.

  # Whether the parsed flags requested the machine surface. A boolean switch, so
  # absent (nil) and `--no-json` both mean human output (the default).
  @spec json?(keyword()) :: boolean()
  defp json?(flags), do: flags[:json] == true

  # T54.7 (#1076): the ONE JSON encoder for every `--json` write. `escape:
  # :unicode_safe` emits `\uXXXX` for every non-ASCII codepoint, so the output
  # is PURE ASCII and byte-identical regardless of the caller's locale. Plain
  # `Jason.encode!/1` is correct (raw UTF-8), but `IO.puts` on a latin1
  # `:standard_io` device (a non-UTF-8 locale, e.g. `env -i`) transcodes each
  # non-ASCII codepoint to the literal 7-char string `\x{2014}` -- invalid JSON.
  # Escaping to ASCII at the ENCODER sidesteps the IO device entirely (never
  # mutating the process-global `:io.setopts`, which would fight `env -i`).
  @spec encode_json!(term()) :: String.t()
  defp encode_json!(payload), do: Jason.encode!(payload, escape: :unicode_safe)

  # The render seam: under `--json` print exactly `encode_json!(payload)` and a
  # newline (a single JSON object, no human prose interleaved on stdout);
  # otherwise run `human_fun`, the command's existing human rendering. Returns
  # `:ok`; the caller owns the exit code.
  @spec emit(boolean(), map(), (-> any())) :: :ok
  defp emit(true, payload, _human_fun) when is_map(payload) do
    IO.puts(encode_json!(payload))
  end

  defp emit(false, _payload, human_fun) when is_function(human_fun, 0) do
    _ = human_fun.()
    :ok
  end

  # A clear, machine-readable error envelope on stdout for the NON-INTERACTIVE
  # guarantee: under `--json` a command that would otherwise prompt/block on stdin
  # emits this instead and the caller returns a non-zero exit. Keeping the error
  # on the SAME stdout stream as a success object means an orchestrator parses one
  # surface; the non-zero exit code is what it branches on.
  @spec emit_json_error(String.t()) :: :ok
  defp emit_json_error(message) when is_binary(message) do
    IO.puts(encode_json!(%{error: message, schema_version: @run_schema_version}))
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn {opt, _value} -> opt end)
  end

  # The kazi version, read from the loaded application spec (set from mix.exs at
  # build time). Works in the release and the escript (both embed the app spec);
  # falls back to "unknown" if the app is not loaded (it always is in practice).
  @spec version() :: String.t()
  defp version do
    case Application.spec(:kazi, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  # =============================================================================
  # help --json + schema (T16.1, ADR-0024 decision 2): kazi self-describes
  # =============================================================================
  #
  # `help --json` and `schema` are the machine-readable teachability surface: an
  # agent introspects the command/flag table and the versioned result schemas at
  # runtime, no external docs. `help --json` is GENERATED from the `@commands` /
  # `@switches` / `@flag_docs` data the parser also reads, so it can never drift
  # from the real surface (ADR-0024 consequences: "generated, not hand-maintained").

  # The full command/flag surface as a single JSON object (`help --json`). It walks
  # the command table, joining each command's flags against `@switches` (for the
  # type) and `@flag_docs` (for the description), so every command + flag the parser
  # recognizes is reported. `schema_version` ties it to the result-schema contract.
  @spec help_json() :: map()
  defp help_json do
    %{
      schema_version: @run_schema_version,
      kazi: version(),
      commands: Enum.map(@commands, &command_json/1)
    }
  end

  # T27.4 (ADR-0032): the command object carries `deprecated` (always present, a
  # boolean) and — for a deprecated alias — `alias_of` naming the primary verb it
  # forwards to, both read straight from the `@commands` table. As of v0.6.0 (T27.9)
  # no command is deprecated, so every command reports `deprecated: false` and omits
  # `alias_of`; the fields stay generated from the table so reintroducing an alias
  # needs no edit here.
  defp command_json(command) do
    base = %{
      name: command.name,
      summary: command.summary,
      deprecated: Map.get(command, :deprecated, false),
      args: Enum.map(command.args, &arg_json/1),
      flags: Enum.map(command.flags, &command_flag_json/1)
    }

    case Map.get(command, :alias_of) do
      nil -> base
      primary -> Map.put(base, :alias_of, primary)
    end
  end

  defp arg_json(arg), do: %{name: arg.name, required: arg.required}

  # One flag entry: its long name, type (from `@switches`, the parser's own table),
  # description (from `@flag_docs`), and aliases (e.g. -h for --help, from
  # `@aliases`). Joining against the parser's tables is what keeps the surface true.
  defp command_flag_json(flag) do
    %{
      name: "--#{flag |> to_string() |> String.replace("_", "-")}",
      type: to_string(Keyword.fetch!(@switches, flag)),
      description: Map.fetch!(@flag_docs, flag),
      aliases: flag_aliases(flag)
    }
  end

  defp flag_aliases(flag) do
    @aliases
    |> Enum.filter(fn {_alias, target} -> target == flag end)
    |> Enum.map(fn {alias_char, _target} -> "-#{alias_char}" end)
  end

  # `schema [<command>]` (T16.1): emit the versioned result schema(s) for `--json`
  # output. With a command, that command's schema; with none, every schema keyed by
  # command. An unknown command is a clear JSON error with a non-zero exit, so an
  # orchestrator branches on the exit code, never on prose. JSON-only by design.
  @spec execute_schema(String.t() | nil) :: exit_code()
  defp execute_schema(nil) do
    IO.puts(encode_json!(Kazi.CLI.Schema.all()))
    0
  end

  defp execute_schema(command) do
    case Kazi.CLI.Schema.fetch(command) do
      {:ok, schema} ->
        IO.puts(encode_json!(schema))
        0

      :error ->
        # T32.1 (ADR-0040): fall back to the predicate-provider config schemas
        # (`kazi schema custom_script`) before reporting an unknown command, so the
        # one `schema` surface self-describes both `--json` results AND provider
        # config keys. T45.1: the roadmap ARTIFACT shape (`kazi schema roadmap`)
        # is on the same surface.
        execute_artifact_schema(command)
    end
  end

  # T45.1 (ADR-0075): the roadmap artifact's input shape, on the same self-describing
  # `schema` surface as result and provider schemas. Any other command falls through
  # to the predicate-provider config schemas.
  defp execute_artifact_schema("roadmap") do
    IO.puts(encode_json!(Kazi.Goal.Roadmap.schema()))
    0
  end

  defp execute_artifact_schema(command), do: execute_provider_schema(command)

  # T32.1 (ADR-0040): emit a predicate-provider kind's config-key schema, or a
  # JSON error (preserving the "no result schema" marker the unknown-command tests
  # pin) listing both the result-schema commands and the provider kinds.
  @spec execute_provider_schema(String.t()) :: exit_code()
  defp execute_provider_schema(command) do
    case Kazi.Predicate.Schema.fetch(command) do
      {:ok, schema} ->
        IO.puts(encode_json!(schema))
        0

      :error ->
        emit_json_error(
          "no result schema for #{inspect(command)} " <>
            "(result schemas: #{Enum.join(Kazi.CLI.Schema.commands(), ", ")}; " <>
            "provider schemas: #{Enum.join(Kazi.Predicate.Schema.kinds(), ", ")}; " <>
            "artifact schemas: roadmap)"
        )

        1
    end
  end

  # =============================================================================
  # run command
  # =============================================================================

  # Boot the app + read-model, load the goal, run it, report. Returns the exit
  # code (never halts) so it stays testable.
  defp execute_run(goal_source, opts, runtime_opts) do
    cond do
      opts[:fleet] == true ->
        execute_fleet(goal_source, opts, runtime_opts)

      # T45.4 (ADR-0075): a positional roadmap artifact (a [[goals]] DAG) runs its
      # whole goals in topological `needs` frontiers one level up — the SAME
      # Kazi.Fleet.Execution scheduler the --fleet flag uses, but the DAG comes
      # from the roadmap's DECLARED `needs`, not goal-file metadata/scope overlap.
      # `roadmap_file?/1` peeks for a top-level [[goals]] array, so a proposal ref
      # or plain goal-file never routes here.
      roadmap_file?(goal_source) ->
        execute_roadmap(goal_source, opts, runtime_opts)

      true ->
        execute_single_run(goal_source, opts, runtime_opts)
    end
  end

  defp execute_single_run(goal_source, opts, runtime_opts) do
    persist? = ensure_read_model()

    case load_goal_source(goal_source, persist?) do
      {:ok, goal, proposal_ref, proposal_session_name} ->
        run_opts =
          opts
          |> maybe_put(:proposal_ref, proposal_ref)
          |> maybe_put(:proposal_session_name, proposal_session_name)
          # goal-drift-guard-1415: only a REAL goal-file path (never a proposal
          # ref, which has no on-disk bar to drift against) is worth threading
          # through to Kazi.Runtime.run/2's drift detector.
          |> maybe_put(:goal_source, if(proposal_ref == nil, do: goal_source))

        run_goal(goal, run_opts, persist?, runtime_opts)

      {:error, message} ->
        # M9 (deep-review-001): under --json this must still emit a JSON error
        # object on stdout (not just a human line to stderr), matching every
        # other --json command's `emit_json_error` convention -- an
        # orchestrator parsing stdout must never see an empty stream here.
        if json?(opts) do
          emit_json_error(message)
        else
          IO.puts(:stderr, "error: #{message}")
        end

        1
    end
  end

  # T50.4/T50.5 (ADR-0065 decision 3): `--fleet <dir|manifest>` loads a DAG of
  # goal-files instead of one goal (`Kazi.Fleet.load/1`). `--explain` prints
  # the fleet schedule and dispatches nothing; without it the fleet EXECUTES
  # through `Kazi.Fleet.Execution` (the partition scheduler one level up).
  defp execute_fleet(path, opts, runtime_opts) do
    case Fleet.load(path) do
      {:ok, fleet} ->
        cond do
          opts[:explain] == true ->
            explain_fleet(fleet, opts)

          # Fleet members ALWAYS run in their own task worktrees (isolation is
          # the fleet-level contract, ADR-0065); an in-place fleet would race
          # every member inside one checkout. Rejected loudly, like
          # --in-place + --base.
          opts[:in_place] == true ->
            fleet_error(
              "--fleet and --in-place are contradictory: every fleet member runs in " <>
                "its own kazi-owned task worktree off the shared base (ADR-0065 " <>
                "decision 3). Drop --in-place.",
              opts
            )

          true ->
            run_fleet(path, fleet, opts, runtime_opts)
        end

      {:error, message} ->
        fleet_error(message, opts)
    end
  end

  # Execute the fleet DAG (T50.5). The member seams (`:member_runner`,
  # `:supervisor`, `:reconcile_timeout`, `:on_frontier_complete`,
  # `:pause_between_waves`, `:resume_token`) pass through from `runtime_opts`
  # so the boundary test stays hermetic; everything else in `runtime_opts`
  # (adapter_opts, await_timeout, integrate seams, ...) is forwarded to each
  # member's `Kazi.Runtime.run/2`, mirroring the serial path.
  @fleet_seam_opts [
    :member_runner,
    :supervisor,
    :reconcile_timeout,
    :on_frontier_complete,
    :pause_between_waves,
    :resume_token
  ]

  defp run_fleet(path, %Fleet{} = fleet, opts, runtime_opts) do
    persist? = ensure_read_model()
    # T21.12: the standalone binary hands straight to the CLI before the app
    # supervision tree is up — ensure the partition supervisor the DepScheduler
    # dispatches under is running (idempotent under mix/test).
    {:ok, _supervisor} = Kazi.Scheduler.PartitionSupervisor.ensure_started()

    exec_opts = build_fleet_exec_opts(opts, runtime_opts, persist?)

    case Fleet.Execution.run(fleet, exec_opts) do
      {:ok, result} ->
        report_fleet(path, fleet, result, json?(opts))
        fleet_exit_code(result)

      {:error, {:resume_not_found, token}} ->
        fleet_error("resume token #{token} not found; re-run without it", opts)

      {:error, {:goal_changed, message}} ->
        fleet_error("cannot resume: #{message}", opts)

      {:error, reason} ->
        fleet_error("fleet execution failed: #{inspect(reason)}", opts)
    end
  end

  # The `Kazi.Fleet.Execution.run/2` opts shared by the --fleet path and the
  # T45.4 roadmap path — both drive the SAME goal-level scheduler, so they build
  # the execution opts identically (member seams, per-member runtime opts,
  # concurrency cap, base ref, frontier stream, pause/resume).
  defp build_fleet_exec_opts(opts, runtime_opts, persist?) do
    workspace = opts[:workspace] || "."

    runtime_opts
    |> Keyword.take(@fleet_seam_opts)
    |> Keyword.put(:workspace, workspace)
    |> Keyword.put(:persist?, persist?)
    |> Keyword.put(:runtime_opts, fleet_member_runtime_opts(opts, runtime_opts))
    |> maybe_put(:fleet_concurrency, opts[:fleet_concurrency])
    # T50.8: --base selects every member worktree's base ref (nil keeps the
    # HEAD default with the stale-base warning).
    |> maybe_put(:base_ref, opts[:base])
    # issue #936 one level up: under --json --stream, frontier boundaries emit
    # the same-shaped frontier_complete JSONL event the --parallel needs-DAG
    # path emits (same helper, same schema).
    |> maybe_put_frontier_stream(opts)
    # T50.6: --pause-between-waves / --resume act on frontiers the same way they
    # act on a needs-DAG goal's waves — same helper, one level up.
    |> maybe_put_pause_resume(opts)
  end

  # The per-member `Kazi.Runtime.run/2` opts: the caller's runtime seams (minus
  # the fleet-level ones) with the CLI flag levers threaded exactly like the
  # serial/parallel paths (harness/model/effort/permissions/session identity/
  # deploy env/standing/debrief).
  defp fleet_member_runtime_opts(opts, runtime_opts) do
    runtime_opts
    |> Keyword.drop(@fleet_seam_opts)
    |> maybe_put_deploy_env(opts[:env])
    |> maybe_put_standing(opts[:standing])
    |> maybe_put_debrief(opts[:debrief])
    |> maybe_put(:harness, opts[:harness])
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:effort, opts[:effort])
    |> maybe_put(:permission_mode, opts[:permission_mode])
    |> maybe_put(:allowed_tools, opts[:allowed_tools])
    |> maybe_put(:session_name, resolve_session_name(opts))
    |> maybe_put(:allow_duplicate_run, if(opts[:allow_duplicate_run] == true, do: true))
    |> maybe_put(
      :allow_workspace_collision,
      if(opts[:allow_workspace_collision] == true, do: true)
    )
  end

  # 0 on a converged collective — and on a PAUSE (T50.3 one level up: a pause
  # is the requested outcome, carrying the resume token; mirroring the
  # pause-between-waves contract "exit 0 with a resumable state token").
  defp fleet_exit_code(%{collective: :converged}), do: 0
  defp fleet_exit_code(%{collective: :paused}), do: 0
  defp fleet_exit_code(_result), do: 1

  # ---------------------------------------------------------------------------
  # fleet terminal report (T50.5): mirrors the DAG collective shape
  # ---------------------------------------------------------------------------

  # The fleet terminal object mirrors the DAG collective result
  # (docs/schemas/collective-result.md): schema_version / collective /
  # schedule / blocked / next_action are the SAME keys with the same meaning;
  # `mode`, `members` (per-member status + honest-unknown economy +
  # landing info), the fleet-level `economy` rollup, and `resume_token` are
  # ADDITIVE. The schedule renders through the SAME DepGraph layering the
  # scheduler ran (`Kazi.Fleet.Execution.synthetic_goal/2`), so report and
  # execution can never disagree on a member's frontier.
  defp report_fleet(path, %Fleet{} = fleet, result, json?) do
    emit(json?, fleet_result_json(path, fleet, result), fn ->
      report_fleet_human(path, fleet, result)
    end)
  end

  defp fleet_result_json(path, %Fleet{} = fleet, result) do
    collective_str = to_string(result.collective)
    synthetic = Fleet.Execution.synthetic_goal(fleet, ".")

    %{
      schema_version: @run_schema_version,
      mode: "fleet",
      fleet: path,
      collective: collective_str,
      members: fleet_members_json(result),
      schedule: schedule_json(synthetic, result.members),
      blocked: blocked_json(Map.get(result, :blocked, [])),
      economy: result.economy,
      resume_token: result.resume_token,
      next_action: fleet_next_action(collective_str)
    }
  end

  defp fleet_members_json(result) do
    Enum.map(result.members, fn {id, status} ->
      member = Map.get(result.member_results, id, %{})

      %{
        id: id,
        status: to_string(status),
        economy: Map.get(member, :economy),
        integration: Map.get(member, :integration),
        error: fleet_member_error(Map.get(member, :error))
      }
    end)
  end

  defp fleet_member_error(nil), do: nil
  defp fleet_member_error(error) when is_binary(error), do: error
  defp fleet_member_error(error), do: inspect(error)

  defp fleet_next_action("paused"),
    do: "paused at a fleet frontier; resume by re-running with the resume_token"

  defp fleet_next_action(collective_str), do: next_action(collective_str)

  defp report_fleet_human(path, %Fleet{} = fleet, result) do
    synthetic = Fleet.Execution.synthetic_goal(fleet, ".")

    IO.puts("FLEET #{result.collective |> to_string() |> String.upcase()}  source=#{path}")
    IO.puts("members: #{length(result.members)}")
    print_schedule_frontiers(schedule_view(synthetic, result.members))
    print_blocked_human(Map.get(result, :blocked, []))
    print_fleet_economy_human(result.economy)
    print_fleet_cost_table(result)

    if result.resume_token do
      IO.puts("resume_token: #{result.resume_token}")
    end
  end

  # T60.5 (#1070): "kazi apply --fleet prints one row per goal in the same
  # table shape" as the single-goal report -- reuses print_cost_table/1
  # (the "not two separate implementations" requirement). Sourced from each
  # member's `:human_cost` (never `--json`-serialized; see
  # `Kazi.Fleet.Execution`'s moduledoc). Members that reported no usage at
  # all are skipped, same honest-unknown rule as the single-goal path;
  # nothing prints when NO member reported usage.
  defp print_fleet_cost_table(%{members: members, member_results: member_results}) do
    rows =
      members
      |> Enum.map(fn {id, _status} -> {id, Map.get(member_results, id, %{})} end)
      |> Enum.filter(fn {_id, member} -> is_map(Map.get(member, :human_cost)) end)
      |> Enum.map(fn {id, member} -> fleet_cost_row(id, member) end)

    if rows != [] do
      IO.puts("")
      print_cost_table(rows)
    end
  end

  defp print_fleet_cost_table(_result), do: :ok

  defp fleet_cost_row(id, %{economy: economy, human_cost: human_cost}) do
    %{
      goal: id,
      iterations: Map.get(economy || %{}, :iterations, 0),
      cost_usd: Map.get(human_cost, :cost_usd),
      predicates: predicates_label(Map.get(human_cost, :vector)),
      token_breakdown: Map.get(human_cost, :token_breakdown)
    }
  end

  defp print_fleet_economy_human(%{totals: nil} = economy) do
    IO.puts("economy: #{economy.members_reported}/#{economy.members_total} members reported")
  end

  defp print_fleet_economy_human(%{totals: totals} = economy) do
    IO.puts(
      "economy: #{economy.members_reported}/#{economy.members_total} members reported; " <>
        "iterations=#{totals.iterations} tokens=#{totals.tokens} elapsed_ms=#{totals.elapsed_ms}"
    )
  end

  defp fleet_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  defp explain_fleet(%Fleet{} = fleet, opts) do
    json? = json?(opts)
    frontiers = Fleet.frontiers(fleet)

    emit(json?, fleet_explain_json(fleet, frontiers), fn ->
      fleet_explain_human(fleet, frontiers)
    end)

    0
  end

  defp fleet_explain_json(%Fleet{nodes: nodes, edges: edges}, frontiers) do
    %{
      schema_version: @run_schema_version,
      mode: "fleet_explain",
      dispatched: false,
      nodes: Enum.map(nodes, fn n -> %{id: n.id, file: n.file} end),
      edges: Enum.map(edges, &fleet_edge_json/1),
      frontiers: frontiers,
      next_action: "run without --explain to execute the fleet"
    }
  end

  defp fleet_edge_json(%Fleet.Edge{from: from, to: to, kind: :explicit}) do
    %{from: from, to: to, kind: "explicit"}
  end

  defp fleet_edge_json(%Fleet.Edge{from: from, to: to, kind: :inferred_overlap, overlap: overlap}) do
    %{
      from: from,
      to: to,
      kind: "inferred_overlap",
      overlap: Enum.map(overlap, fn {a, b} -> %{a: a, b: b} end)
    }
  end

  defp fleet_explain_human(%Fleet{edges: edges}, frontiers) do
    IO.puts("FLEET SCHEDULE (explain, nothing dispatched)")
    IO.puts("frontiers: #{length(frontiers)}")

    frontiers
    |> Enum.with_index()
    |> Enum.each(fn {ids, index} -> IO.puts("  frontier #{index}: #{Enum.join(ids, ", ")}") end)

    Enum.each(edges, fn
      %Fleet.Edge{from: from, to: to, kind: :explicit} ->
        IO.puts("  edge: #{from} -> #{to} (explicit)")

      %Fleet.Edge{from: from, to: to, kind: :inferred_overlap, overlap: overlap} ->
        pairs = Enum.map_join(overlap, ", ", fn {a, b} -> "#{a}~#{b}" end)
        IO.puts("  edge: #{from} -> #{to} (inferred overlap: #{pairs})")
    end)
  end

  # ===========================================================================
  # apply over a roadmap (T45.4, ADR-0075)
  # ===========================================================================
  #
  # `kazi apply <roadmap>` lifts the goal-level scheduler one level up: it runs
  # the roadmap's WHOLE GOALS in topological `needs` frontiers via the SAME
  # `Kazi.Fleet.Execution` engine `--fleet` uses (a roadmap projects to a fleet
  # through `Kazi.Goal.Roadmap.to_fleet/1`). Per-goal loops are UNCHANGED — each
  # goal runs its own kazi apply loop in its own task worktree, inheriting its own
  # `[integration]`/landing (E44). The result is a roadmap-level collective
  # mirroring the fleet/DAG collective shape (docs/schemas/collective-result.md).

  defp execute_roadmap(path, opts, runtime_opts) do
    case Kazi.Goal.Roadmap.load(path) do
      # A SINGLE-goal roadmap has no scheduling to do, so it degrades to plain
      # `kazi apply` on that one goal — the SAME `run_goal/4` entry the lone
      # goal-file path takes (no proposal ref), so --explain/--check and the
      # result object are byte-identical to `kazi apply <that-goal-file>`.
      {:ok, %Kazi.Goal.Roadmap{nodes: [only]}} ->
        persist? = ensure_read_model()
        run_goal(only.goal, opts, persist?, runtime_opts)

      {:ok, %Kazi.Goal.Roadmap{} = roadmap} ->
        cond do
          opts[:explain] == true ->
            explain_roadmap(path, roadmap, opts)

          # Every roadmap goal runs in its OWN task worktree off the shared base
          # (isolation is the goal-level contract, ADR-0065/ADR-0075), so an
          # in-place roadmap would race every goal in one checkout. Rejected
          # loudly, like --fleet + --in-place.
          opts[:in_place] == true ->
            fleet_error(
              "--in-place cannot run a roadmap: every roadmap goal runs in its own " <>
                "kazi-owned task worktree off the shared --workspace base " <>
                "(ADR-0065/ADR-0075). Drop --in-place.",
              opts
            )

          true ->
            run_roadmap(path, roadmap, opts, runtime_opts)
        end

      {:error, message} ->
        fleet_error(message, opts)
    end
  end

  defp run_roadmap(path, %Kazi.Goal.Roadmap{} = roadmap, opts, runtime_opts) do
    fleet = Kazi.Goal.Roadmap.to_fleet(roadmap)
    persist? = ensure_read_model()
    {:ok, _supervisor} = Kazi.Scheduler.PartitionSupervisor.ensure_started()
    exec_opts = build_fleet_exec_opts(opts, runtime_opts, persist?)

    case Fleet.Execution.run(fleet, exec_opts) do
      {:ok, result} ->
        report_roadmap(path, fleet, result, json?(opts))
        fleet_exit_code(result)

      {:error, {:resume_not_found, token}} ->
        fleet_error("resume token #{token} not found; re-run without it", opts)

      {:error, {:goal_changed, message}} ->
        fleet_error("cannot resume: #{message}", opts)

      {:error, reason} ->
        fleet_error("roadmap execution failed: #{inspect(reason)}", opts)
    end
  end

  # The roadmap terminal object mirrors the fleet/DAG collective shape exactly —
  # only `mode` ("roadmap"), the source key (`roadmap`), and the node vocabulary
  # (`goals`) differ. Every sub-view (`goals`, `schedule`, `blocked`, economy,
  # next_action) reuses the fleet builders, so the two surfaces never drift.
  defp report_roadmap(path, %Fleet{} = fleet, result, json?) do
    emit(json?, roadmap_result_json(path, fleet, result), fn ->
      report_roadmap_human(path, fleet, result)
    end)
  end

  defp roadmap_result_json(path, %Fleet{} = fleet, result) do
    collective_str = to_string(result.collective)
    synthetic = Fleet.Execution.synthetic_goal(fleet, ".")

    %{
      schema_version: @run_schema_version,
      mode: "roadmap",
      roadmap: path,
      collective: collective_str,
      goals: fleet_members_json(result),
      schedule: schedule_json(synthetic, result.members),
      blocked: blocked_json(Map.get(result, :blocked, [])),
      economy: result.economy,
      resume_token: result.resume_token,
      next_action: fleet_next_action(collective_str)
    }
  end

  defp report_roadmap_human(path, %Fleet{} = fleet, result) do
    synthetic = Fleet.Execution.synthetic_goal(fleet, ".")

    IO.puts("ROADMAP #{result.collective |> to_string() |> String.upcase()}  source=#{path}")
    IO.puts("goals: #{length(result.members)}")
    print_schedule_frontiers(schedule_view(synthetic, result.members))
    print_blocked_human(Map.get(result, :blocked, []))
    print_fleet_economy_human(result.economy)

    if result.resume_token do
      IO.puts("resume_token: #{result.resume_token}")
    end
  end

  defp explain_roadmap(path, %Kazi.Goal.Roadmap{} = roadmap, opts) do
    fleet = Kazi.Goal.Roadmap.to_fleet(roadmap)
    frontiers = Fleet.frontiers(fleet)

    emit(json?(opts), roadmap_explain_json(path, fleet, frontiers), fn ->
      roadmap_explain_human(path, fleet, frontiers)
    end)

    0
  end

  defp roadmap_explain_json(path, %Fleet{nodes: nodes, edges: edges}, frontiers) do
    %{
      schema_version: @run_schema_version,
      mode: "roadmap_explain",
      dispatched: false,
      roadmap: path,
      goals: Enum.map(nodes, fn n -> %{id: n.id, source: n.file} end),
      edges: Enum.map(edges, &fleet_edge_json/1),
      frontiers: frontiers,
      next_action: "run without --explain to execute the roadmap"
    }
  end

  defp roadmap_explain_human(path, %Fleet{edges: edges}, frontiers) do
    IO.puts("ROADMAP SCHEDULE (explain, nothing dispatched)  source=#{path}")
    IO.puts("frontiers: #{length(frontiers)}")

    frontiers
    |> Enum.with_index()
    |> Enum.each(fn {ids, index} -> IO.puts("  frontier #{index}: #{Enum.join(ids, ", ")}") end)

    Enum.each(edges, fn %Fleet.Edge{from: from, to: to} ->
      IO.puts("  edge: #{from} -> #{to}")
    end)
  end

  # T39.2 (ADR-0049): `apply` accepts either a goal-file PATH (the historical
  # argument, behavior unchanged) or an APPROVED proposal's `prop-...` ref —
  # the handle `plan` mints and `approve` flips — loaded straight from the
  # read-model, so the plan -> approve -> apply spine closes with no
  # orchestrator-side goal-file reconstruction. The `prop-` prefix is the
  # discriminator (ADR-0049); an EXISTING file always wins the tie, so a
  # goal-file that happens to be named `prop-...` still loads as a path.
  # Both sources yield a goal through the same validated loader
  # (`Kazi.Goal.Loader`), so the runtime's pre-loop guards (vacuous-goal,
  # primary-workspace, duplicate-run) apply identically.
  @spec load_goal_source(String.t(), boolean()) ::
          {:ok, Goal.t(), String.t() | nil, String.t() | nil} | {:error, String.t()}
  defp load_goal_source(source, persist?) do
    if proposal_ref?(source) do
      load_approved_proposal(source, persist?)
    else
      case Goal.Loader.load(source) do
        {:ok, goal} -> {:ok, goal, nil, nil}
        {:error, reason} -> {:error, "could not load goal-file #{source}: #{reason}"}
      end
    end
  end

  defp proposal_ref?(source) do
    String.starts_with?(source, "prop-") and not File.exists?(source)
  end

  # A proposal ref lives in the read-model, so without one (the escript's
  # missing SQLite NIF, a failed migration) the ref cannot resolve — refuse
  # clearly rather than reporting a misleading "could not load goal-file"
  # (repo lore L-0031: every CLI path touching the read-model must degrade
  # cleanly, never crash).
  defp load_approved_proposal(ref, false) do
    {:error,
     "proposal ref #{ref} requires the read-model, which is unavailable here; " <>
       "run via the release binary or `mix kazi.apply`, or pass a goal-file path"}
  end

  defp load_approved_proposal(ref, true) do
    case Authoring.load_approved(ref) do
      {:ok, goal} ->
        # Session provenance part 2: carry the proposal's own session_name
        # (the session that authored it) alongside its ref, so an applying
        # session that names none of its own falls back to who planned it
        # (resolve_session_name/1) — the plan -> approve -> apply lifecycle
        # is designed to be cross-session.
        proposal_session_name =
          case ReadModel.get_proposed_goal(ref) do
            %ProposedGoal{session_name: session_name} -> session_name
            nil -> nil
          end

        {:ok, goal, ref, proposal_session_name}

      {:error, :not_found} ->
        {:error,
         "no proposal #{ref} in the read-model; draft one with `kazi plan` " <>
           "(see `kazi list-proposed`), or pass a goal-file path"}

      {:error, {:not_approved, status}} ->
        {:error,
         "proposal #{ref} is #{status}, not approved; only an approved proposal " <>
           "runs — approve it first (`kazi approve #{ref}`)"}

      {:error, {:invalid_goal, reason}} ->
        {:error, "proposal #{ref} no longer loads as a runnable goal: #{inspect(reason)}"}
    end
  end

  # T21.8 (ADR-0027): `--parallel` routes the run to the PARALLEL SCHEDULER
  # (`Kazi.Scheduler.run_goals/2`) instead of the serial single-goal loop. The
  # scheduler partitions the goal-set by blast radius and drives one supervised
  # reconciler per partition to a COLLECTIVE verdict; a single-partition goal-set
  # (one goal / no blast radius) degrades to today's serial behavior. Without
  # `--parallel` the run is byte-identical to the pre-T21.8 serial path.
  defp run_goal(%Goal{} = goal, opts, persist?, runtime_opts) do
    cond do
      # T50.8 (ADR-0065 decision 5): --in-place + --base is CONTRADICTORY —
      # --base selects the ref the kazi-owned task worktree is created FROM,
      # and --in-place runs with no worktree at all. Rejected up front, before
      # any execution branch, like the other flag-interplay checks below.
      opts[:in_place] == true and is_binary(opts[:base]) ->
        refuse_contradictory_base(opts)

      # T23.6 (ADR-0028): --explain / --dry-run is PURE PLANNING — compute and print
      # the wave schedule, dispatch NOTHING, exit 0. Checked FIRST so it never falls
      # through to a real serial/parallel run (the spy seam asserts no reconciler is
      # invoked). It runs before any execution branch regardless of --parallel.
      opts[:explain] == true ->
        explain_schedule(goal, opts, runtime_opts)

      # (issue #805): --check is observe-only, same as --explain — checked before
      # any execution branch so it never dispatches a harness/reconciler either.
      opts[:check] == true ->
        check_goal(goal, opts, runtime_opts)

      # T50.6 (the ADR-0065/T50.3 CLI surface): --pause-between-waves / --resume
      # are WAVE-BOUNDARY mechanisms — they exist only where frontiers exist
      # (--parallel needs-DAG/group scheduling; the --fleet path never reaches
      # run_goal and accepts them on its own). A serial loop has no boundary to
      # pause at or resume from, so the combination is rejected loudly, like the
      # other flag-interplay checks above.
      (opts[:pause_between_waves] == true or is_binary(opts[:resume])) and
          opts[:parallel] != true ->
        refuse_pause_without_parallel(opts)

      # (issue #937 Gap A): an EXECUTING apply refuses a workspace that is a git
      # repo's PRIMARY worktree unless --allow-primary-workspace. The dispatched
      # agent's shell can reset/clean the whole checkout, and a primary checkout
      # routinely holds untracked state a wipe destroys (a live incident lost a
      # concurrent session's files exactly this way; lore L-0034). Checked AFTER
      # --explain/--check (read-only, safe anywhere) and before both execution
      # branches, so serial and --parallel are guarded alike. A non-git
      # workspace is unaffected.
      # T50.1 (ADR-0065 decision 1): the guard now applies ONLY to the
      # --in-place serial path (and, unchanged, to --parallel). The DEFAULT
      # serial path (no --in-place) creates its own task worktree off the
      # requested workspace, so a primary-worktree target is unreachable and
      # the refusal is unnecessary there.
      primary_workspace_refused?(goal, opts) and
          (opts[:parallel] == true or opts[:in_place] == true) ->
        refuse_primary_workspace(goal, opts)

      opts[:parallel] == true ->
        with_preflight(goal, opts, persist?, fn ->
          warn_unwritable_permission_mode(goal, opts)
          run_goal_parallel(goal, opts, persist?, runtime_opts)
        end)

      true ->
        with_preflight(goal, opts, persist?, fn ->
          warn_unwritable_permission_mode(goal, opts)
          run_goal_serial(goal, opts, persist?, runtime_opts)
        end)
    end
  end

  # T44.9 (UC-058): before the FIRST dispatch, verify the base can actually
  # receive the run's work and REFUSE with a named reason if not — so a run never
  # burns a budget only to strand converged work on a broken push path. Gated
  # here, after the read-only --explain/--check short-circuits (which dispatch
  # nothing and so need no preflight) and around BOTH execution branches, so
  # serial and --parallel are guarded alike.
  #
  # Only REAL, persisted runs are preflighted: a `persist? == false` run is an
  # ephemeral / read-model-unavailable best-effort dispatch (and every stubbed
  # test drive), not a tracked run whose landing we must protect — gating on
  # persist? keeps preflight off those without a per-caller opt-out. `--no-preflight`
  # bypasses it explicitly.
  defp with_preflight(%Goal{} = goal, opts, persist?, dispatch) when is_function(dispatch, 0) do
    if opts[:no_preflight] == true or persist? == false do
      dispatch.()
    else
      case Kazi.Apply.Preflight.check(goal, opts) do
        :ok -> dispatch.()
        {:refuse, %{message: message}} -> refuse_preflight(message, opts)
      end
    end
  end

  defp refuse_preflight(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # T54.6 (#1072, regression of #769) fix (a): warn BEFORE dispatching when the
  # claude harness will run under a permission mode that cannot write. Such a run
  # burns budget and changes nothing, and the harness still exits 0 — the exact
  # silent failure of lore L-0023.
  #
  # REFRAMED from the task's original condition ("harness=claude AND NO
  # --permission-mode"): that condition is now unreachable. `Runtime` defaults the
  # mode to "auto" (#769), so a mode is ALWAYS set and the original trigger could
  # never fire — it would have shipped as dead code. The residual risk is no longer
  # "unset" but "explicitly set to something that cannot act", so that is what this
  # warns on:
  #
  #   * `plan`      — read-only by design; every Write is refused.
  #   * `default`   — defers to the interactive trust dialog, which a headless
  #                   `-p` dispatch has no human to accept.
  #   * `acceptEdits` — grants edits but NOT Bash, so a goal whose predicates need
  #                   git (a `landed`/`committed` check) can never converge.
  #
  # Placed on both execution branches and NOT on --check/--explain, which are
  # read-only and dispatch nothing (the task's exemption).
  # The profile an `apply` with no `--harness` and no goal-file `[harness] id`
  # resolves to (Kazi.Harness.Registry's default).
  @default_harness_id "claude"

  @unwritable_permission_modes %{
    "plan" => "it is read-only by design — every Write is refused",
    "default" =>
      "it defers to Claude Code's interactive trust dialog, which a headless dispatch has no human to accept",
    "acceptEdits" =>
      "it grants edits but NOT Bash, so a goal whose predicates need git (a `landed`/`committed` check) can never converge"
  }
  defp warn_unwritable_permission_mode(%Goal{} = goal, opts) do
    with "claude" <- to_string(harness_id(goal, opts)),
         mode when is_binary(mode) <- effective_permission_mode(goal, opts),
         {:ok, why} <- Map.fetch(@unwritable_permission_modes, mode) do
      # stderr, so a `--json` stdout stream stays machine-parseable (the
      # `warn_on_liveness` precedent).
      IO.puts(
        :stderr,
        "warning: permission_mode=#{mode} cannot make the changes this goal needs -- #{why}. " <>
          "The harness will still exit 0 while changing nothing, and the run will burn budget " <>
          "to `stuck` (issue #1072). Use --permission-mode auto (the default) or bypassPermissions."
      )
    end

    :ok
  end

  defp effective_permission_mode(%Goal{harness: harness}, opts) when is_map(harness),
    do: opts[:permission_mode] || Map.get(harness, :permission_mode)

  defp effective_permission_mode(%Goal{}, opts), do: opts[:permission_mode]

  # The harness this run will resolve to. `nil` from BOTH the flag and the
  # goal-file means the DEFAULT profile, which is claude — so nil must read as
  # "claude" here, or the warning above silently never fires on the single most
  # common invocation (`kazi apply <goal>` with no --harness).
  defp harness_id(%Goal{harness: harness}, opts) when is_map(harness),
    do: opts[:harness] || Map.get(harness, :id) || @default_harness_id

  defp harness_id(%Goal{}, opts), do: opts[:harness] || @default_harness_id

  # Whether the resolved workspace IS a git repo's primary (non-linked)
  # worktree root AND the caller did not opt in with
  # --allow-primary-workspace. Two conditions, both from one `git rev-parse`:
  #
  #   * primary vs linked — in the primary worktree `--git-dir` and
  #     `--git-common-dir` answer the SAME path; in a linked worktree the
  #     git-dir is `.git/worktrees/<name>` while the common dir stays the main
  #     `.git` (the discriminator `git worktree list` itself uses);
  #   * the workspace is the worktree's TOP LEVEL — a workspace nested INSIDE
  #     a checkout (a scratch subdir, a fixture under a repo's tmp/) is not
  #     the incident shape (#937's wipe hit a workspace that WAS the checkout
  #     root) and stays unguarded, matching how every test/harness scratch
  #     dir has always worked.
  #
  # Fail-open on anything unexpected (no git, not a repo, weird output): the
  # guard is a tripwire for the shared-checkout incident class, never a new
  # way for a healthy run to break.
  defp primary_workspace_refused?(%Goal{} = goal, opts) do
    opts[:allow_primary_workspace] != true and
      primary_worktree_root?(opts[:workspace] || goal.scope.workspace)
  end

  defp primary_worktree_root?(workspace) when is_binary(workspace) do
    case System.cmd(
           "git",
           ["-C", workspace, "rev-parse", "--git-dir", "--git-common-dir", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.split(out, "\n", trim: true) do
          [git_dir, common_dir, toplevel] ->
            Path.expand(git_dir, workspace) == Path.expand(common_dir, workspace) and
              Path.expand(toplevel) == Path.expand(workspace)

          _ ->
            false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp primary_worktree_root?(_workspace), do: false

  defp refuse_primary_workspace(%Goal{} = goal, opts) do
    workspace = opts[:workspace] || goal.scope.workspace

    message =
      "workspace #{workspace} is a git repo's PRIMARY worktree; an executing " <>
        "apply refuses it (issue #937) because the dispatched agent's shell can " <>
        "reset/clean the whole checkout, destroying untracked state that is not " <>
        "this goal's to touch. Run against a dedicated task worktree " <>
        "(git worktree add <path> <branch>), or pass --allow-primary-workspace " <>
        "to accept the risk. --check/--explain stay available without the flag."

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # T50.1 (ADR-0065 decision 1): a serial `apply` no longer trusts `--workspace`
  # as the edit site directly. By default it creates a kazi-owned task
  # worktree off that workspace's HEAD, threads the WORKTREE path in as
  # `:workspace` (so the loop, the dispatched agent, and predicate evaluation
  # all operate there), and removes it on every terminal state — the serial
  # 1-partition degenerate case of the parallel scheduler's own worktree
  # isolation (Kazi.Scheduler.Worktree). `--in-place` opts out and reproduces
  # today's direct-edit behavior byte-identically. A workspace that is not a
  # git repo cannot host a worktree at all, so it fails open to in-place
  # (unchanged behavior — worktree isolation is simply unavailable there).
  defp run_goal_serial(%Goal{} = goal, opts, persist?, runtime_opts) do
    base_workspace = opts[:workspace] || goal.scope.workspace
    base_ref = opts[:base]

    cond do
      # T50.8 (ADR-0065 decision 5): an explicit --base must resolve to a commit
      # the local ref store ALREADY KNOWS — checked here, before any worktree is
      # created, so the error names the ref instead of surfacing as a generic
      # worktree-creation failure. kazi never fetches to make a ref resolve.
      is_binary(base_ref) and not base_ref_resolves?(base_workspace, base_ref) ->
        refuse_unresolvable_base(base_ref, base_workspace, opts)

      opts[:in_place] == true or not git_repo?(base_workspace) ->
        run_goal_serial_at(goal, opts, persist?, runtime_opts, base_workspace, base_workspace)

      true ->
        run_goal_serial_in_worktree(goal, opts, persist?, runtime_opts, base_workspace)
    end
  end

  # A pure local read (`rev-parse --verify <ref>^{commit}`), mirroring
  # `Kazi.Scheduler.Worktree`'s own validation — never a fetch. Fail-closed:
  # anything unexpected (no git, not a repo) means the ref cannot be honored.
  defp base_ref_resolves?(workspace, base_ref) when is_binary(workspace) do
    case System.cmd(
           "git",
           ["-C", workspace, "rev-parse", "--verify", "--quiet", base_ref <> "^{commit}"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp base_ref_resolves?(_workspace, _base_ref), do: false

  defp refuse_pause_without_parallel(opts) do
    message =
      "--pause-between-waves/--resume need wave boundaries to act on: pass " <>
        "--parallel (a needs-DAG/group goal) or --fleet (goal-file frontiers). " <>
        "A serial loop has no frontier to pause at (T50.3, ADR-0065 decision 3)."

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  defp refuse_contradictory_base(opts) do
    message =
      "--in-place and --base are contradictory: --base <ref> selects the ref the " <>
        "kazi-owned task worktree is created from (ADR-0065 decision 5), and " <>
        "--in-place runs without a task worktree at all. Drop one of the two flags."

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  defp refuse_unresolvable_base(base_ref, workspace, opts) do
    message =
      "--base #{base_ref} does not resolve to a commit in #{workspace} " <>
        "(git rev-parse --verify #{base_ref}^{commit} failed); kazi never fetches — " <>
        "fetch it yourself and re-run, or pass a ref the local repo already knows"

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # `workspace` is only "a git repo" for T50.1's purposes when it is itself a
  # repo/worktree ROOT (`--show-toplevel` resolves back to it) — matching
  # `primary_worktree_root?/1`'s own check. A plain directory NESTED inside
  # some ancestor repo (e.g. a throwaway scratch dir under this project's own
  # checkout) must NOT be treated as isolatable via `git worktree add`, which
  # would silently branch off the ANCESTOR repo's HEAD instead — it falls open
  # to in-place, unchanged pre-T50.1 behavior.
  defp git_repo?(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> Path.expand(String.trim(out)) == Path.expand(workspace)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp git_repo?(_workspace), do: false

  # Wraps the run in a task worktree via the parallel scheduler's own worktree
  # machinery (Kazi.Scheduler.Worktree.wrap/2) — a 1-partition degenerate case:
  # create off `base_workspace`'s HEAD, run the loop with the worktree path as
  # `:workspace`, remove it on every exit (normal, error, or crash) via the
  # wrapper's `try/after`. `reconciler.(...)` returns whatever `run_goal_serial_at/6`
  # returns (an exit code) on a normal run, or `:stuck` if the worktree itself
  # could not be created (e.g. a permissions failure) — reported as a run error.
  defp run_goal_serial_in_worktree(%Goal{} = goal, opts, persist?, runtime_opts, base_workspace) do
    reconciler =
      Kazi.Scheduler.Worktree.wrap(
        fn _partition, worktree_path ->
          run_goal_serial_at(goal, opts, persist?, runtime_opts, base_workspace, worktree_path)
        end,
        repo: base_workspace,
        # T54.1 (#1079/#1080): check the worktree out onto the goal's REAL target
        # branch, so a goal-authored `landed` predicate naming it can converge and
        # SerialLanding.land/4 recognizes the run-owned branch by explicit identity.
        owned_branch: Kazi.Goal.integration_branch(goal),
        # T50.8 (ADR-0065 decision 5): --base selects the worktree's base ref;
        # nil (flag absent) keeps the HEAD default WITH the stale-base warning,
        # an explicit ref states intent and silences it.
        base_ref: opts[:base]
      )

    case reconciler.(%{key: goal.id}) do
      code when is_integer(code) ->
        code

      _stuck ->
        IO.puts(
          :stderr,
          "error: could not create an isolated task worktree for #{base_workspace}"
        )

        1
    end
  end

  defp run_goal_serial_at(%Goal{} = goal, opts, persist?, runtime_opts, base_workspace, workspace) do
    # The caller's static run config; CLI-owned keys (workspace/persist?) win, and
    # an explicit :persist? in runtime_opts can still override (tests).
    #
    # T3.4d standing wiring: only forward `:standing` when `--standing` was
    # actually given (flag is true). When absent (nil) we leave it unset so
    # `Kazi.Runtime.run/2` falls back to the goal-file's own declared `standing`
    # field — the flag overrides the goal-file, it does not silently force it off.
    run_opts =
      runtime_opts
      |> Keyword.put_new(:persist?, persist?)
      |> Keyword.put(:workspace, workspace)
      # T50.1: the caller's base workspace stays available on the run opts
      # (the follow-up integration task, T50.2, needs it to integrate the
      # worktree's edits back onto the base) — absent only for :in_place runs,
      # where base_workspace == workspace anyway.
      |> Keyword.put(:base_workspace, base_workspace)
      # T3.3d deploy wiring: fold the operator's --env selection into the deploy
      # action's params, so the deepened deploy (T3.3a) selects that environment's
      # per-env target. Merged OVER any caller-supplied :deploy_params so tests
      # passing their own deploy_params keep working and an explicit --env wins.
      |> maybe_put_deploy_env(opts[:env])
      |> maybe_put_standing(opts[:standing])
      # T48.11 (ADR-0058 §3): only forward `:debrief` when `--debrief` was
      # actually given, same rationale as `:standing` above — absent (nil)
      # leaves it unset so `Kazi.Runtime.run/2` falls back to the goal-file's
      # own declared `[economy] debrief` field.
      |> maybe_put_debrief(opts[:debrief])
      # T8.7 harness wiring: forward --harness/--model to Kazi.Runtime, which
      # resolves the adapter (Kazi.Harness.resolve/1). Only set when given, so the
      # default path (no flags) stays byte-identical to the pre-T8.7 claude path.
      |> maybe_put(:harness, opts[:harness])
      |> maybe_put(:model, opts[:model])
      # T36.6 (ADR-0047): forward the Claude-only --effort lever to Kazi.Runtime,
      # which folds it into adapter_opts for the claude profile. Only set when
      # given, so the default path stays byte-identical.
      |> maybe_put(:effort, opts[:effort])
      # (issue #769): forward --permission-mode/--allowed-tools the same way, so
      # a headless claude dispatch can be pre-authorized against an untrusted
      # workspace instead of silently denying every tool call.
      |> maybe_put(:permission_mode, opts[:permission_mode])
      |> maybe_put(:allowed_tools, opts[:allowed_tools])
      # Session identity: --session-name, KAZI_SESSION_NAME, or an
      # auto-detected orchestrator session id (resolve_session_name/1) labels
      # the run's fleet-registry row for the mission control fleet view. Only set
      # when one resolves, so the default path is unchanged when none do.
      |> maybe_put(:session_name, resolve_session_name(opts))
      |> maybe_put(:proposal_ref, opts[:proposal_ref])
      # goal-drift-guard-1415: forward the loaded goal-file path so
      # Kazi.Runtime.run/2 can fingerprint the t0 bar and report if the file
      # on disk drifted from it by the time the run terminates.
      |> maybe_put(:goal_source, opts[:goal_source])
      |> maybe_put(:allow_duplicate_run, if(opts[:allow_duplicate_run] == true, do: true))
      |> maybe_put(
        :allow_workspace_collision,
        if(opts[:allow_workspace_collision] == true, do: true)
      )
      # T15.4 (ADR-0023 decision 3): under --json --stream, thread a per-iteration
      # streaming observer into the runtime's `:stream` seam, which composes it
      # OVER the read-model projection (one `on_iteration` fires both). It emits
      # one JSONL progress event per observation to stdout; the final run-result
      # object below TERMINATES the stream. Off (no `:stream`) unless both flags.
      |> maybe_put_stream(opts)
      # T35.5 (ADR-0045 §8): --context-store/--context-budget wire the store into
      # the dispatch loop (T35.4). Off by default → adapter_opts unchanged → the
      # dispatch + result are byte-identical. A caller/test that already set
      # :context_store in adapter_opts wins (the flag does not override it).
      |> maybe_put_context_store(opts)

    json? = opts[:json] == true

    # T15.3 (ADR-0023 decision 2): map the loop's terminal result to the surface.
    # The loop's outcome/reason are reused verbatim — `:converged`, `:over_budget`,
    # and `:stopped` (which carries `reason: :stuck` for a stuck stop, T1.5) — and
    # rendered as the versioned JSON contract under --json or the human report
    # otherwise. The exit code is the same on both surfaces: 0 only on convergence.
    case attach_run_context_store(Runtime.run(goal, run_opts), run_opts) do
      {:ok, %{outcome: :converged} = result} ->
        # T50.2 (ADR-0065 decision 2): a worktree-isolated serial run that
        # converged LANDS its task-branch commits on the base before the
        # worktree is cleaned up. Runs BEFORE report_outcome so the result
        # object carries the landing verdict. (issue #1407): the exit code
        # mirrors CONVERGENCE alone by default — a converged-but-unlanded run
        # still exits 0 (the landing failure stays visible via
        # `integration.landed == false` plus a stderr warning); pass
        # --strict-landing to couple the exit code to landing too.
        {result, exit_code} =
          land_converged_serial(
            goal,
            result,
            runtime_opts,
            base_workspace,
            workspace,
            opts[:strict_landing] == true
          )

        report_outcome(
          goal,
          :converged,
          result,
          run_economy(goal, :converged, result, opts, persist?),
          workspace,
          json?
        )

        exit_code

      {:ok, %{outcome: :over_budget} = result} ->
        report_outcome(
          goal,
          :over_budget,
          result,
          run_economy(goal, :over_budget, result, opts, persist?),
          workspace,
          json?
        )

        1

      {:ok, %{outcome: :stopped} = result} ->
        report_outcome(
          goal,
          :stopped,
          result,
          run_economy(goal, :stopped, result, opts, persist?),
          workspace,
          json?
        )

        1

      {:error, reason} ->
        report_run_error(goal, reason, json?)
        1
    end
  end

  # =============================================================================
  # serial landing (T50.2, ADR-0065 decision 2)
  # =============================================================================

  # A T50.1-isolated serial run that CONVERGED must land its task-branch commits
  # on the base before the ephemeral worktree is cleaned up — converging in a
  # worktree nobody integrates is a silent drop. The landing itself lives in
  # `Kazi.Scheduler.SerialLanding` (shared with the fleet member path, T50.5);
  # this wrapper folds its verdict into the CLI surface.
  #
  # (issue #1407): the exit code is DECOUPLED from the landing verdict by
  # default — convergence alone earns exit 0, and a landing failure is
  # surfaced (the `integration.landed == false` evidence, the stderr warning,
  # the surviving task-branch ref the worktree teardown never destroys)
  # WITHOUT downgrading the exit code, so a caller polling exit status alone
  # cannot mistake "the fix converged but a landing hiccup left it on a task
  # branch" for "nothing happened". `strict_landing?` (--strict-landing)
  # restores the pre-#1407 coupling for a caller that wants a landing failure
  # to fail the invocation outright (e.g. a CI gate).
  defp land_converged_serial(
         %Goal{} = goal,
         result,
         runtime_opts,
         base_workspace,
         workspace,
         strict_landing?
       ) do
    if Path.expand(base_workspace) == Path.expand(workspace) do
      # In-place (or non-git) run: the work already lives in the caller's checkout.
      {result, 0}
    else
      land_opts = [vector: Map.get(result, :vector)]

      case Kazi.Scheduler.SerialLanding.land(
             goal,
             runtime_opts,
             base_workspace,
             workspace,
             land_opts
           ) do
        :nothing_to_land ->
          {result, 0}

        {:landed, info} ->
          {Map.put(result, :integration, info), 0}

        {:unlanded, info} ->
          hint =
            if strict_landing?,
              do: "",
              else: " (exit 0 — pass --strict-landing to fail the invocation on this)"

          IO.puts(
            :stderr,
            "warning: goal #{goal.id} converged but its work did NOT land on " <>
              "#{info[:base] || "the base"}: #{info[:reason] || "integration failed"}; " <>
              "the task branch #{info[:task_branch]} survives in #{base_workspace}#{hint}"
          )

          {Map.put(result, :integration, info), if(strict_landing?, do: 1, else: 0)}
      end
    end
  end

  # T34.6 (ADR-0046 §5): fold the run's per-iteration accounting envelopes into the
  # run-end economy KPIs. The cost split comes from the run-aggregate `usage`
  # envelope (T34.1) and the terminal vector's converged-predicate count; the
  # cache + re-discovery KPIs come from the RECORDED per-iteration `context` /
  # `tools` counters (T34.3), read back from the read-model when the run persisted.
  # Without persistence (no read-model) only the run-aggregate KPIs are derivable
  # and the per-iteration ones report unavailable (`nil`) — honest, never zero.
  defp run_economy(%Goal{} = goal, outcome, result, opts, persist?) do
    iterations = if persist?, do: recorded_iterations(goal.id), else: []

    meta = %{
      status: run_status(outcome, result),
      converged_predicates: converged_predicate_count(Map.get(result, :vector)),
      iteration_count: Map.get(result, :iterations, 0),
      usage: Map.get(result, :usage, %{}),
      harness: opts[:harness] && to_string(opts[:harness]),
      model: opts[:model] && to_string(opts[:model])
    }

    Kazi.Economy.KPIs.from_iterations(iterations, meta)
  end

  # Read back the goal's recorded iterations for the economy fold, best-effort: a
  # read-model that is not started/available yields no iterations (the
  # per-iteration KPIs then report unavailable) rather than crashing the run's
  # terminal report.
  defp recorded_iterations(goal_id) do
    ReadModel.list_iterations(goal_id)
  rescue
    _ -> []
  end

  # The number of predicates that reached `pass` at the terminal observation — the
  # KPI denominator (cost / converged predicate). `nil` for an absent vector.
  defp converged_predicate_count(%Kazi.PredicateVector{results: results}) do
    Enum.count(results, fn {_id, result} -> Kazi.PredicateResult.passed?(result) end)
  end

  defp converged_predicate_count(_), do: nil

  # =============================================================================
  # context store wiring (T35.5, ADR-0045 §8)
  # =============================================================================

  @context_default_budget 6_000

  # Map a --context-store provider name to its ContextStore provider module.
  defp context_store_provider("gist"), do: {:ok, Kazi.ContextStore.GistCLI}
  defp context_store_provider(other), do: {:error, {:unknown_context_store, other}}

  # Fold --context-store/--context-budget into run_opts[:adapter_opts]. A
  # caller/test that already set :context_store in adapter_opts WINS (the flag does
  # not override an injected store). With no flag, run_opts is returned unchanged so
  # the dispatch is byte-identical (the loop, T35.4, only compresses when a store is
  # present). An unknown provider name leaves the store off.
  defp maybe_put_context_store(run_opts, opts) do
    adapter = Keyword.get(run_opts, :adapter_opts, [])

    cond do
      Keyword.has_key?(adapter, :context_store) ->
        run_opts

      is_nil(opts[:context_store]) ->
        run_opts

      true ->
        case context_store_provider(opts[:context_store]) do
          {:ok, module} ->
            budget = opts[:context_budget] || @context_default_budget

            Keyword.put(
              run_opts,
              :adapter_opts,
              Keyword.merge(adapter, context_store: module, context_budget: budget)
            )

          {:error, {:unknown_context_store, name}} ->
            # An unknown --context-store name silently left the store off, so the
            # operator believed compression was active when it was not (deep
            # review L11) — warn on stderr rather than swallowing it.
            IO.puts(:stderr, "warning: unknown --context-store #{inspect(name)}; store left off")
            run_opts
        end
    end
  end

  # Attach the additive `context_store` stats object to a successful run result when
  # a store was configured. Absent ⇒ result unchanged ⇒ byte-identical.
  defp attach_run_context_store({:ok, result}, run_opts),
    do: {:ok, attach_context_store_stats(result, run_opts)}

  defp attach_run_context_store(other, _run_opts), do: other

  defp attach_context_store_stats(result, run_opts) do
    adapter = Keyword.get(run_opts, :adapter_opts, [])

    case Keyword.get(adapter, :context_store) do
      nil ->
        result

      store ->
        budget = Keyword.get(adapter, :context_budget, @context_default_budget)

        case ContextStore.stats(context_store: store) do
          {:ok, stats} -> Map.put(result, :context_store, context_store_json(stats, budget))
          {:error, _} -> result
        end
    end
  end

  defp context_store_json(stats, budget) do
    %{
      provider: to_string(Map.get(stats, :provider, "gist")),
      indexed_bytes: Map.get(stats, :indexed_bytes, 0),
      returned_bytes: Map.get(stats, :returned_bytes, 0),
      saved_bytes: Map.get(stats, :saved_bytes, 0),
      budget: budget
    }
  end

  # =============================================================================
  # run --parallel (T21.8, ADR-0027): drive the native parallel scheduler
  # =============================================================================
  #
  # Routes the goal-set to `Kazi.Scheduler.run_goals/2` — partition by blast
  # radius, one supervised reconciler per partition, fold the COLLECTIVE verdict
  # (`%{collective:, partitions:}`). The CLI only RENDERS + VERSIONS that result;
  # it invents no scheduler semantics. Under --json it emits the versioned
  # COLLECTIVE object (docs/schemas/collective-result.md); --parallel is
  # NON-INTERACTIVE under --json. The exit code mirrors the collective verdict
  # (0 only when every partition converged), matching the serial run's contract.
  #
  # The scheduler's injectable reconciler seam keeps this hermetic: a test injects
  # `:reconciler` (and a static `:graph_source`) via `inject_opts`, so no real
  # harness, lease, or worktree is touched. Production injects nothing and the
  # default per-goal loop runs.
  defp run_goal_parallel(%Goal{} = goal, opts, persist?, runtime_opts) do
    # T21.12 fix: the parallel scheduler dispatches partition/group reconcilers
    # under the NAMED `Kazi.Scheduler.PartitionSupervisor`. The app supervision
    # tree starts it, but the Burrito standalone binary hands straight to the CLI
    # before that tree is stood up (the same path that left `Kazi.Repo` unstarted),
    # so under the released binary the supervisor is absent and the scheduler's
    # `start_child/2` crashes with `:noproc`. Ensure it is running for this process
    # before dispatching — idempotent under mix/test where the app tree started it.
    {:ok, _supervisor} = Kazi.Scheduler.PartitionSupervisor.ensure_started()

    workspace = opts[:workspace] || goal.scope.workspace
    json? = opts[:json] == true

    # Compose the scheduler opts. `:workspace` is required by `run_goals/2`; the
    # caller's injected seams (`:reconciler`, `:graph_source`, `:lease`,
    # `:worktree`, `:supervisor`, `:reconcile_timeout`, `:run_opts`, `:integrate`,
    # `:max_restarts`) pass through verbatim so the boundary test stays hermetic.
    # `:run_opts` carries the per-goal loop config (persist?/harness/model) the
    # default reconciler forwards to `Kazi.Runtime.run/2`.
    scheduler_opts =
      runtime_opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.update(
        :run_opts,
        default_parallel_run_opts(opts, persist?),
        &merge_parallel_run_opts(&1, opts, persist?)
      )
      |> maybe_put_default_lease()
      |> maybe_put_default_worktree(workspace, opts)
      |> maybe_put_frontier_stream(opts)
      |> maybe_put_pause_resume(opts)

    case Kazi.Scheduler.run_goals([goal], scheduler_opts) do
      {:ok, result} ->
        # T62.6 (issue #1241 part 2): persist the per-group landed refs the
        # collective just computed so `kazi status <goal-id>` shows the same
        # per-group landing detail AFTER the run exits, not only this immediate
        # invocation's output. Best-effort (a projection, never gates the run);
        # skipped when persistence is off (`--json` boundary tests without a
        # read-model) — the immediate collective surface is unchanged.
        if persist?, do: persist_landed_refs(goal, result)
        report_collective(goal, result, json?)
        collective_exit_code(result)

      {:error, reason} ->
        report_run_error(goal, reason, json?)
        1
    end
  end

  # T50.6 (the ADR-0065/T50.3 CLI surface): thread --pause-between-waves /
  # --resume into the DepScheduler opts. `put_new` so an injected seam (a
  # boundary test driving :pause_between_waves/:resume_token via runtime_opts)
  # keeps its value; only meaningful on the needs-DAG/group route — the flat
  # parallel path has no frontiers, so the options are dropped there, mirroring
  # :on_frontier_complete.
  defp maybe_put_pause_resume(scheduler_opts, opts) do
    scheduler_opts
    |> then(fn acc ->
      if opts[:pause_between_waves] == true,
        do: Keyword.put_new(acc, :pause_between_waves, true),
        else: acc
    end)
    |> then(fn acc ->
      case opts[:resume] do
        token when is_binary(token) -> Keyword.put_new(acc, :resume_token, token)
        _absent -> acc
      end
    end)
  end

  # Engage the partition LEASE layer on the production CLI path so the operator
  # dashboard's lease map (`/leases`, `KaziWeb.CoordinationSource.Native`) renders
  # the live native-parallel leases. Without `:lease` opts the scheduler skips
  # `Kazi.Scheduler.LeasedReconciler.wrap/2` entirely (lib/kazi/scheduler.ex), so
  # nothing publishes into `Kazi.Coordination.LeaseTable` and the map stays empty.
  #
  # We start a per-run in-memory lease store (the single-node, NATS-free backend;
  # ADR-0027) and point the lease layer at the globally-readable `LeaseTable` so a
  # SAME-NODE dashboard (the dev `mix phx.server` driving an in-node run) sees the
  # partitions' leases live. A separately-deployed dashboard reading a one-shot
  # CLI's leases still needs the NATS transport source (Slice 3) — different BEAM
  # nodes share no in-memory table.
  #
  # Best-effort and hermetic: skipped when the caller already injected `:lease`
  # (keep its handle) or injected a `:reconciler` (a boundary test drives its own
  # seam and must not be wrapped in a real lease), so the parallel boundary tests
  # stay free of real lease/clock side effects.
  defp maybe_put_default_lease(opts) do
    if Keyword.has_key?(opts, :lease) or Keyword.has_key?(opts, :reconciler) do
      opts
    else
      {:ok, _table} = Kazi.Coordination.LeaseTable.ensure_started()
      {:ok, store} = Kazi.Coordination.Lease.Memory.start_link()

      Keyword.put(opts, :lease,
        backend: Kazi.Coordination.Lease.Memory,
        lease_opts: [store: store],
        lease_table: Kazi.Coordination.LeaseTable
      )
    end
  end

  # T59.9 (#937 Gap F): DEFAULT per-partition worktree isolation on the parallel
  # path, mirroring the serial path (`run_goal_serial_in_worktree`). Without this
  # the flat/group scheduler handed EVERY partition the SAME `--workspace` root
  # (compose_reconciler skips the worktree layer when no `:worktree` opts are
  # given), so N group reconcilers edited one cwd concurrently — the exact
  # 9-10-agents-share-one-cwd symptom #937 comment 3 observed. Each partition now
  # gets its own git worktree off the workspace base (`repo: workspace`), created
  # from `--base` when set (else HEAD, with the staleness warning). The DIRs live
  # under the managed base dir, never the workspace root.
  #
  # Skipped when the caller already injected `:worktree` (an explicit fixture base
  # dir) or a `:reconciler`/`:group_reconciler` stub (hermetic boundary tests that
  # drive a chosen status against a non-git tmp workspace and must NOT touch git),
  # mirroring `maybe_put_default_lease/1`. Also skipped when the workspace is NOT a
  # git work-tree: isolation is a `git worktree add`, so there is nothing to branch
  # from — an executing real `apply` runs against a git repo (the primary-worktree
  # guard + integration already require it), while a bare-directory boundary run
  # keeps its pre-T59.9 in-workspace behavior instead of failing worktree creation.
  defp maybe_put_default_worktree(scheduler_opts, workspace, opts) do
    cond do
      Keyword.has_key?(scheduler_opts, :worktree) -> scheduler_opts
      Keyword.has_key?(scheduler_opts, :reconciler) -> scheduler_opts
      Keyword.has_key?(scheduler_opts, :group_reconciler) -> scheduler_opts
      not git_worktree_root?(workspace) -> scheduler_opts
      true -> Keyword.put(scheduler_opts, :worktree, default_worktree_opts(workspace, opts))
    end
  end

  # Is `workspace` a git work-tree ROOT (the repo's toplevel — primary or linked)?
  # A real `kazi apply` runs against the repo root, so `git worktree add` yields a
  # faithful checkout; a workspace that is merely a SUBDIR of some repo (e.g. a
  # test tmp dir under this checkout) is NOT a valid isolation base — isolating it
  # would branch the enclosing repo, not the workspace — so it keeps the pre-T59.9
  # in-workspace behavior. A pure local read; false for a bare/non-string dir.
  defp git_worktree_root?(workspace) when is_binary(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> Path.expand(String.trim(out)) == Path.expand(workspace)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp git_worktree_root?(_workspace), do: false

  # The default worktree opts the parallel path isolates each partition with:
  # `repo` is the workspace, `base_ref` is the explicit `--base` (nil ⇒ HEAD).
  defp default_worktree_opts(workspace, opts) do
    [repo: workspace] |> maybe_put(:base_ref, opts[:base])
  end

  # issue #936: wire the DepScheduler's `:on_frontier_complete` seam to the same
  # JSONL stream `--stream` drives for iteration events, so `apply --parallel
  # --json --stream` gets a `frontier_complete` marker at each needs-DAG wave
  # boundary. Only under BOTH --json and --stream (mirrors `maybe_put_stream/2`);
  # skipped when the caller already injected `:on_frontier_complete` (a boundary
  # test driving its own seam).
  defp maybe_put_frontier_stream(scheduler_opts, opts) do
    if opts[:json] == true and opts[:stream] == true and
         not Keyword.has_key?(scheduler_opts, :on_frontier_complete) do
      Keyword.put(scheduler_opts, :on_frontier_complete, &emit_frontier_complete_event/1)
    else
      scheduler_opts
    end
  end

  # The frontier-boundary stream event (issue #936): one JSON object per LINE
  # (JSONL), `"event": "frontier_complete"`, emitted by the DepScheduler once a
  # topological frontier fully settles and before the next frontier dispatches.
  # Distinguished from the per-iteration event by its `event` value; both
  # terminate at the same terminal result object.
  defp emit_frontier_complete_event(payload) do
    event = %{
      schema_version: @run_schema_version,
      event: "frontier_complete",
      frontier: payload.frontier,
      groups:
        Enum.map(payload.groups, fn %{id: id, status: status} -> %{id: id, status: status} end)
    }

    IO.puts(encode_json!(event))
  end

  # The per-goal loop opts the default scheduler reconciler forwards to
  # `Kazi.Runtime.run/2`: persistence + any --harness/--model overrides, mirroring
  # the serial path so a single-partition parallel run behaves like the serial run.
  defp default_parallel_run_opts(opts, persist?) do
    [persist?: persist?]
    |> maybe_put(:harness, opts[:harness])
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:effort, opts[:effort])
    |> maybe_put(:permission_mode, opts[:permission_mode])
    |> maybe_put(:allowed_tools, opts[:allowed_tools])
    |> maybe_put(:session_name, resolve_session_name(opts))
    |> maybe_put(:proposal_ref, opts[:proposal_ref])
    |> maybe_put(:allow_duplicate_run, if(opts[:allow_duplicate_run] == true, do: true))
    |> maybe_put(
      :allow_workspace_collision,
      if(opts[:allow_workspace_collision] == true, do: true)
    )
  end

  # Merge the CLI-owned per-goal opts OVER any caller-supplied `:run_opts` (tests),
  # so an explicit injected `:run_opts` keeps its keys while persistence/harness are
  # still threaded.
  defp merge_parallel_run_opts(injected, opts, persist?) when is_list(injected) do
    injected
    |> Keyword.put_new(:persist?, persist?)
    |> maybe_put(:harness, opts[:harness])
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:effort, opts[:effort])
    |> maybe_put(:permission_mode, opts[:permission_mode])
    |> maybe_put(:allowed_tools, opts[:allowed_tools])
    |> maybe_put(:proposal_ref, opts[:proposal_ref])
  end

  # The collective run's exit code: 0 only when the whole goal-set collectively
  # converged, non-zero otherwise — the same convergence-mirrors-exit contract the
  # serial run honors (concept §1, §5). A PAUSE is the requested outcome
  # (--pause-between-waves, T50.3: "exit 0 with a resumable state token"), so it
  # maps to 0, mirroring the fleet path's contract.
  defp collective_exit_code(%{collective: :converged}), do: 0
  defp collective_exit_code(%{collective: :paused}), do: 0
  defp collective_exit_code(_result), do: 1

  # Render the loop's terminal result on the requested surface (T15.3): the
  # versioned JSON result object under --json, the existing human report
  # otherwise. Both share the SAME loop result; only the OUTPUT shape differs.
  defp report_outcome(%Goal{} = goal, outcome, result, economy, workspace, json?) do
    emit(json?, run_result_json(goal, outcome, result, economy, workspace), fn ->
      report(goal, human_outcome(outcome), result, economy)
      Kazi.MCP.Nudge.maybe_print(workspace)
    end)
  end

  # The human report (T0.10) knows only `:converged` / `:stopped`. An
  # `:over_budget` stop is a non-converged terminal stop, so it renders through
  # the existing `:stopped` human line (the JSON surface carries the precise
  # `over_budget` status + the exceeded dimension in `next_action`/`budget_spent`).
  defp human_outcome(:converged), do: :converged
  defp human_outcome(_), do: :stopped

  # A pre-loop run error (an unknown provider/harness, a vacuous goal, an await
  # timeout) on the requested surface: the versioned JSON error object under
  # --json (so the orchestrator parses ONE stdout surface and branches on the
  # non-zero exit), the existing human stderr line otherwise.
  defp report_run_error(%Goal{} = goal, reason, json?) do
    message = format_run_error(reason)

    if json? do
      IO.puts(encode_json!(run_error_json(goal, reason, message)))
    else
      IO.puts(:stderr, "error: run failed: #{message}")
    end

    :ok
  end

  # T3.3d deploy wiring: merge the operator's --env into the deploy action's
  # params. No --env leaves deploy_params untouched (back-compat single-target).
  # With --env, the env atom is set on a deploy_params map merged OVER any
  # caller-supplied one, so the deepened deploy (T3.3a) selects that
  # environment's per-env target from its `envs` map.
  defp maybe_put_deploy_env(run_opts, nil), do: run_opts

  defp maybe_put_deploy_env(run_opts, env) when is_binary(env) do
    deploy_params =
      run_opts
      |> Keyword.get(:deploy_params, %{})
      |> Map.put(:env, String.to_atom(env))

    Keyword.put(run_opts, :deploy_params, deploy_params)
  end

  # T3.4d standing wiring: forward `:standing` to the runtime ONLY when the
  # `--standing` flag was given (true). A nil/false flag is left unset so the
  # goal-file's declared `standing` decides (the flag overrides, never forces off).
  defp maybe_put_standing(run_opts, true), do: Keyword.put(run_opts, :standing, true)
  defp maybe_put_standing(run_opts, _), do: run_opts

  # T48.11 (ADR-0058 §3): forward `:debrief` to the runtime ONLY when the
  # `--debrief` flag was given (true). A nil/false flag is left unset so the
  # goal-file's declared `[economy] debrief` decides (the flag overrides, never
  # forces it off).
  defp maybe_put_debrief(run_opts, true), do: Keyword.put(run_opts, :debrief, true)
  defp maybe_put_debrief(run_opts, _), do: run_opts

  # Set a run opt only when the value is present (a CLI flag was given). Keeping
  # absent flags unset means the default path is byte-identical to pre-T8.7.
  defp maybe_put(run_opts, _key, nil), do: run_opts
  defp maybe_put(run_opts, key, value), do: Keyword.put(run_opts, key, value)

  # Session identity resolution (T24-followup): --session-name is opt-in, and an
  # operator running many concurrent sessions across many projects frequently
  # forgets to pass it, leaving the fleet dashboard/read-model unable to say which
  # session a run belongs to (most runs in a live fleet had no session_name at
  # all). Resolved in priority order so nothing here changes behavior for a
  # caller who already sets one explicitly:
  #
  #   1. an explicit `--session-name` (or injected `opts[:session_name]`);
  #   2. the `KAZI_SESSION_NAME` env var (an operator's own override, pre-existing);
  #   3. `CLAUDE_CODE_SESSION_ID` -- auto-detected when kazi is dispatched as a
  #      subprocess of a Claude Code session (the orchestrator's OWN session id,
  #      set in every Claude Code subprocess's environment, distinct from
  #      `--harness`/`--model`, which name the INNER harness kazi dispatches TO).
  #   4. session provenance part 2: when this `apply` is running an APPROVED
  #      proposal ref, that proposal's OWN recorded session_name (the session
  #      that planned it) -- so an applying session naming none of its own
  #      still traces the run back to who planned it, instead of the run
  #      landing unlabeled. Only reached when 1-3 are all absent, so an
  #      applying session that names itself is never overridden by the
  #      proposal's provenance.
  #
  # A future harness-agnostic addition can extend step 3 with more orchestrator
  # session env vars as they're confirmed to exist; this only adds the one this
  # codebase's own operator environment was confirmed to set.
  @doc "Public so `Kazi.Bus` (T51.2) reuses the SAME session-identity resolution chain, instead of reinventing it."
  @spec resolve_session_name(keyword()) :: String.t() | nil
  def resolve_session_name(opts) do
    opts[:session_name] ||
      System.get_env("KAZI_SESSION_NAME") ||
      System.get_env("CLAUDE_CODE_SESSION_ID") ||
      opts[:proposal_session_name]
  end

  # T15.4 (ADR-0023 decision 3): install the JSONL streaming observer only when
  # BOTH --json and --stream were given. Without both, no `:stream` is set and the
  # run path is byte-identical to the pre-T15.4 (single result object / human)
  # path. The observer prints ONE JSON line per observation; the run's final
  # result object (T15.3) terminates the stream.
  defp maybe_put_stream(run_opts, opts) do
    if opts[:json] == true and opts[:stream] == true do
      Keyword.put(run_opts, :stream, &emit_stream_event/1)
    else
      run_opts
    end
  end

  # The per-iteration stream event (T15.4): one JSON object per LINE (JSONL), each
  # parsing independently, distinguished from the terminal result by
  # `event: "iteration"`. It renders the loop's `on_iteration` payload — iteration
  # index, the predicate VECTOR at this observation, whether the whole vector is
  # satisfied, the dispatched action (when the loop projects a budget stop), and
  # the release ref so far — so an orchestrator follows convergence live. Side
  # effect only; the runtime contains a raising observer.
  defp emit_stream_event(payload) do
    event =
      %{
        schema_version: @run_schema_version,
        event: "iteration",
        iteration: Map.get(payload, :iteration),
        predicates: predicate_vector_json(Map.get(payload, :vector)),
        converged: Map.get(payload, :converged?) == true,
        release_ref: Map.get(payload, :release_ref),
        # T34.3 (ADR-0046 §2): the per-iteration context counters — the
        # orientation/retrieval cache state + section token estimates kazi spent on
        # this dispatch's context. Always present (kazi owns the prompt).
        context: Map.get(payload, :context) || %{}
      }
      # T34.3: the tool counters, present ONLY when the harness exposed a tool-use
      # stream — an empty `tools` is omitted so absent ≠ zero (ADR-0046 §6).
      |> put_stream_tools(Map.get(payload, :tools))

    IO.puts(encode_json!(event))
  end

  # T34.3: include the `tools` counters only when non-empty (the harness reported
  # tool data); an empty map is omitted so a reader never mistakes "unreported" for
  # "zero tool calls".
  defp put_stream_tools(event, tools) when is_map(tools) and map_size(tools) > 0,
    do: Map.put(event, :tools, tools)

  defp put_stream_tools(event, _tools), do: event

  defp format_run_error({:unknown_provider_kinds, kinds}) do
    "goal names provider kind(s) this build can't evaluate: " <>
      Enum.map_join(kinds, ", ", &inspect/1)
  end

  # T8.7 (ADR-0016): an unknown --harness id (or goal-file/config harness) — name
  # the offending id and the harnesses that ARE available.
  defp format_run_error({:unknown_harness, id}) do
    "unknown harness #{inspect(id)}; available: " <>
      Enum.map_join(Kazi.Harness.Registry.ids(), ", ", &to_string/1)
  end

  defp format_run_error(:vacuous_goal),
    do:
      "goal is vacuous — every predicate already passes at t0, so there is nothing " <>
        "to build or repair. A creation/repair goal must have at least one predicate " <>
        "failing before kazi starts (concept R3); the goal is underspecified."

  defp format_run_error(:await_timeout),
    do: "the loop did not reach a terminal state within the await timeout"

  defp format_run_error({:duplicate_run, %{run_id: run_id} = live}) do
    session = if live[:session_name], do: " session=#{live[:session_name]}", else: ""

    "a LIVE run for this goal is already in flight: run #{run_id}#{session} " <>
      "workspace=#{live[:workspace]} last heartbeat #{live[:heartbeat_at]}. A second " <>
      "concurrent apply of one goal burns a second budget and races the first's " <>
      "edits. Wait for it (kazi status <goal-id>), stop it, or pass " <>
      "--allow-duplicate-run for a deliberate re-run alongside it. A dead run " <>
      "stops blocking on its own once its heartbeat goes stale (~90s)."
  end

  defp format_run_error({:workspace_collision, %{run_id: run_id} = live}) do
    session = if live[:session_name], do: " session=#{live[:session_name]}", else: ""

    "a LIVE run for a DIFFERENT goal (#{live[:goal_ref]}) already holds this " <>
      "workspace: run #{run_id}#{session} workspace=#{live[:workspace]} last " <>
      "heartbeat #{live[:heartbeat_at]}. Running a second goal against one shared " <>
      "workspace cross-contaminates their commits. Use a dedicated task worktree " <>
      "(the default), wait for the live run (kazi status), stop it, or pass " <>
      "--allow-workspace-collision to accept the co-tenancy. A dead run stops " <>
      "blocking on its own once its heartbeat goes stale (~90s)."
  end

  # T50.6 (the ADR-0065/T50.3 CLI surface): the DepScheduler's resume refusals,
  # rendered the same way the fleet path words them.
  defp format_run_error({:resume_not_found, token}),
    do: "resume token #{token} not found; re-run without it"

  defp format_run_error({:goal_changed, message}), do: "cannot resume: #{message}"

  defp format_run_error(other), do: inspect(other)

  # =============================================================================
  # status command (T15.5, ADR-0023 decision 2): report a run/proposal's state
  # =============================================================================
  #
  # `kazi status <ref>` reports the CURRENT state of a run or a proposal from the
  # read-model — no loop is driven, nothing is mutated; it is a pure read. The
  # <ref> resolves in two ways, checked in order:
  #
  #   1. a RUN's goal_ref (a goal id the loop has recorded iterations for): report
  #      its latest iteration — the predicate vector, last iteration index,
  #      whether it converged, and the observation timestamp; or
  #   2. a PROPOSAL's proposal_ref (an authoring handle): report its lifecycle
  #      state (proposed / approved / rejected), idea, and goal id.
  #
  # An unknown ref is a clear error (a JSON error envelope under --json, a human
  # stderr line otherwise) with a NON-ZERO exit, so an orchestrator branches on
  # the exit code, never on prose.
  defp execute_status(nil, opts) do
    with_read_model(opts, fn -> report_live_runs(opts) end)
  end

  defp execute_status(ref, opts) do
    with_read_model(opts, fn ->
      cond do
        (iteration = ReadModel.latest_iteration(ref)) != nil ->
          report_run_status(ref, iteration, opts)

        # T45.2 (UC-059): a ROADMAP ref resolves to its member proposals. Checked
        # before a single proposal ref (roadmap refs use a distinct `road-` prefix,
        # so they never collide).
        (members = ReadModel.list_proposed_goals_by_roadmap(ref)) != [] ->
          report_roadmap_status(ref, members, opts)

        (proposal = ReadModel.get_proposed_goal(ref)) != nil ->
          report_proposal_status(proposal, opts)

        true ->
          status_not_found(ref, opts)
      end
    end)
  end

  # Issue #1073/#857: `kazi orphans` finds every registered run whose recorded
  # `harness_child_pid` is STILL alive -- a harness dispatch that outlived its
  # controller (e.g. the launcher was killed before Layer A shipped, or a run
  # that predates this deploy). Read-only by default; `--reap` TERM/KILLs each
  # orphaned process group via the same signal shape the #857 watchdog uses.
  defp execute_orphans(opts) do
    reap? = opts[:reap] == true

    with_read_model(opts, fn ->
      results =
        RunRegistry.list()
        |> Enum.filter(&orphan_run?/1)
        |> Enum.map(fn run ->
          outcome = if reap?, do: ChildSupervisor.reap(run.harness_child_pid), else: :alive
          {run, outcome}
        end)

      emit(json?(opts), orphans_json(results, reap?), fn -> print_orphans(results, reap?) end)

      0
    end)
  end

  defp orphan_run?(run) do
    is_binary(run.harness_child_pid) and ChildSupervisor.alive?(run.harness_child_pid)
  end

  defp orphans_json(results, reap?) do
    %{
      schema_version: @run_schema_version,
      kind: "orphans",
      reaped: reap?,
      count: length(results),
      orphans: Enum.map(results, fn {run, outcome} -> orphan_json(run, outcome) end)
    }
  end

  defp orphan_json(run, outcome) do
    %{
      run_id: run.run_id,
      goal_ref: run.goal_ref,
      harness_child_pid: run.harness_child_pid,
      status: run.status,
      reap_outcome: to_string(outcome)
    }
  end

  # T60.4 (#1160): the fleet's portfolio state, composed purely from
  # Kazi.Portfolio.build/0 -- this function only renders it.
  defp execute_portfolio(opts) do
    with_read_model(opts, fn ->
      portfolio = Kazi.Portfolio.build()

      emit(json?(opts), portfolio_json(portfolio), fn ->
        print_portfolio(portfolio, opts[:full] || false)
      end)

      0
    end)
  end

  # v1 keys (schema_version, kind, planned, by_repo, fleet_remote) are byte-
  # identical to T60.4; E64/T64.3 ADDS totals / todo / blocked / rate beside them
  # (schema_version stays 2). Bucket atoms are stringified for the JSON surface.
  defp portfolio_json(portfolio) do
    %{planned: planned, by_repo: by_repo, fleet_remote: fleet_remote} = portfolio
    %{buckets: buckets, totals: totals, rate: rate} = portfolio

    %{
      schema_version: @run_schema_version,
      kind: "portfolio",
      planned: planned,
      by_repo:
        Map.new(by_repo, fn {repo, buckets} ->
          {repo, Map.new(buckets, fn {bucket, entries} -> {to_string(bucket), entries} end)}
        end),
      fleet_remote: Enum.map(fleet_remote, &Map.update!(&1, :bucket, fn b -> to_string(b) end)),
      totals: portfolio_totals_json(totals),
      todo: buckets.todo,
      blocked: Enum.map(buckets.blocked, &portfolio_blocked_json/1),
      rate: rate
    }
  end

  defp portfolio_totals_json(%{base: base, empty?: empty?, rows: rows}) do
    %{
      base: base,
      empty: empty?,
      rows: Enum.map(rows, fn r -> %{bucket: to_string(r.bucket), count: r.count, pct: r.pct} end)
    }
  end

  defp portfolio_blocked_json(entry) do
    entry
    |> Map.update(:cause, nil, &to_string/1)
    |> Map.put(:blocker, Kazi.Portfolio.blocker_label(entry))
  end

  # E64/T64.3 sitrep: a headline percentage line, then each of the five buckets
  # (top-3 one-liners + "+N more"; --full restores the complete ledger), then the
  # fleet-wide honest rate. NEVER a projected date (ADR-0046).
  @portfolio_bucket_labels [
    done: "DONE",
    running: "IN PROGRESS",
    blocked: "BLOCKED",
    todo: "TODO",
    planned: "PLANNED"
  ]

  defp print_portfolio(%{totals: totals, buckets: buckets, rate: rate}, full?) do
    IO.puts(portfolio_headline(totals))

    Enum.each(@portfolio_bucket_labels, fn {bucket, label} ->
      print_portfolio_bucket(label, Map.get(buckets, bucket, []), bucket, full?)
    end)

    print_portfolio_rate(rate)
  end

  defp portfolio_headline(%{empty?: true}), do: "nothing tracked yet"

  defp portfolio_headline(%{rows: rows}) do
    Enum.map_join(rows, " | ", fn %{bucket: bucket, count: count, pct: pct} ->
      "#{portfolio_headline_label(bucket)} #{pct}% (#{count})"
    end)
  end

  defp portfolio_headline_label(:running), do: "in-progress"
  defp portfolio_headline_label(bucket), do: to_string(bucket)

  defp print_portfolio_bucket(_label, [], _bucket, _full?), do: :ok

  defp print_portfolio_bucket(label, entries, bucket, full?) do
    IO.puts("")
    IO.puts("#{label} (#{length(entries)}):")

    shown = if full?, do: entries, else: Enum.take(entries, 3)
    Enum.each(shown, fn entry -> IO.puts("  " <> portfolio_entry_line(bucket, entry)) end)

    hidden = length(entries) - length(shown)
    if hidden > 0, do: IO.puts("  +#{hidden} more")
  end

  defp portfolio_entry_line(:done, %{goal_ref: ref}), do: ref

  defp portfolio_entry_line(:running, %{goal_ref: ref} = entry),
    do: "#{ref}\t#{Kazi.Portfolio.rate_label(Map.get(entry, :rate))}"

  defp portfolio_entry_line(:blocked, %{goal_ref: ref} = entry),
    do: "#{ref}\t#{Kazi.Portfolio.blocker_label(entry)}"

  defp portfolio_entry_line(bucket, entry) when bucket in [:todo, :planned],
    do: "#{entry.goal_id}\t#{entry.idea}"

  defp print_portfolio_rate(%{empty?: true}), do: :ok

  defp print_portfolio_rate(%{green: green, total: total, delta: delta}) do
    sign = if delta >= 0, do: "+#{delta}", else: "#{delta}"
    IO.puts("")
    IO.puts("fleet rate: #{green}/#{total} preds green, #{sign} this run")
  end

  defp print_orphans([], _reap?) do
    IO.puts("no orphaned harness processes")
  end

  defp print_orphans(results, reap?) do
    verb = if reap?, do: "reaped", else: "found"
    IO.puts("#{verb} #{length(results)} orphaned harness process(es):\n")

    Enum.each(results, fn {run, outcome} ->
      suffix = if reap?, do: "\treap=#{outcome}", else: ""

      IO.puts(
        "  #{run.goal_ref}\trun_id=#{run.run_id}\tharness_pid=#{run.harness_child_pid}" <> suffix
      )
    end)
  end

  # Report every currently LIVE run (issue #971): `status` called with NO ref is
  # the pre-upgrade check an operator runs before installing a newer
  # burrito-built kazi binary (see `docs/lore.md`, Release / CI / Burrito, for
  # why burrito's do_clean_old_versions makes this necessary). "Live" reuses
  # `RunRegistry`'s existing staleness definition (`list_live/1` — status
  # `"running"` AND a heartbeat fresher than `stale?/2`'s window) rather than
  # inventing a new one.
  defp report_live_runs(opts) do
    live_runs = RunRegistry.list_live()
    # T68.9 (#1501): the fleet-wide first-pass rate — pooled across every live
    # run's goal, a predicate-weighted read of JIT authoring quality across the
    # board. Nil when no live run has measurable iteration history.
    first_pass = live_runs_first_pass(live_runs)

    emit(json?(opts), live_runs_json(live_runs, first_pass), fn ->
      case live_runs do
        [] ->
          IO.puts("no LIVE runs (safe to install/upgrade kazi)")

        runs ->
          IO.puts("#{length(runs)} LIVE run(s):\n")

          Enum.each(runs, fn run ->
            IO.puts(
              "  #{run.goal_ref}\trun_id=#{run.run_id}\tstatus=#{run.status}\t" <>
                "heartbeat_age_s=#{heartbeat_age_seconds(run)}"
            )
          end)

          print_status_first_pass(first_pass)
      end
    end)

    0
  end

  # T68.9 (#1501): pool the first-pass summaries of every live run's goal into
  # one fleet figure. Distinct goal_refs only — two live runs sharing a goal
  # read the same iteration history, so counting it once avoids double-weighting.
  defp live_runs_first_pass(live_runs) do
    live_runs
    |> Enum.map(& &1.goal_ref)
    |> Enum.uniq()
    |> Enum.map(fn goal_ref ->
      FirstPassRate.from_history(ReadModel.iteration_history(goal_ref))
    end)
    |> FirstPassRate.aggregate()
  end

  # The `status --json` result for the no-ref live-run list (issue #971): an
  # array of `{goal_ref, run_id, status, heartbeat_age_s}`, `schema_version`-
  # tagged like every other --json surface. `kind: "live_runs"` distinguishes it
  # from the single-ref run/proposal status shapes.
  defp live_runs_json(live_runs, first_pass) do
    %{
      schema_version: @run_schema_version,
      kind: "live_runs",
      count: length(live_runs),
      runs: Enum.map(live_runs, &live_run_json/1),
      # T68.9 (#1501): the pooled fleet first-pass rate (null when unmeasurable).
      first_pass_rate: first_pass_json(first_pass)
    }
  end

  defp live_run_json(run) do
    %{
      goal_ref: run.goal_ref,
      run_id: run.run_id,
      status: run.status,
      heartbeat_age_s: heartbeat_age_seconds(run)
    }
  end

  defp heartbeat_age_seconds(%{heartbeat_at: %DateTime{} = heartbeat_at}) do
    DateTime.diff(DateTime.utc_now(), heartbeat_at, :second)
  end

  defp heartbeat_age_seconds(_run), do: nil

  # Report a RUN's current state from its latest recorded iteration (T15.5): a
  # JSON object under --json, a human block otherwise.
  defp report_run_status(ref, iteration, opts) do
    vector = ReadModel.to_predicate_vector(iteration)
    # T62.6 (issue #1241 part 2): the run's persisted per-group landed refs, so a
    # completed `--parallel` run's status shows the same per-group landing detail
    # (branch/pr/merge_commit) the immediate collective output carried. Empty for
    # a run that never landed (e.g. a single-goal run) — the surface then stays
    # byte-identical to the pre-T62.6 shape.
    landed = ReadModel.landed_refs(ref)
    # T68.9 (#1501): the predicate first-pass rate — the fraction of authored
    # predicates green on the FIRST observation vs. needing reconcile-loop
    # rework — computed from this goal's persisted iteration history.
    first_pass = FirstPassRate.from_history(ReadModel.iteration_history(ref))

    emit(json?(opts), run_status_json(ref, iteration, vector, landed, first_pass), fn ->
      IO.puts("STATUS     ref=#{ref} kind=run")
      IO.puts("converged: #{iteration.converged}")
      IO.puts("iteration: #{iteration.iteration_index}")
      maybe_status_release(iteration.release_ref)
      IO.puts("observed:  #{iteration.observed_at}")
      print_status_first_pass(first_pass)
      IO.puts("\npredicate vector:")
      IO.puts(format_vector(vector))
      print_status_landed(landed)
    end)

    0
  end

  # T68.9 (#1501): the human first-pass line, printed only when there is
  # iteration history to measure. Nothing printed for an unmeasurable goal so
  # the human block stays byte-identical to the pre-T68.9 shape there.
  defp print_status_first_pass(nil), do: :ok

  defp print_status_first_pass(%{total: total, first_pass: first_pass, rate: rate}) do
    IO.puts(
      "first-pass: #{first_pass}/#{total} (#{format_rate(rate)}) predicates green on first observation"
    )
  end

  defp format_rate(rate) when is_float(rate), do: "#{round(rate * 100)}%"

  # T62.6: the persisted per-group landed refs appended to a run's human status
  # block — one line per group, `<partition-id>: landed=<branch> pr=<pr>
  # merge=<merge_commit>`, mirroring the collective block's `landed_human/1`.
  # Nothing printed when the run recorded no landed refs.
  defp print_status_landed([]), do: :ok

  defp print_status_landed(landed) do
    IO.puts("\nlanded:")

    Enum.each(landed, fn row ->
      refs = %{branch: row.branch, pr: row.pr, merge_commit: row.merge_commit}
      IO.puts("  #{row.partition_id}#{landed_human(refs)}")
    end)
  end

  # Report a PROPOSAL's current lifecycle state (T15.5): a JSON object under
  # --json, a human block otherwise.
  defp report_proposal_status(proposal, opts) do
    emit(json?(opts), proposal_status_json(proposal), fn ->
      IO.puts("STATUS     ref=#{proposal.proposal_ref} kind=proposal")
      IO.puts("state:     #{proposal.status}")
      IO.puts("goal:      #{proposal.goal_id}")
      IO.puts("idea:      #{proposal.idea}")
    end)

    0
  end

  # An unknown status ref: a clear, machine-readable error under --json (so the
  # orchestrator parses one stdout surface and branches on the non-zero exit), a
  # human stderr line otherwise. Exit non-zero either way.
  defp status_not_found(ref, opts) do
    message =
      "no run or proposal found for ref #{inspect(ref)} " <>
        "(a run appears once it has recorded an iteration; a proposal once proposed)"

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  defp maybe_status_release(ref) when is_binary(ref) and ref != "",
    do: IO.puts("release:   #{ref}")

  defp maybe_status_release(_ref), do: :ok

  # The `status --json` result object for a RUN (T15.5): the persisted run state —
  # `status` (the lifecycle the board derives: converged / in_progress), the
  # predicate VECTOR (the same `{id, verdict}` shape as `run --json`), the last
  # iteration index, the release ref, and the observation timestamp — plus
  # `schema_version`. `kind: "run"` distinguishes it from a proposal status.
  defp run_status_json(ref, iteration, vector, landed, first_pass) do
    base = %{
      schema_version: @run_schema_version,
      kind: "run",
      ref: to_string(ref),
      status: if(iteration.converged, do: "converged", else: "in_progress"),
      converged: iteration.converged,
      iteration: iteration.iteration_index,
      predicates: predicate_vector_json(vector),
      # T68.9 (#1501): the first-pass rate object (null when unmeasurable — no
      # iteration history / empty vector), a stable key an orchestrator reads to
      # judge JIT authoring quality without re-deriving it.
      first_pass_rate: first_pass_json(first_pass),
      release_ref: iteration.release_ref,
      observed_at: status_timestamp(iteration.observed_at)
    }

    # T62.6 (issue #1241 part 2): a run that landed per-group work carries its
    # persisted `landed` refs — ADDITIVE, so a run with none (a single-goal run,
    # or a pre-T62.6 row) omits the key entirely and the object is byte-identical
    # to the pre-T62.6 status shape (regression pin).
    case landed do
      [] -> base
      rows -> Map.put(base, :landed, Enum.map(rows, &status_landed_json/1))
    end
  end

  # One persisted landed-ref row on the `status --json` surface: the group's
  # stable `partition_id` plus the T44.10 `{branch, pr, merge_commit}` shape,
  # each key present only when the run recorded it (honest-unknown, ADR-0046).
  defp status_landed_json(row) do
    %{partition_id: row.partition_id}
    |> maybe_put_ref(:branch, row.branch)
    |> maybe_put_ref(:pr, row.pr)
    |> maybe_put_ref(:merge_commit, row.merge_commit)
  end

  # T68.9 (#1501): the first-pass-rate object on a --json status surface, or
  # `nil` (JSON null) when there is nothing to measure. `rate` is a 0.0–1.0
  # float; `total`/`first_pass`/`reworked` are the counts behind it.
  defp first_pass_json(nil), do: nil

  defp first_pass_json(%{total: total, first_pass: first_pass, reworked: reworked, rate: rate}) do
    %{total: total, first_pass: first_pass, reworked: reworked, rate: rate}
  end

  # The `status --json` result object for a PROPOSAL (T15.5): its lifecycle state,
  # idea, and goal id. `kind: "proposal"` distinguishes it from a run status.
  defp proposal_status_json(proposal) do
    base = %{
      schema_version: @run_schema_version,
      kind: "proposal",
      ref: proposal.proposal_ref,
      status: proposal.status,
      goal_id: proposal.goal_id,
      idea: proposal.idea
    }

    # T45.6 (UC-059): surface `--discover` evidence only when present, so the
    # status shape is byte-identical to today's when discovery was not attached.
    if is_nil(proposal.discovery),
      do: base,
      else: Map.put(base, :discovery, proposal.discovery)
  end

  # T45.2 (UC-059): a roadmap ref resolves to its member proposals.
  defp report_roadmap_status(ref, members, opts) do
    emit(json?(opts), roadmap_status_json(ref, members), fn ->
      IO.puts("STATUS     ref=#{ref} kind=roadmap")
      IO.puts("goals:     #{length(members)}")

      Enum.each(members, fn m ->
        IO.puts("  - #{m.proposal_ref}  (#{m.goal_id})  #{m.status}")
      end)
    end)

    0
  end

  defp roadmap_status_json(ref, members) do
    %{
      schema_version: @run_schema_version,
      kind: "roadmap",
      ref: ref,
      roadmap_ref: ref,
      proposals:
        Enum.map(members, fn m ->
          %{proposal_ref: m.proposal_ref, goal_id: m.goal_id, status: m.status}
        end)
    }
  end

  defp status_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp status_timestamp(other), do: other

  # =============================================================================
  # economy command (ADR-0058): report-only economics views
  # =============================================================================
  #
  # `kazi economy [--goal <ref>] [--json]` (T48.8, ADR-0058 decision 2
  # precursor) is a PURE READ over the run-end economics T48.7 persists onto
  # `Kazi.ReadModel.Run`, aggregated into p50/p95 history groups by
  # `Kazi.Economy.History` — it drives no loop and mutates nothing. An empty
  # aggregate (a fresh read-model with no finished runs yet) is a legitimate,
  # honestly-reported answer -- `{"groups": []}` at exit 0, never an error.
  #
  # `--rediscovery <goal>` (T48.10, ADR-0058 decision 3) instead reads the
  # goal's recorded iterations back from the read-model and folds their
  # `tools` counters (T34.3) into a ranked candidate report via
  # `Kazi.Economy.Rediscovery`. Same pure-read boundary — no goal loaded, no
  # harness touched, and (the hard boundary this task pins) NOTHING here
  # feeds back into a dispatch prompt.
  defp execute_economy(opts) do
    with_read_model(opts, fn ->
      case opts[:rediscovery] do
        goal_ref when is_binary(goal_ref) ->
          execute_economy_rediscovery(goal_ref, opts)

        nil ->
          history = History.aggregate(goal_ref: opts[:goal])

          emit(json?(opts), economy_json(history, opts[:goal]), fn ->
            report_economy(history, opts[:goal])
          end)

          0
      end
    end)
  end

  # Always exit 0: unlike `status` (which looks up a specific run/proposal
  # ENTITY and errors when neither exists), this command folds "whatever
  # iterations are recorded for this ref" -- an unstarted or mistyped goal_ref
  # legitimately folds to zero iterations, and `Kazi.Economy.Rediscovery`
  # already reports that honestly as `status: "unknown"` with a reason. The
  # report's `status` field is the signal a caller branches on, not the exit
  # code.
  defp execute_economy_rediscovery(goal_ref, opts) do
    report =
      goal_ref
      |> ReadModel.list_iterations()
      |> Kazi.Economy.Rediscovery.candidates()

    emit(json?(opts), rediscovery_json(goal_ref, report), fn ->
      print_rediscovery_report(goal_ref, report)
    end)

    0
  end

  # `Kazi.Economy.Rediscovery.to_json/1` already omits `candidates` on an
  # `:unknown` report — merging its STRING-keyed map onto this ATOM-keyed
  # envelope is fine, `Jason.encode!/1` renders either key type identically.
  defp rediscovery_json(goal_ref, report) do
    %{schema_version: @run_schema_version, goal_ref: goal_ref}
    |> Map.merge(Kazi.Economy.Rediscovery.to_json(report))
  end

  defp print_rediscovery_report(goal_ref, %{status: :unknown, reason: reason}) do
    IO.puts("REDISCOVERY goal=#{goal_ref} status=unknown")
    IO.puts("reason: #{reason}")
  end

  defp print_rediscovery_report(goal_ref, %{status: :ranked, candidates: []}) do
    IO.puts("REDISCOVERY goal=#{goal_ref} status=ranked")

    IO.puts(
      "no rediscovery pressure detected (report-only; not a suggestion to change anything)."
    )
  end

  defp print_rediscovery_report(goal_ref, %{status: :ranked, candidates: candidates}) do
    IO.puts("REDISCOVERY goal=#{goal_ref} status=ranked")
    IO.puts("\nranked candidates (report-only -- feeds no prompt):")

    Enum.each(candidates, fn c ->
      IO.puts(
        "  #{c.category}: #{c.label}\n" <>
          "    recurring_calls=#{c.recurring_calls} recurring_dispatches=#{c.recurring_dispatches}/#{c.dispatches_compared} " <>
          "total_calls=#{c.total_calls} pressure=#{Float.round(c.pressure * 1.0, 3)}"
      )
    end)
  end

  # =============================================================================
  # init command (T5.5, UC-023, ADR-0013): adopt a repo by stack detection
  # =============================================================================
  #
  # `kazi init <repo-dir>` reverse-engineers a starter goal-file. The pure mapping
  # (detect/guards/to_toml) lives in Kazi.Adopt; this CLI layer threads the
  # test-only `:harness`/`:adapter_opts` seam for --enrich (so enrichment is
  # hermetically testable with a stub, never a real `claude`) and owns the file
  # IO, keeping the pure core hermetic.

  @default_stack_out "kazi.goal.toml"

  # Stack-detection source (T5.5): detect -> guards -> (optional --enrich) ->
  # to_toml -> write ONE goal-file. Default --out is <repo>/kazi.goal.toml.
  defp execute_init(repo_dir, opts, inject_opts) do
    enrich_opts = Keyword.take(inject_opts, [:harness, :adapter_opts])

    adopt_opts =
      enrich_opts
      |> Keyword.put(:enrich, opts[:enrich] == true)
      |> Keyword.put(:path, repo_dir)

    case Adopt.adopt(repo_dir, adopt_opts) do
      {:ok, adoption} ->
        goal_map = stack_goal_map(repo_dir, adoption, opts)
        out = opts[:out] || Path.join(repo_dir, @default_stack_out)
        suggestion = suggested_budget_for_predicates(Map.get(goal_map, "predicate"))

        case write_goal_file(out, Adopt.to_toml(goal_map, suggestion)) do
          0 ->
            # Both opt-in setups are additive and independent; run each and fail
            # the command if either step fails (max of the exit codes).
            mcp_code = maybe_write_mcp_config(repo_dir, opts)
            gist_code = maybe_write_gist_config(repo_dir, opts, inject_opts)
            max(mcp_code, gist_code)

          nonzero ->
            nonzero
        end

      {:error, :no_stack_detected} ->
        IO.puts(
          :stderr,
          "error: could not detect a stack in #{repo_dir} " <>
            "(no go.mod / mix.exs / package.json / pyproject.toml / setup.cfg). " <>
            "Provide a repo with a recognised marker file."
        )

        1
    end
  end

  # Assemble the single-goal map from an adoption: the detected acceptance
  # predicate, the conservative guards, and any enrichment-proposed live
  # predicates. The id is derived stably from the repo dir's basename.
  #
  # `--discover` (T41.4, ADR-0054/UC-053) swaps the predicate set: the authored
  # goal's SOLE predicate becomes the manifest-coverage check (`spec_coverage`),
  # scoped to the target repo -- RED on a repo with no `.feature` files yet. Stack
  # detection still gates the command (a repo with no marker refuses), but the
  # detected acceptance predicate + guards + enrichment are all replaced by that
  # single discovery predicate. Absent the flag, the goal-file is byte-identical
  # to before (regression guard).
  defp stack_goal_map(repo_dir, adoption, opts) do
    base = repo_dir |> Path.expand() |> Path.basename()
    id = if base in ["", ".", "/"], do: "adopted", else: "adopt-#{base}"

    {name, predicates} =
      if opts[:discover] == true do
        {"Spec-coverage discovery goal for #{base}", [Adopt.spec_coverage_predicate()]}
      else
        guards = Adopt.guards(adoption, file_reader: File, path: repo_dir)
        proposed = Map.get(adoption, :proposed, [])
        {"Adopted baseline for #{base}", [adoption.predicate | guards] ++ proposed}
      end

    %{
      "id" => id,
      "name" => name,
      "scope" => %{"workspace" => opts[:workspace] || repo_dir},
      "predicate" => predicates
    }
  end

  # T48.9 (ADR-0058 decision 2): the adopted goal's predicate COUNT (acceptance
  # + guards + any enriched live predicates) is its shape for a learned budget
  # lookup. `kazi init` has never required the read-model (ADR-0013 -- pure
  # filesystem detection); `BudgetSuggestion.suggest/2` degrades to `nil` on any
  # read-model failure, so this stays best-effort and never blocks adoption.
  defp suggested_budget_for_predicates(predicates) when is_list(predicates) do
    BudgetSuggestion.suggest(length(predicates))
  end

  defp suggested_budget_for_predicates(_predicates), do: nil

  # `--with-mcp` (T33.3, ADR-0044): after the goal-file lands, additively write the
  # canonical kazi MCP client config to the repo's `.mcp.json` so an MCP-speaking
  # harness drives kazi NATIVELY via the installed `kazi mcp` verb — no JSON-CLI
  # shell-out. Without the flag this is a no-op (exit 0). The merge preserves any
  # servers already declared.
  defp maybe_write_mcp_config(repo_dir, opts) do
    if opts[:with_mcp] do
      case Kazi.MCP.ClientConfig.ensure_in_dir(repo_dir) do
        {:ok, outcome, path} ->
          verb =
            case outcome do
              :created -> "WROTE "
              :merged -> "MERGED"
              :present -> "OK    "
            end

          IO.puts("#{verb} #{path}  (kazi MCP server -> `kazi mcp`)")
          IO.puts("\nWire an MCP-speaking harness with:")
          IO.puts("  " <> Kazi.MCP.ClientConfig.inline())
          0

        {:error, reason} ->
          IO.puts(:stderr, "error: could not write the MCP client config: #{inspect(reason)}")
          1
      end
    else
      0
    end
  end

  # `--with-gist` (T35.8, ADR-0045 §8): opt THIS repo into the Gist context store.
  # Verify `gist doctor`, write the project-local `.kazi/context.toml`, additively
  # register the `gist serve` MCP server in `.mcp.json`, and recommend KAZI_GIST_DSN
  # for cross-iteration persistence. PROJECT-LOCAL ONLY — no global agent config is
  # touched. Absent the `gist` binary, report the missing dep and exit non-zero (the
  # goal-file is already written); never crash. Without the flag this is a no-op.
  #
  # `inject_opts` threads the `:gist_bin`/`:gist_env`/`:gist_timeout_ms` test seam
  # into the doctor probe so the healthy and missing-dep paths are hermetic.
  defp maybe_write_gist_config(repo_dir, opts, inject_opts) do
    if opts[:with_gist] do
      case GistInit.doctor(gist_doctor_opts(inject_opts)) do
        {:ok, _doctor_out} ->
          write_gist_project_config(repo_dir)

        {:error, :gist_not_available} ->
          IO.puts(
            :stderr,
            "error: `gist` is not installed (not on PATH). Install it " <>
              "(https://github.com/sirerun/gist), then re-run `kazi init --with-gist`. " <>
              "The goal-file was written; no context-store config was changed."
          )

          1

        {:error, reason} ->
          IO.puts(:stderr, "error: `gist doctor` reported a problem: #{inspect(reason)}")
          1
      end
    else
      0
    end
  end

  # The doctor probe's subprocess seam: tests inject a fake `gist` binary (and its
  # env) so the verify step runs hermetically against test/support/fake_gist.sh.
  defp gist_doctor_opts(inject_opts) do
    [:gist_bin, :gist_timeout_ms]
    |> Enum.reduce([], fn key, acc ->
      case inject_opts[key] do
        nil -> acc
        val -> Keyword.put(acc, strip_gist_prefix(key), val)
      end
    end)
    |> then(fn acc ->
      case inject_opts[:gist_env] do
        nil -> acc
        env -> Keyword.put(acc, :env, env)
      end
    end)
  end

  defp strip_gist_prefix(:gist_bin), do: :gist_bin
  defp strip_gist_prefix(:gist_timeout_ms), do: :timeout_ms

  # Write both project-local artifacts (context.toml + the gist MCP server entry)
  # and print the on-ramp, including the KAZI_GIST_DSN recommendation. Either write
  # failing is reported and exits non-zero.
  defp write_gist_project_config(repo_dir) do
    with {:ok, ctx_outcome, ctx_path} <- GistInit.write_context_toml(repo_dir),
         {:ok, mcp_outcome, mcp_path} <- GistInit.ensure_mcp(repo_dir) do
      IO.puts("#{outcome_verb(ctx_outcome)} #{ctx_path}  (context-store provider -> gist)")
      IO.puts("#{outcome_verb(mcp_outcome)} #{mcp_path}  (gist MCP server -> `gist serve`)")

      IO.puts("\nThis repo is now opted into the Gist context store (project-local).")

      IO.puts("For cross-iteration persistence, set #{GistInit.dsn_env()} to a PostgreSQL DSN:")

      IO.puts("  export #{GistInit.dsn_env()}=\"postgres://USER:PASS@HOST:5432/gist\"")
      0
    else
      {:error, reason} ->
        IO.puts(
          :stderr,
          "error: could not write the Gist context-store config: #{inspect(reason)}"
        )

        1
    end
  end

  defp outcome_verb(:created), do: "WROTE "
  defp outcome_verb(:updated), do: "UPDATE"
  defp outcome_verb(:merged), do: "MERGED"
  defp outcome_verb(:present), do: "OK    "

  # Write a single goal-file (stack mode) and print the path + review hint.
  defp write_goal_file(out, toml) do
    dir = Path.dirname(out)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(out, toml) do
      IO.puts("WROTE  #{out}")
      IO.puts("\nReview the live-predicate TODO in the goal-file, then run:")
      IO.puts("  kazi apply #{out} --workspace <path>")
      0
    else
      {:error, reason} ->
        IO.puts(:stderr, "error: could not write #{out}: #{:file.format_error(reason)}")
        1
    end
  end

  # =============================================================================
  # install-skill command (T16.2, UC-031, ADR-0024 decision 1): the kazi skill
  # =============================================================================
  #
  # `kazi install-skill` writes the kazi Claude Code SKILL.md so an orchestrating
  # agent already knows the plan → approve → apply recipe (the two-tier
  # economics + branching on `next_action`). It is OPT-IN/consent-first: only this
  # explicit command writes, and a normal `kazi` run never touches ~/.claude
  # (`brew install` only PRINTS a hint to run it — the tap formula's `caveats`).
  #
  # The target dir is INJECTABLE so tests never write to the real ~/.claude:
  # `--dir <path>` wins, else `inject_opts[:skill_dir]` (the same seam pattern as
  # the other commands), else the default `~/.claude/skills/kazi`.
  defp execute_install_skill(opts, inject_opts) do
    write_opts = install_skill_opts(opts, inject_opts)

    # ADR-0077 (the ADR-0074 amendment): before writing, migrate any operator
    # `LOCAL.md` sitting inside the (possibly plugin-managed) content dir to the
    # STABLE path, never silently ignoring one. For the classic install-skill
    # channel the two paths coincide, so this is a no-op.
    report_local_migration(InstallSkill.migrate_local(write_opts))

    case InstallSkill.write(write_opts) do
      {:ok, path} ->
        dir = Path.dirname(path)
        for {name, _content} <- InstallSkill.docs(), do: IO.puts("WROTE  #{Path.join(dir, name)}")

        IO.puts("\nThe kazi skill is installed. In Claude Code, it teaches the recipe:")
        IO.puts("  plan --json → approve --json → apply --harness <cheap> --json [--stream]")
        IO.puts("then branch on the result's next_action.")

        IO.puts(
          "\nSite-specific wiring goes in #{InstallSkill.local_path(write_opts)} -- " <>
            "install-skill never touches it, and it lives at a STABLE path a plugin " <>
            "update cannot overwrite (ADR-0077)."
        )

        0

      {:error, reason} ->
        IO.puts(:stderr, "error: could not install the kazi skill: #{format_skill_error(reason)}")
        1
    end
  end

  # Resolve the install target dir, NON-DEFAULT only when given: `--dir` (operator
  # / tests) wins, else an injected `:skill_dir` (tests), else InstallSkill's own
  # default (~/.claude/skills/kazi). Returns a keyword list for `InstallSkill.write/1`.
  defp install_skill_opts(opts, inject_opts) do
    cond do
      is_binary(opts[:dir]) -> [dir: opts[:dir]]
      is_binary(inject_opts[:skill_dir]) -> [dir: inject_opts[:skill_dir]]
      true -> []
    end
  end

  defp format_skill_error(reason) when is_atom(reason), do: :file.format_error(reason)
  defp format_skill_error(reason), do: inspect(reason)

  # Report the LOCAL.md migration outcome (ADR-0077). A migration or a conflict
  # is surfaced; a no-op is silent. A conflict leaves BOTH files untouched and
  # asks the operator to merge -- never a silent clobber.
  defp report_local_migration({:ok, :noop}), do: :ok

  defp report_local_migration({:ok, {:migrated, from, to}}) do
    IO.puts("MIGRATED  #{from} -> #{to} (LOCAL.md moved to its stable path, ADR-0077)")
  end

  defp report_local_migration({:warn, {:conflict, old, new}}) do
    IO.puts(
      :stderr,
      "warning: LOCAL.md exists at BOTH #{old} (old, inside the skill dir) and " <>
        "#{new} (stable); left both untouched -- merge the old one into the stable " <>
        "one by hand, then delete the old (ADR-0077)."
    )
  end

  defp report_local_migration({:error, reason}) do
    IO.puts(:stderr, "warning: could not migrate LOCAL.md: #{format_skill_error(reason)}")
  end

  # =============================================================================
  # install-hooks command (T55.2, UC-068, ADR-0071): session-bus delivery
  # =============================================================================
  #
  # `kazi install-hooks` registers the two delivery hooks (SessionStart +
  # UserPromptSubmit -> `kazi bus hook <event>`) in the Claude Code settings,
  # the opt-in sibling of `install-skill` (same consent contract: only this
  # explicit command writes harness config). The merge/uninstall mechanics --
  # merge-never-clobber, byte-identical preservation, exact-inverse uninstall,
  # malformed-input-writes-nothing -- live in `Kazi.Teach.InstallHooks`.
  #
  # The target dir is INJECTABLE so tests never write to the real ~/.claude:
  # `--dir <path>` wins, else `inject_opts[:hooks_dir]` (the same seam pattern
  # as install-skill's :skill_dir), else the default `~/.claude`.
  defp execute_install_hooks(opts, inject_opts) do
    hooks_opts = install_hooks_opts(opts, inject_opts)

    if opts[:uninstall] do
      case InstallHooks.uninstall(hooks_opts) do
        {:ok, %{status: :unchanged, path: path}} ->
          IO.puts("UNCHANGED  #{path} (no kazi hooks installed)")
          0

        {:ok, %{status: :removed, deleted: true, path: path}} ->
          IO.puts("REMOVED  #{path} (the file install-hooks created; deleted)")
          0

        {:ok, %{status: :removed, path: path}} ->
          IO.puts("REMOVED  kazi hooks from #{path} (everything else preserved)")
          0

        {:error, message} ->
          IO.puts(:stderr, "error: #{message}")
          1
      end
    else
      case InstallHooks.install(hooks_opts) do
        {:ok, %{status: :unchanged, path: path}} ->
          IO.puts("UNCHANGED  #{path} (kazi hooks already installed)")
          0

        {:ok, %{status: :installed, path: path}} ->
          IO.puts("WROTE  #{path}")
          IO.puts("")
          IO.puts("Session-bus delivery is installed (ADR-0071/T60.3): SessionStart,")
          IO.puts("UserPromptSubmit, and Notification now run `kazi bus hook <event>` --")
          IO.puts("a silent no-op unless a `kazi daemon` is up. Re-running is a no-op;")
          IO.puts("`kazi install-hooks --uninstall` removes exactly what was added.")
          0

        {:error, message} ->
          IO.puts(:stderr, "error: #{message}")
          1
      end
    end
  end

  # Resolve the settings target dir, NON-DEFAULT only when given: `--dir`
  # (operator / tests) wins, else an injected `:hooks_dir` (tests), else
  # InstallHooks' own default (~/.claude). `--local` always carries through
  # (it picks the settings.local.json file name and, with no dir, <cwd>/.claude).
  defp install_hooks_opts(opts, inject_opts) do
    project = [project: opts[:project] || false]

    cond do
      is_binary(opts[:dir]) -> [dir: opts[:dir]] ++ project
      is_binary(inject_opts[:hooks_dir]) -> [dir: inject_opts[:hooks_dir]] ++ project
      true -> project
    end
  end

  # =============================================================================
  # mcp command (T33.1, ADR-0044): start the MCP server over stdio
  # =============================================================================
  #
  # `kazi mcp` starts the SAME `Kazi.MCP.Server` that `mix kazi.mcp` starts — the
  # one server module both entry points share through `Kazi.MCP.Stdio`, so the
  # installed binary and the development task cannot drift (ADR-0044 decision 4).
  # No new tools are introduced here: this is a distribution/packaging surface, the
  # missing leg ADR-0024 named but the installed CLI never grew.
  #
  # We bring up the read-model the same way every other command does
  # (`ensure_read_model`: burrito-safe, degrades quietly under the escript) so the
  # server's status/list-proposed tools read real persisted state — matching the
  # Mix task's `app.start`. The serve loop then reads line-delimited JSON-RPC from
  # stdin and BLOCKS until EOF; the process exit code is 0 on a clean EOF.
  #
  # `inject_opts` is forwarded to `Kazi.MCP.Stdio.serve/1`: a hermetic caller (the
  # Tier-2 boundary test) passes `boot: false` (the app is already running) and
  # `redirect_logging: false` (do not mutate the global logger) to drive the real
  # dispatch over a captured stdio without touching the read-model bootstrap or
  # the logger handlers.
  defp execute_mcp(inject_opts) do
    inject_opts
    |> Keyword.put_new(:boot, &ensure_read_model/0)
    |> Kazi.MCP.Stdio.serve()

    0
  end

  # =============================================================================
  # dashboard command (T46.4, ADR-0057): the standalone fleet-mode web endpoint
  # =============================================================================
  #
  # `kazi dashboard` boots the operator web endpoint against the shared
  # read-model + run registry with NO goal loop in the process — a pure
  # read-only projection (ADR-0011 reaffirmed at fleet scope). Home view: the
  # mission control (`KaziWeb.MissionControlLive`).
  #
  # In every entry point this process ALREADY supervises (dev, `mix test`,
  # `mix kazi.apply`), `KaziWeb.Endpoint` is already running as part of the app's
  # normal supervision tree (`Kazi.Application`) — in that case `--port`/`--bind`
  # are advisory only (the endpoint is already bound) and we just report where
  # it's serving. Only a FRESH boot (a standalone burrito/escript process with no
  # endpoint yet) actually applies the flags and starts one.
  #
  # `inject_opts[:serve_forever]` is the injectable seam (matching `execute_mcp`'s
  # `inject_opts`): production leaves the default (block forever so the process
  # keeps serving until Ctrl-C); the CLI boundary test overrides it with a no-op
  # so `run/2` returns instead of hanging.
  #
  # `--roadmap <goal-file>` (T47.2, ADR-0056/ADR-0057): the first user-visible
  # consumer of `KaziWeb.Starmap.GoalSource` — loads a REAL goal-file so mission
  # control groups ITS `needs`-DAG into wave sections instead of only a test
  # fixture's. Like `--port`/`--bind`, it's advisory-only when this process
  # already serves the endpoint (nothing to reconfigure); on a fresh boot a
  # bad/unloadable path is a LOUD boot error (non-zero exit, nothing started),
  # never a silently-empty roadmap.
  defp execute_dashboard(opts, inject_opts) do
    ensure_read_model()

    case Process.whereis(KaziWeb.Endpoint) do
      pid when is_pid(pid) ->
        if opts[:roadmap] do
          IO.puts(
            :stderr,
            "kazi dashboard: --roadmap ignored -- this process already serves mission control " <>
              "(--roadmap only takes effect on a fresh standalone boot, like --port/--bind)"
          )
        end

        http = KaziWeb.Endpoint.config(:http) || []
        serve_dashboard(:already_running, format_bind(http[:ip]), http[:port], inject_opts)

      nil ->
        case configure_roadmap(opts[:roadmap]) do
          :ok ->
            bind = opts[:bind] || "127.0.0.1"
            port = opts[:port] || 4050
            start_standalone_endpoint(bind, port)
            serve_dashboard(:booted, bind, port, inject_opts)

          {:error, reason} ->
            IO.puts(
              :stderr,
              "error: kazi dashboard: could not load --roadmap goal-file #{opts[:roadmap]}: #{reason}"
            )

            1
        end
    end
  end

  defp serve_dashboard(mode, bind, port, inject_opts) do
    case mode do
      :already_running ->
        IO.puts(
          "kazi dashboard: this process already serves mission control at http://#{bind}:#{port}/ " <>
            "(--port/--bind ignored -- they only apply to a fresh standalone boot)"
        )

      :booted ->
        IO.puts(
          "kazi dashboard: mission control (fleet view, read-only) at http://#{bind}:#{port}/ -- Ctrl-C to stop"
        )
    end

    serve_forever = Keyword.get(inject_opts, :serve_forever, fn -> Process.sleep(:infinity) end)
    serve_forever.()

    0
  end

  # =============================================================================
  # daemon command (T51.1, ADR-0067 decision point 1): the long-lived
  # per-machine daemon's lifecycle over its Unix-socket control plane.
  # =============================================================================
  #
  # `start` runs the daemon supervision tree in the FOREGROUND -- the SAME
  # convention as `kazi dashboard`: the operator backgrounds it (`&`, a
  # process manager, ...); this process just blocks until the tree stops
  # (either a clean `stop`-triggered shutdown or an external kill). `status`
  # and `stop` are pure client calls over the socket -- they never start
  # anything.
  #
  # Down/stale handling (the brief's point 4) is centralized in
  # `daemon_probe_result/2` so `status` and `stop` report it identically.
  defp execute_daemon("start", [], opts, inject_opts) do
    sock_path = Kazi.Daemon.Supervisor.default_sock_path()
    pid_path = Kazi.Daemon.Supervisor.default_pid_path()

    daemon_opts =
      [sock_path: sock_path, pid_path: pid_path]
      |> maybe_put(:nats_bin, opts[:nats_bin])
      |> maybe_put(:port, opts[:nats_port])
      |> maybe_put(:nats_host, opts[:nats_host])
      |> maybe_put(:nats_token, opts[:nats_token])

    case Kazi.Daemon.start(daemon_opts) do
      {:ok, sup_pid} ->
        IO.puts("kazi daemon listening on #{sock_path} (vsn #{version()})")

        wait_for_stop =
          Keyword.get(inject_opts, :daemon_wait, fn pid ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, _pid, _reason} -> :ok
            end
          end)

        wait_for_stop.(sup_pid)
        0

      {:error, {:already_running, vsn}} ->
        daemon_error("daemon already running (vsn #{vsn})", opts)

      {:error, :nats_bin_not_found} ->
        daemon_error(
          "nats-server binary not found (searched PATH; pass --nats-bin <path>) -- install it from https://nats.io/download/",
          opts
        )

      {:error, reason} ->
        daemon_error("could not start daemon: #{inspect(reason)}", opts)
    end
  end

  defp execute_daemon("status", [], opts, _inject_opts) do
    sock_path = Kazi.Daemon.Supervisor.default_sock_path()

    case daemon_probe_result(sock_path) do
      {:ok, resp} ->
        emit(json?(opts), resp, fn ->
          IO.puts(
            "kazi daemon: running (vsn #{resp["vsn"]}, uptime #{resp["uptime_s"]}s, pid #{resp["pid"]}#{schema_vsn_suffix(resp)})"
          )

          IO.puts("  velocity collector: #{velocity_status_line(resp["velocity"])}")
          IO.puts("  delivery projection: #{delivery_projection_line(resp["velocity"])}")
        end)

        0

      {:error, message} ->
        daemon_error(message, opts)
    end
  end

  defp execute_daemon("stop", [], opts, _inject_opts) do
    sock_path = Kazi.Daemon.Supervisor.default_sock_path()
    pid_path = Kazi.Daemon.Supervisor.default_pid_path()

    case Kazi.Daemon.Probe.probe(sock_path) do
      :missing ->
        daemon_error("no daemon running (no socket at #{sock_path})", opts)

      :dead ->
        daemon_clean_stale(sock_path, pid_path, opts)

      :alive ->
        case Kazi.Daemon.Probe.request(sock_path, %{"op" => "shutdown"}) do
          {:ok, %{"ok" => true}} ->
            emit(json?(opts), %{"ok" => true, "stopped" => true}, fn ->
              IO.puts("kazi daemon stopped")
            end)

            0

          {:ok, resp} ->
            daemon_error("daemon refused shutdown: #{inspect(resp)}", opts)

          {:error, reason} ->
            daemon_error("failed to stop daemon: #{inspect(reason)}", opts)
        end
    end
  end

  # T52.4 (ADR-0068 point 2): `daemon restart` = stop-then-start. The operator's
  # one-command remedy when a running daemon's stamped schema is skewed from the
  # binary. It REQUIRES a running daemon (errors with one clear line otherwise --
  # unlike `start`, which stands one up unconditionally): "restart" of nothing is
  # a mistake worth naming, not a silent fresh start. On a live daemon it shuts
  # the old one down, waits for the socket to free, then runs the SAME foreground
  # `start` (fresh pid, socket re-bound) -- so any `--nats-*` flags on the restart
  # carry through exactly as they would on `start`.
  defp execute_daemon("restart", [], opts, inject_opts) do
    sock_path = Kazi.Daemon.Supervisor.default_sock_path()
    pid_path = Kazi.Daemon.Supervisor.default_pid_path()

    case Kazi.Daemon.Probe.probe(sock_path) do
      :missing ->
        daemon_error("no daemon running to restart (no socket at #{sock_path})", opts)

      :dead ->
        daemon_clean_stale(sock_path, pid_path, opts)

      :alive ->
        case Kazi.Daemon.Probe.request(sock_path, %{"op" => "shutdown"}) do
          {:ok, %{"ok" => true}} ->
            wait_for_socket_free(sock_path)
            execute_daemon("start", [], opts, inject_opts)

          {:ok, resp} ->
            daemon_error("daemon refused shutdown: #{inspect(resp)}", opts)

          {:error, reason} ->
            daemon_error("failed to stop daemon for restart: #{inspect(reason)}", opts)
        end
    end
  end

  defp execute_daemon(sub, _args, opts, _inject_opts),
    do: daemon_error("unknown daemon subcommand #{inspect(sub)}", opts)

  # The shutdown ack means "accepted", not "torn down": the listener frees the
  # socket asynchronously as the tree exits. Poll (bounded) until the old daemon
  # no longer holds the socket so the fresh `start` sees `:missing`/`:dead` and
  # binds cleanly, never `:already_running`.
  defp wait_for_socket_free(sock_path, attempts \\ 40)
  defp wait_for_socket_free(_sock_path, 0), do: :ok

  defp wait_for_socket_free(sock_path, attempts) do
    case Kazi.Daemon.Probe.probe(sock_path) do
      :alive ->
        Process.sleep(25)
        wait_for_socket_free(sock_path, attempts - 1)

      _free ->
        :ok
    end
  end

  # T52.2: the daemon's stamped read-model `schema_vsn` (ADR-0068), shown when a
  # daemon reports it and omitted for an older daemon that predates the field.
  defp schema_vsn_suffix(%{"schema_vsn" => v}) when is_integer(v), do: ", schema_vsn #{v}"
  defp schema_vsn_suffix(_resp), do: ""

  # T67.6: the `kazi daemon status` line for the opt-in session-stats collector.
  # Reports real run facts only (never fabricated). A daemon older than T67.6
  # omits the field entirely -- fall back to "unknown".
  defp velocity_status_line(%{"enabled" => false}), do: "disabled"

  defp velocity_status_line(%{"enabled" => true} = v) do
    case {v["last_run_at"], v["last_session_count"]} do
      {nil, _} -> "enabled (no run yet)"
      {at, n} -> "enabled (last run #{at}, #{n} session(s))"
    end
  end

  defp velocity_status_line(_absent), do: "unknown"

  # T67.6 finding 2: the `kazi daemon status` line for the delivery projection --
  # real pass facts only (workspaces scanned, events written), never fabricated. No
  # configured workspaces (or no pass yet) reads "no workspaces configured"; a
  # daemon older than this field omits it and falls back to "unknown".
  defp delivery_projection_line(%{"last_projection" => nil}), do: "no workspaces configured"

  defp delivery_projection_line(%{"last_projection" => p}) when is_map(p) do
    "last pass #{p["at"]}, #{p["workspaces_scanned"]} workspace(s), #{p["events_written"]} event(s)"
  end

  defp delivery_projection_line(_absent), do: "unknown"

  # Shared `status` probe: `:missing` / `:dead` render the point-4 down/stale
  # messages; `:alive` pings and surfaces the raw handshake.
  defp daemon_probe_result(sock_path) do
    case Kazi.Daemon.Probe.probe(sock_path) do
      :missing ->
        {:error, "no daemon running (no socket at #{sock_path})"}

      :dead ->
        pid_path = Kazi.Daemon.Supervisor.default_pid_path()
        File.rm(sock_path)
        File.rm(pid_path)
        {:error, "daemon was not running (stale socket at #{sock_path} cleaned up)"}

      :alive ->
        case Kazi.Daemon.Probe.ping(sock_path) do
          {:ok, resp} -> {:ok, resp}
          {:error, reason} -> {:error, "daemon did not answer the ping: #{inspect(reason)}"}
        end
    end
  end

  defp daemon_clean_stale(sock_path, pid_path, opts) do
    File.rm(sock_path)
    File.rm(pid_path)
    daemon_error("daemon was not running (stale socket at #{sock_path} cleaned up)", opts)
  end

  defp daemon_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # bus command (T51.2, ADR-0067 decision point 4): the session bus verbs over
  # the daemon-supervised NATS bus. Every verb is a thin `Kazi.Bus` wrapper;
  # the shared no-daemon message and `--json` envelope live here.
  # =============================================================================
  # #1060: `bus post <text>` (one positional) DEFAULTS <kind> to `fact` -- the
  # issue's preferred fix over a required positional with no default.
  defp execute_bus("post", [text], opts), do: do_bus_post(@default_bus_kind, text, opts)

  defp execute_bus("post", [kind, text], opts) when kind in @bus_kinds,
    do: do_bus_post(kind, text, opts)

  # An EXPLICIT unknown kind is a one-line usage error enumerating the valid
  # kinds (#1060) -- distinct from the generic bus-error path since this is a
  # client-side usage mistake, never a daemon/transport error.
  defp execute_bus("post", [kind, _text], opts) when kind not in @bus_kinds,
    do: bus_error(unknown_bus_kind_error(kind), opts)

  defp execute_bus("post", _args, opts),
    do: bus_error("`bus post` requires <text> or <kind> <text>", opts)

  # T55.12: a tell answers with the message's public id -- `told <recipient>`
  # alone meant QUEUED, and left the sender no way to ask what became of it.
  # A recipient the roster calls dead (or that has no presence row at all)
  # WARNS on stderr and still sends: the send is real either way, and the
  # operator may know better than the last sweep did.
  defp execute_bus("tell", [session, text], opts) do
    case Kazi.Bus.tell(session, text, bus_call_opts(opts)) do
      {:ok, receipt} ->
        emit(
          json?(opts),
          %{
            "ok" => true,
            "schema_version" => @run_schema_version,
            "id" => receipt.id,
            "recipient" => receipt.recipient,
            "liveness" => receipt.liveness
          }
          # T65.4 (#1430): carry the renamed-notice only when the tell landed via
          # a tombstone-alias, so the JSON stays byte-identical for the common case.
          |> maybe_put_json("notice", Map.get(receipt, :notice)),
          fn ->
            warn_on_liveness(receipt)
            IO.puts("told #{receipt.recipient} (id #{receipt.id})")
            # T65.4 (#1430): the recipient was renamed and the sender used the
            # OLD name inside the grace window -- name the current name.
            if notice = Map.get(receipt, :notice), do: IO.puts(notice)
          end
        )

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp execute_bus("tell", _args, opts),
    do: bus_error("`bus tell` requires <session> <text>", opts)

  # T55.12: `bus status <id>` -- what became of a tell, from the recipient's
  # own ack state.
  defp execute_bus("status", [id], opts) do
    case Integer.parse(id) do
      {seq, ""} when seq > 0 ->
        do_bus_status(seq, opts)

      _other ->
        bus_error("`bus status` requires a message id (a positive integer)", opts)
    end
  end

  defp execute_bus("status", _args, opts),
    do: bus_error("`bus status` requires <id>", opts)

  # T55.6 (ADR-0072 decision 3): `bus get <id>` -- the deliberate pull for a
  # stubbed body. A direct stream GET by id that consumes nothing.
  defp execute_bus("get", [id], opts) do
    case Integer.parse(id) do
      {seq, ""} when seq > 0 ->
        do_bus_get(seq, opts)

      _other ->
        bus_error("`bus get` requires a message id (a positive integer)", opts)
    end
  end

  defp execute_bus("get", _args, opts),
    do: bus_error("`bus get` requires <id>", opts)

  # #1059: `bus read --peek` is non-destructive -- delegates to `Kazi.Bus.peek/1`
  # exactly like `bus peek` (kept as two entry points, one shared implementation).
  defp execute_bus("read", [], opts) do
    if opts[:peek] do
      do_bus_peek(opts)
    else
      case parse_read_since(opts[:since]) do
        {:error, message} -> bus_error(message, opts)
        {:ok, since} -> do_bus_assembled_read(opts, since: since)
      end
    end
  end

  defp execute_bus("read", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  defp execute_bus("peek", [], opts), do: do_bus_peek(opts)

  defp execute_bus("peek", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  defp execute_bus("who", [], opts) do
    # T55.11: --project/--machine filter server-side over the fetched roster;
    # --json carries `ttl_s` (and per-session `seen_s`) so the freshness
    # cutoff is data, not folklore.
    who_opts =
      bus_call_opts(opts) ++
        [
          who_team: opts[:team],
          all: opts[:all],
          who_project: opts[:project],
          who_machine: opts[:machine]
        ]

    case Kazi.Bus.who(who_opts) do
      {:ok, sessions} ->
        emit(
          json?(opts),
          %{"ok" => true, "ttl_s" => Kazi.Bus.session_ttl_s(), "sessions" => sessions},
          fn ->
            Enum.each(sessions, fn s ->
              # T55.5: a named session renders name-first -- the addressable
              # label a `bus tell` accepts -- with the raw id in parentheses.
              label =
                if s["name"], do: "#{s["name"]} (#{s["session"]})", else: s["session"]

              machine = if s["machine"], do: " machine=#{s["machine"]}", else: ""
              liveness = if s["liveness"], do: " liveness=#{s["liveness"]}", else: ""
              team = if s["team"], do: " team=#{s["team"]}", else: ""
              age = if s["age_s"], do: " seen=#{s["age_s"]}s ago", else: ""
              # T55.12: only render a depth that says something -- an empty
              # inbox is the norm and would be noise on every row.
              inbox = if s["inbox"] && s["inbox"] > 0, do: " inbox=#{s["inbox"]}", else: ""

              IO.puts(
                "#{label}#{machine} pid=#{s["pid"]}#{liveness}#{team}#{inbox}#{age} #{s["cwd"]}"
              )
            end)
          end
        )

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  # T55.4 (ADR-0073): the current-state projection. Cursor-free -- consumes
  # nothing, so a session may board every turn without draining what a read was
  # counting on.
  defp execute_bus("board", [], opts) do
    case Kazi.Bus.board(bus_call_opts(opts) ++ [claims: true]) do
      {:ok, board} ->
        emit(json?(opts), bus_board_payload(board), fn -> print_board(board, opts) end)
        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp execute_bus("board", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  # #1091: block until a NEW message arrives, then consume and print it.
  # T54.9/#1097: --since <seq|now|all> anchors what counts as new (default
  # `now` -- pending backlog never satisfies the watch).
  defp execute_bus("watch", [], opts) do
    case parse_watch_since(opts[:since]) do
      {:error, message} ->
        bus_error(message, opts)

      {:ok, since} ->
        case Kazi.Bus.watch(bus_call_opts(opts) ++ [since: since]) do
          {:ok, messages} ->
            reply = local_bus_reply(messages, opts)
            emit(json?(opts), bus_read_payload(reply), fn -> print_read_digest(reply) end)

            0

          {:error, :watch_timeout} ->
            emit(json?(opts), %{"ok" => false, "timeout" => true}, fn ->
              IO.puts(:stderr, "bus watch timed out with no messages")
            end)

            3

          {:error, reason} ->
            bus_error(reason, opts)
        end
    end
  end

  defp execute_bus("watch", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  # T65.1 (#1430): argless `bus join` DERIVES the team from the workspace's git
  # origin -- no team string typed, so the leading-dash class cannot recur.
  defp execute_bus("join", [], opts) do
    case Kazi.Bus.join_derived(bus_call_opts(opts)) do
      {:ok, %{slug: slug, source: source, notice: notice}} ->
        assign_and_report_name(slug, source, notice, true, opts)

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  # #1069: named-team membership. An explicit team argument is the deliberate
  # cross-repo override (T65.1) -- recorded `derived=false`. `bus join -- <team>`
  # reaches here with the team as a positional even when it begins with `-`.
  defp execute_bus("join", [team], opts) do
    case Kazi.Bus.join(team, Keyword.put(bus_call_opts(opts), :derived, false)) do
      :ok ->
        assign_and_report_name(team, nil, nil, false, opts)

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp execute_bus("join", _args, opts),
    do: bus_error("`bus join` takes at most one <team> argument", opts)

  defp execute_bus("leave", [], opts) do
    case Kazi.Bus.leave(bus_call_opts(opts)) do
      :ok ->
        emit(json?(opts), %{"ok" => true}, fn -> IO.puts("left team") end)
        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp execute_bus("leave", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  # T55.5 (ADR-0073 decision point 3): assign a durable, addressable name.
  defp execute_bus("name", [nickname], opts) do
    case Kazi.Bus.name(nickname, bus_call_opts(opts)) do
      :ok ->
        emit(json?(opts), %{"ok" => true, "name" => nickname}, fn ->
          IO.puts("named #{nickname}")
        end)

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp execute_bus("name", _args, opts),
    do: bus_error("`bus name` requires exactly one <nickname> argument", opts)

  # T55.2/T55.9 (ADR-0071 decisions 2/4/5): `bus hook <event>` -- the harness
  # hook entry point `install-hooks` registers (SessionStart -> `session-start`,
  # UserPromptSubmit -> `turn`). The payload lives in `Kazi.Bus.Hook`, which
  # holds the whole hook contract: ALWAYS exit 0, a silent no-op with the daemon
  # down, a hard ~2s wall-clock bound even against a HUNG daemon, and the
  # untrusted-advisory framing on anything it injects -- because a hook that
  # errors, blocks, or chatters breaks/taxes every turn of every session. An
  # unknown or missing <event> is ALSO a silent success; `kazi bus hook --help`
  # documents the events.
  defp execute_bus("hook", [event], opts), do: Kazi.Bus.Hook.run(event, bus_call_opts(opts))
  defp execute_bus("hook", _args, _opts), do: 0

  defp execute_bus("who", extra, opts),
    do: bus_error("unexpected argument(s): #{Enum.join(extra, " ")}", opts)

  # T65.3 (#1430): after a join lands the presence row, the daemon assigns the
  # session its next-free short name for the team (atomic KV allocation) and the
  # join OUTPUT reports it -- so the operator learns the session's name straight
  # from `bus join`. Assignment is idempotent, so a re-join prints the SAME name.
  defp assign_and_report_name(team, source, notice, derived?, opts) do
    case Kazi.Bus.assign_name(team, bus_call_opts(opts)) do
      {:ok, name} ->
        payload =
          %{"ok" => true, "team" => team, "derived" => derived?, "name" => name}
          |> maybe_put_json("source", source && to_string(source))

        emit(json?(opts), payload, fn ->
          IO.puts("joined #{team}#{if derived?, do: " (derived)", else: ""} as #{name}")
          if notice, do: IO.puts(notice)
        end)

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp maybe_put_json(map, _key, nil), do: map
  defp maybe_put_json(map, key, value), do: Map.put(map, key, value)

  # T55.12: the two liveness verdicts worth interrupting a send for. Both still
  # queue, so the wording says what happened AND what to check -- never
  # "failed", which would be a different lie from the one this task removes.
  defp warn_on_liveness(%{liveness: "dead-reaping", recipient: recipient}) do
    IO.puts(
      :stderr,
      "warning: #{recipient} looks dead (liveness=dead-reaping) -- queued anyway; " <>
        "check `kazi bus who --all` and `kazi bus status <id>`"
    )
  end

  defp warn_on_liveness(%{liveness: "no-presence", recipient: recipient}) do
    IO.puts(
      :stderr,
      "warning: #{recipient} has no presence row -- queued to its durable inbox; " <>
        "check `kazi bus who --all` and `kazi bus status <id>`"
    )
  end

  defp warn_on_liveness(_receipt), do: :ok

  defp do_bus_status(seq, opts) do
    case Kazi.Bus.status(seq, bus_call_opts(opts)) do
      {:ok, status} ->
        emit(
          json?(opts),
          Map.merge(status, %{"ok" => true, "schema_version" => @run_schema_version}),
          fn -> print_bus_status(status) end
        )

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp print_bus_status(status) do
    sent = if status["sent_at"], do: " sent=#{status["sent_at"]}", else: ""
    IO.puts("#{status["id"]} #{status["state"]} recipient=#{status["recipient"]}#{sent}")

    # The per-recipient breakdown is the whole point for a team fan-out; for a
    # single recipient the line above already said it, so don't repeat it.
    case status["recipients"] do
      [_single] ->
        :ok

      recipients ->
        Enum.each(recipients, fn r -> IO.puts("  #{r["session"]} #{r["state"]}") end)
    end
  end

  # T55.6: fetch and render one message by id. `Kazi.Bus.get/2` always returns
  # the FULL body; `Kazi.Bus.Digest.get_view/2` bounds it to a cheap preview
  # unless `--full` was passed -- the same 1024-byte threshold that stubbed it.
  defp do_bus_get(seq, opts) do
    case Kazi.Bus.get(seq, bus_call_opts(opts)) do
      {:ok, message} ->
        view = Kazi.Bus.Digest.get_view(message, opts[:full] || false)

        emit(
          json?(opts),
          %{"ok" => true, "schema_version" => @run_schema_version, "message" => view},
          fn -> print_bus_get(view) end
        )

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp print_bus_get(view) do
    topic = view["topic"] || "_"
    session = if view["session"], do: " session=#{view["session"]}", else: ""
    machine = if view["machine"], do: " machine=#{view["machine"]}", else: ""
    IO.puts("#{view["id"]} #{view["kind"]}/#{topic} #{view["bytes"]}B#{session}#{machine}")
    IO.puts(view["text"])

    if view["truncated"] do
      IO.puts(
        "-- preview truncated to #{byte_size(view["text"])}B of #{view["bytes"]}B; pass --full for the whole body"
      )
    end
  end

  defp do_bus_post(kind, text, opts) do
    case Kazi.Bus.post(kind, text, bus_call_opts(opts)) do
      :ok ->
        emit(json?(opts), %{"ok" => true}, fn -> IO.puts("posted") end)
        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp do_bus_peek(opts), do: do_bus_assembled_read(opts, peek: true)

  # T55.7 (ADR-0072 d5): the ONE read path. The daemon pulls the consumer,
  # aggregates, and enforces the bound; the CLI renders what came back and
  # never re-aggregates. `Kazi.Bus.read_digest/1` is the same call the MCP
  # tools and the ADR-0071 hook make, which is what keeps the three surfaces
  # from drifting apart.
  defp do_bus_assembled_read(opts, mode_opts) do
    call_opts = bus_call_opts(opts) ++ mode_opts ++ [full: opts[:full]]

    case Kazi.Bus.read_digest(call_opts) do
      {:ok, reply} ->
        emit(json?(opts), bus_read_payload(reply), fn -> print_read_digest(reply) end)

        0

      {:error, reason} ->
        bus_error(reason, opts)
    end
  end

  defp bus_call_opts(opts) do
    [
      scope: opts[:scope],
      topic: opts[:topic],
      sev: opts[:sev],
      timeout: opts[:timeout],
      session_name: opts[:session_name]
    ]
  end

  # T54.9/#1097: `bus watch --since <seq|now|all>` -> Kazi.Bus.watch/1's
  # :since option. An unrecognized value is a fail-fast usage error, never a
  # silent fallback to the default anchor.
  defp parse_watch_since(nil), do: {:ok, :now}
  defp parse_watch_since("now"), do: {:ok, :now}
  defp parse_watch_since("all"), do: {:ok, :all}

  defp parse_watch_since(value) when is_binary(value) do
    case Integer.parse(value) do
      {seq, ""} when seq >= 0 ->
        {:ok, seq}

      _other ->
        {:error,
         "invalid --since #{inspect(value)} (expected `now`, `all`, or a numeric stream sequence)"}
    end
  end

  # T55.7: `bus read --since <cursor>` (T51.4's debugging escape) replays from
  # a stream sequence. Unlike `watch --since`, `now`/`all` are not accepted:
  # a read is not a park, so "wake me on new" has no meaning here and a plain
  # `bus read` already is `--since all`. A bad value is a fail-fast usage
  # error, never a silent full read.
  defp parse_read_since(nil), do: {:ok, nil}

  defp parse_read_since(value) when is_binary(value) do
    case Integer.parse(value) do
      {seq, ""} when seq >= 0 ->
        {:ok, seq}

      _other ->
        {:error,
         "invalid --since #{inspect(value)} (expected a numeric stream sequence, e.g. `--since 42`)"}
    end
  end

  # T55.4 (ADR-0073 d1): the `bus board` --json envelope -- the current-state
  # projection under the ADR-0023 versioned contract, mirroring
  # `bus_read_payload/1`'s shape (`kazi schema bus`).
  defp bus_board_payload(board) do
    %{"ok" => true, "schema_version" => @run_schema_version, "board" => board}
  end

  # The human board: NEEDS OPERATOR first (T60.3 -- the scarcest-attention
  # section is the whole point, so it goes before facts/roster/claims), then
  # facts (topic = current value, or a stub/overflow notice), then the roster
  # (addressable identity + liveness). Empty sections say so rather than
  # rendering a blank block. `--attention` trims the render to ONLY the
  # NEEDS OPERATOR section (the full board is still what --json returns).
  defp print_board(board, opts) do
    print_board_attention(board)

    unless opts[:attention] do
      IO.puts("facts (#{board["total_facts"]} topics):")

      if board["facts"] == [] do
        IO.puts("  (none)")
      else
        Enum.each(board["facts"], &IO.puts("  " <> board_fact_line(&1)))
      end

      IO.puts("roster (#{board["total_sessions"]} sessions):")

      if board["roster"] == [] do
        IO.puts("  (none)")
      else
        Enum.each(board["roster"], &IO.puts("  " <> board_roster_line(&1)))
      end

      print_board_claims(board)
    end
  end

  # T60.3 (issue #1156): one glance answers "who is blocked on me, where, for
  # how long" across the whole fleet -- every session with a live
  # `waiting-on-operator` fact, oldest-waiting first.
  defp print_board_attention(board) do
    IO.puts("NEEDS OPERATOR (#{board["total_attention"] || 0}):")

    case board["attention"] || [] do
      [] ->
        IO.puts("  (none)")

      entries ->
        Enum.each(entries, &IO.puts("  " <> board_attention_line(&1)))
    end
  end

  defp board_attention_line(entry) do
    machine = if entry["machine"], do: "@#{entry["machine"]}", else: ""
    age = if entry["age_s"], do: " (waiting #{board_age(entry["age_s"])})", else: ""
    "#{entry["session"]}#{machine}  #{entry["summary"]}#{age}"
  end

  # ADR-0073 point 2: ownership read live from `refs/claims/*`. When the remote
  # is unreachable the section is ONE honest line -- never a possibly-stale
  # table. `claims_available`/`claims` are absent only when the caller did not
  # ask for claims (not on the `bus board` path), so the section is skipped.
  defp print_board_claims(%{"claims_available" => false}),
    do: IO.puts("claims: unavailable (remote unreachable)")

  defp print_board_claims(%{"claims_available" => true} = board) do
    IO.puts("claims (#{board["total_claims"]} held):")

    if board["claims"] == [] do
      IO.puts("  (none)")
    else
      Enum.each(board["claims"], &IO.puts("  " <> board_claim_line(&1)))
    end
  end

  defp print_board_claims(_board), do: :ok

  defp board_claim_line(claim) do
    owner = claim["owner"] || "unknown"
    host = if claim["host"], do: "@#{claim["host"]}", else: ""
    age = if claim["age_s"], do: " (#{board_age(claim["age_s"])})", else: ""
    "#{claim["task"]}: #{owner}#{host}#{age}"
  end

  # Compact age for the claims section -- the one board field that is live by
  # design (ADR-0073 point 2), so it ticks and the section is not idempotent,
  # unlike the pure fact/roster projection.
  defp board_age(s) when s < 60, do: "#{s}s"
  defp board_age(s) when s < 3600, do: "#{div(s, 60)}m"
  defp board_age(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp board_age(s), do: "#{div(s, 86_400)}d"

  defp board_fact_line(%{"type" => "overflow", "count" => count}),
    do: "... #{count} more topics"

  defp board_fact_line(%{"type" => "stub"} = line),
    do: "#{line["topic"] || "_"}: <#{line["bytes"]} bytes, id #{line["id"]}>"

  defp board_fact_line(line),
    do: "#{line["topic"] || "_"}: #{line["text"]}"

  defp board_roster_line(row) do
    label = if row["name"], do: "#{row["name"]} (#{row["session"]})", else: row["session"]
    team = if row["team"], do: " team=#{row["team"]}", else: ""
    machine = if row["machine"], do: " machine=#{row["machine"]}", else: ""
    liveness = if row["liveness"], do: " liveness=#{row["liveness"]}", else: ""
    "#{label}#{machine}#{liveness}#{team}"
  end

  # T55.7: renders the daemon's already-assembled digest. The `--full` escape
  # has no digest to render, so its TTY view is summarized locally -- the one
  # place the bound does not apply, because asking for `--full` IS asking for
  # the unabridged set.
  defp print_read_digest(%{"digest" => digest}) do
    digest |> Kazi.Bus.Digest.to_tty_lines() |> Enum.each(&IO.puts/1)
  end

  defp print_read_digest(%{"messages" => messages}) do
    print_read_digest(%{"digest" => Kazi.Bus.Digest.render(messages)})
  end

  defp print_read_digest(_reply), do: :ok

  @doc false
  # T55.1 (ADR-0072 d1/d6): the machine-readable result for `bus read|peek|
  # watch --json`. The bounded DIGEST is the default; `--full` is the
  # documented escape returning every pending message unabridged. Both shapes
  # join the ADR-0023 versioned contract (`kazi schema bus`).
  #
  # T55.7: `reply` is what the DAEMON assembled (`Kazi.Bus.read_digest/1`) --
  # this only stamps the envelope onto it. `--full` vs digest is now decided
  # by the daemon, which is why this no longer takes opts. Public so tests pin
  # the envelope.
  @spec bus_read_payload(map()) :: map()
  def bus_read_payload(reply) do
    %{"ok" => true, "schema_version" => @run_schema_version}
    |> Map.merge(Map.take(reply, ["digest", "messages"]))
  end

  @doc false
  # T55.1/T54.9: `bus watch`'s local render. A watch is a PARK, not a read --
  # the messages that woke it are already in hand, and E55 must not touch
  # `watch/1` (T54.9 owns it) -- so it shapes the same reply the daemon would
  # have returned and shares every renderer below it.
  @spec local_bus_reply([map()], keyword()) :: map()
  def local_bus_reply(messages, opts) do
    if opts[:full] do
      %{"messages" => messages}
    else
      %{"digest" => Kazi.Bus.Digest.render(messages)}
    end
  end

  defp bus_error(:no_daemon, opts),
    do: daemon_error("no daemon running -- start one with `kazi daemon start`", opts)

  # This fix: a `with_conn`-routed call (who/board/tell/...) hit its hard
  # deadline (`Kazi.Bus.run/3`) instead of hanging -- distinct from
  # `:no_daemon` because a daemon IS there, it (or the NATS round-trip) is
  # just wedged or slow past the bound.
  defp bus_error(:bus_unavailable, opts),
    do:
      daemon_error(
        "bus call timed out -- the daemon or its NATS connection may be wedged; " <>
          "try `kazi daemon status` (a stuck daemon may need a restart)",
        opts
      )

  # T55.7: the daemon answered, and refused. Distinct from `:no_daemon` --
  # "the bus is unreachable from the daemon" is a different fault from "there
  # is no daemon", and an operator who cannot tell them apart debugs the wrong
  # one.
  defp bus_error({:bus_read_failed, reason}, opts),
    do: daemon_error("daemon could not read the bus: #{reason}", opts)

  # T58.2 (#1227): the daemon's `bus_vsn` is older than this CLI requires (or
  # missing entirely -- a pre-T58.2 daemon). Caught before any op is attempted,
  # for both reads and writes, instead of writes silently succeeding while
  # reads fail with an unexplained `unknown_op`.
  defp bus_error({:daemon_protocol_skew, daemon_vsn}, opts),
    do:
      daemon_error(
        "daemon is running an older version (#{daemon_vsn}) that does not speak this " <>
          "CLI's bus protocol -- restart it: `kazi daemon stop && kazi daemon start`",
        opts
      )

  defp bus_error({:text_too_large, cap}, opts),
    do: daemon_error("message exceeds the #{cap}-byte bus cap", opts)

  # T55.5: an unaddressable recipient is a ONE-LINE error naming the live
  # roster -- never a silent queue-to-nowhere.
  defp bus_error({:unknown_recipient, recipient, roster}, opts) do
    live =
      case roster do
        [] -> "no live sessions on the bus"
        labels -> "live sessions: #{Enum.join(labels, ", ")}"
      end

    daemon_error("unknown recipient #{inspect(recipient)} -- #{live}", opts)
  end

  defp bus_error({:invalid_nickname, nickname, why}, opts),
    do: daemon_error("invalid nickname #{inspect(nickname)} -- #{why}", opts)

  # T65.2 (#1430): a name is a unique label bound to one session UUID. Binding
  # one already held by another session names the holder rather than stealing it.
  defp bus_error({:name_taken, nickname, holder}, opts),
    do:
      daemon_error(
        "name #{inspect(nickname)} is already bound to session #{holder} -- pick another name",
        opts
      )

  # T65.3 (#1430): all 26 assigned-name letters for the team are taken.
  defp bus_error({:name_pool_exhausted, team}, opts),
    do:
      daemon_error(
        "no free assigned name for team #{inspect(team)} -- all of #{team}-a..z are in use; " <>
          "attach an explicit alias with `kazi bus name <alias>`",
        opts
      )

  # T65.4 (#1430): a `tell` to a renamed name whose tombstone-alias grace window
  # has expired -- name the session's CURRENT name so the sender can re-address.
  defp bus_error({:name_tombstoned, old, current}, opts),
    do:
      daemon_error(
        "name #{inspect(old)} was renamed to #{inspect(current)} and its grace window " <>
          "has expired -- address #{inspect(current)} instead",
        opts
      )

  # T55.12: `bus status` on an id the stream cannot produce. Both causes are
  # named because they call for opposite reactions -- a typo is the sender's to
  # fix, an aged-out id means the answer is simply gone.
  defp bus_error({:unknown_message, id}, opts),
    do:
      daemon_error(
        "no message with id #{id} -- it was never posted, or it aged out of the 30-day retention",
        opts
      )

  defp bus_error({:not_directed, id, kind}, opts),
    do:
      daemon_error(
        "message #{id} is a broadcast (kind #{kind}), not a directed tell -- " <>
          "delivery status needs one recipient whose ack state can answer for it",
        opts
      )

  # T55.12: a tell whose publish the stream never acked. The old fire-and-forget
  # publish could not see this at all -- it reported success regardless.
  defp bus_error({:publish_rejected, detail}, opts),
    do: daemon_error("the bus stream rejected the message: #{inspect(detail)}", opts)

  defp bus_error({:publish_failed, reason}, opts),
    do:
      daemon_error(
        "the message was not acknowledged by the bus stream (#{inspect(reason)}) -- it may not have been stored",
        opts
      )

  defp bus_error(reason, opts), do: daemon_error("bus error: #{inspect(reason)}", opts)

  @doc """
  Loads `path` (when given) through `Kazi.Goal.Loader` — the SAME loader
  `apply` uses — and points `KaziWeb.Starmap.GoalSource` at the loaded goal via
  `KaziWeb.Starmap.GoalSource.Static` (application env is the seam: visible
  from the LiveView's separate process, unlike the process dictionary).
  Absent `--roadmap` (`path` is `nil`), this is a no-op — the default
  `GoalSource` (`None`) keeps mission control's flat-grid fallback pinned
  unchanged.

  A public seam (T47.2), mirroring `standalone_dashboard_children/0`: exercises
  the `--roadmap` load/wire-up in isolation, with no need to tear down the
  shared `KaziWeb.Endpoint` a test's own HTTP assertions depend on.
  """
  @spec configure_roadmap(Path.t() | nil) :: :ok | {:error, String.t()}
  def configure_roadmap(nil), do: :ok

  def configure_roadmap(path) do
    case Goal.Loader.load(path) do
      {:ok, goal} ->
        Application.put_env(:kazi, :starmap_roadmap_goal, goal)
        Application.put_env(:kazi, :starmap_goal_source, KaziWeb.Starmap.GoalSource.Static)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Boots a standalone endpoint (no scheduler/loop children, ADR-0057 decision 4)
  # under its own supervisor: Phoenix.PubSub, Kazi.Coordination.LeaseTable, and
  # KaziWeb.DagSource.Cache (unless already running under this process), then
  # KaziWeb.Endpoint, configured to the requested bind/port.
  #
  # Issue #801: a fresh standalone boot has no full-app tree (`Kazi.Application`)
  # behind it, so anything the dashboard reads from must be started here too --
  # notably `KaziWeb.DagSource.Cache`, whose absence was the root cause of the
  # `/dag` 500. `standalone_dashboard_children/0` is the public seam so a test
  # can assert this tree has parity with the app web tree without booting a
  # second HTTP listener.
  defp start_standalone_endpoint(bind, port) do
    base_config = Application.get_env(:kazi, KaziWeb.Endpoint, [])

    Application.put_env(
      :kazi,
      KaziWeb.Endpoint,
      standalone_endpoint_config(base_config, bind, port)
    )

    running_children =
      standalone_dashboard_children()
      |> Enum.reject(fn
        {Phoenix.PubSub, _} ->
          Process.whereis(Kazi.PubSub) != nil

        Kazi.Coordination.LeaseTable ->
          Process.whereis(Kazi.Coordination.LeaseTable) != nil

        KaziWeb.DagSource.Cache ->
          Process.whereis(KaziWeb.DagSource.Cache) != nil

        KaziWeb.Endpoint ->
          Process.whereis(KaziWeb.Endpoint) != nil

        Kazi.ReadModel.RunReaperTicker ->
          Process.whereis(Kazi.ReadModel.RunReaperTicker) != nil

        Kazi.Logging.DashboardLogRotation ->
          Process.whereis(Kazi.Logging.DashboardLogRotation) != nil
      end)

    {:ok, _pid} =
      Supervisor.start_link(running_children,
        strategy: :one_for_one,
        name: Kazi.Dashboard.Supervisor
      )

    :ok
  end

  @doc """
  The endpoint config a standalone `kazi dashboard` boot runs with, merged
  over the compiled (prod) config.

  `check_origin: :conn` pins the LiveView socket's origin check to the host
  the request itself arrived on. The compiled prod config cannot know what
  host the operator will browse — `localhost`, `127.0.0.1`, a LAN IP — and
  Phoenix's default checks the origin against the configured url host, so on
  any non-default host/port the websocket was rejected and every `phx-click`
  interaction (panel, filters, mobile tabs) silently died while the page
  still rendered. `:conn` accepts exactly the host serving the page and
  still rejects cross-site pages (CSWSH).
  """
  @spec standalone_endpoint_config(Keyword.t(), String.t(), pos_integer()) :: Keyword.t()
  def standalone_endpoint_config(base_config, bind, port) do
    secret_key_base =
      base_config[:secret_key_base] || Base.encode64(:crypto.strong_rand_bytes(48))

    Keyword.merge(base_config,
      http: [ip: parse_bind_ip(bind), port: port],
      server: true,
      secret_key_base: secret_key_base,
      check_origin: :conn
    )
  end

  @doc """
  The child specs a fresh `kazi dashboard` boot supervises, in start order:
  `Phoenix.PubSub`, then `Kazi.Coordination.LeaseTable`, then
  `KaziWeb.DagSource.Cache`, then `KaziWeb.Endpoint`, then the periodic
  maintenance tickers (`Kazi.ReadModel.RunReaperTicker`,
  `Kazi.Logging.DashboardLogRotation`) -- mirroring the app web tree's
  composition (`Kazi.Application`) so a standalone boot has the same read
  surface (issue #801) AND the same background upkeep. Both tickers
  previously lived only in `Kazi.Application`'s child list, so neither ran
  under the actual `kazi dashboard` deployment mode -- the Burrito binary's
  standalone entry (`running_standalone?/0`) hands off to the CLI before that
  supervision tree ever starts (live-verified: a synthetic zombie run sat
  unreaped across multiple ticker intervals on a released binary). This is
  the full static list; `start_standalone_endpoint/2` filters out any
  singleton already running in this node (e.g. under `mix test`) before
  starting it, so nothing is started twice.
  """
  @spec standalone_dashboard_children() :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def standalone_dashboard_children do
    [
      {Phoenix.PubSub, name: Kazi.PubSub},
      Kazi.Coordination.LeaseTable,
      KaziWeb.DagSource.Cache,
      KaziWeb.Endpoint,
      Kazi.ReadModel.RunReaperTicker,
      Kazi.Logging.DashboardLogRotation
    ]
  end

  defp parse_bind_ip(bind) do
    bind
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp format_bind({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_bind(_), do: "127.0.0.1"

  # =============================================================================
  # export command (T12.6, ADR-0020 decision 5): an Obsidian vault of the group tree
  # =============================================================================
  #
  # `kazi export <goal-file> --obsidian <dir>` loads the goal-file, walks its
  # declared group taxonomy + predicate verdicts (`Kazi.Goal.GroupTree`), and
  # writes an Obsidian VAULT to <dir>: one note per group and per predicate,
  # `[[wikilinked]]` parent↔child and tagged by verdict, an OVERVIEW note carrying
  # the per-group rollups, and a Mermaid rollup diagram. The vault content is
  # rendered PURELY by `Kazi.Export.Obsidian.render/2`; only the directory write is
  # I/O. Without a live run a goal's predicates are all pending, so the export
  # reflects the static structure. --json switches to a machine-readable summary of
  # what was written (the same `emit/3` seam as the other commands).

  defp execute_export(goal_file, opts) do
    case Goal.Loader.load(goal_file) do
      {:ok, goal} ->
        export_goal(goal, opts)

      {:error, reason} ->
        export_load_error(goal_file, reason, opts)
    end
  end

  defp export_goal(%Goal{} = goal, opts) do
    case opts[:obsidian] do
      dir when is_binary(dir) and dir != "" ->
        write_obsidian_vault(goal, dir, opts)

      _ ->
        export_input_error(
          "the `export` command requires --obsidian <dir> (the vault output directory)",
          opts
        )
    end
  end

  # Render + write the vault. Without a live run no verdicts are supplied, so the
  # vault reflects the static structure (every predicate pending) — exactly the
  # "intended, nothing built yet" reading (ADR-0020 §Decision 5).
  defp write_obsidian_vault(%Goal{} = goal, dir, opts) do
    case Obsidian.write(goal, dir) do
      {:ok, %{dir: written_dir, notes: notes}} ->
        emit(json?(opts), export_json(goal, written_dir, notes), fn ->
          report_export(goal, written_dir, notes)
        end)

        0

      {:error, reason} ->
        export_input_error(
          "could not write the Obsidian vault to #{dir}: #{:file.format_error(reason)}",
          opts
        )
    end
  end

  defp report_export(%Goal{} = goal, dir, notes) do
    IO.puts("EXPORTED   goal=#{goal.id} vault=#{dir}")
    IO.puts("notes:     #{length(notes)}")
    IO.puts("groups:    #{length(goal.groups)}")
    IO.puts("\nOpen #{dir} as an Obsidian vault to browse the group tree.")
  end

  # The `export --json` summary: what was written, so an orchestrator confirms the
  # vault and finds its notes. Carries the goal id, the vault directory, the note
  # paths, and the group/predicate/note counts, plus `schema_version`.
  defp export_json(%Goal{} = goal, dir, notes) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(goal.id),
      format: "obsidian",
      vault: dir,
      notes: notes,
      counts: %{
        notes: length(notes),
        groups: length(goal.groups),
        predicates: length(Goal.all_predicates(goal))
      }
    }
  end

  defp export_load_error(goal_file, reason, opts) do
    export_input_error("could not load goal-file #{goal_file}: #{reason}", opts)
  end

  # An export error on the requested surface: a JSON error envelope on stdout under
  # --json (so an orchestrator parses one surface and branches on the non-zero
  # exit), the existing human stderr line otherwise. Exit non-zero either way.
  defp export_input_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # lint command (T12.7, ADR-0020 decision 3): the advisory SECOND net
  # =============================================================================
  #
  # `kazi lint <goal-file>` loads the goal-file and fuzzy-compares its declared
  # group NAMES (`Kazi.Goal.GroupLint`), warning on near-duplicates — "Identity &
  # Access" vs "Identity and Access" — that the loader's id-uniqueness guard (the
  # FIRST net) cannot catch because the ids differ. It is ADVISORY: it exits 0 even
  # WITH warnings, because a name near-duplicate is a smell to review, not a load
  # error. Only a genuine load FAILURE (a missing/malformed goal-file) is a
  # non-zero exit. --json emits a machine-readable list of warnings (the same
  # `emit/3` seam as the other commands); human prose otherwise.

  # T45.5 (ADR-0075, UC-059): `plan render <roadmap>` renders the roadmap DAG as a
  # GENERATED markdown plan — a wave-sectioned WBS with a read-model-driven checkbox
  # per goal, progress counts, and a loud DO-NOT-HAND-EDIT banner — to stdout (or a
  # file via --out). The waves are the SAME `needs`-DAG frontiers `kazi apply
  # <roadmap> --explain` prints (`Kazi.Goal.Roadmap.frontiers/1`), and the
  # checkboxes are a projection of live read-model verdicts, so a re-render after a
  # verdict changes reflects the new state with no cache. Rendering never mutates
  # the read-model; when persistence is unavailable every goal renders `unknown`
  # rather than crashing.
  defp execute_plan_render(roadmap_path, opts) do
    case Kazi.Goal.Roadmap.load(roadmap_path) do
      {:ok, roadmap} ->
        markdown = Kazi.Goal.Roadmap.Render.render(roadmap, roadmap_verdicts(roadmap))
        write_rendered_plan(markdown, opts[:out])

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        1
    end
  end

  # Build the `goal-id => verdict` map the renderer projects into checkboxes. The
  # verdict is read from the read-model's latest iteration per goal; with no
  # read-model (the escript build) every goal is an HONEST `:unknown`, never a
  # fabricated `:pending` (ADR-0046 no-invented-state).
  defp roadmap_verdicts(%Kazi.Goal.Roadmap{nodes: nodes}) do
    if ensure_read_model() do
      Map.new(nodes, fn node -> {node.id, goal_verdict(node.goal.id)} end)
    else
      Map.new(nodes, fn node -> {node.id, :unknown} end)
    end
  end

  defp goal_verdict(goal_id) do
    case ReadModel.latest_iteration(goal_id) do
      %{converged: true} -> :converged
      _ -> :pending
    end
  end

  defp write_rendered_plan(markdown, nil) do
    IO.write(markdown)
    0
  end

  defp write_rendered_plan(markdown, out_path) do
    case File.write(out_path, markdown) do
      :ok ->
        IO.puts(:stderr, "wrote generated roadmap plan to #{out_path} (do not hand-edit)")
        0

      {:error, reason} ->
        IO.puts(:stderr, "error: cannot write #{out_path}: #{:file.format_error(reason)}")
        1
    end
  end

  defp execute_lint(goal_file, opts) do
    # T45.1 (ADR-0075): `lint` covers the roadmap artifact too. A file whose
    # top-level shape is a [[goals]] array is a roadmap — lint it for cycles and
    # unresolvable refs; everything else is a goal-file (the T44.1 [integration]
    # net + the group-name net below).
    if roadmap_file?(goal_file) do
      execute_roadmap_lint(goal_file, opts)
    else
      execute_goal_lint(goal_file, opts)
    end
  end

  defp execute_goal_lint(goal_file, opts) do
    # T44.1 (ADR-0055): the `[integration]` advisory net runs on the RAW decoded
    # TOML, independent of whether the goal LOADS — an unknown `mode` is a hard
    # loader error, so `kazi lint` inspects the raw block to still WARN (naming
    # the bad value) rather than only surfacing the load failure.
    {raw, integration_warnings} = lint_integration_warnings(goal_file)

    case Goal.Loader.load(goal_file) do
      {:ok, goal} ->
        report_lint(goal, GroupLint.warnings(goal), integration_warnings, opts)
        # ADVISORY: exit 0 whether or not warnings were emitted — the second net
        # never fails a goal that loads (ADR-0020 §Decision 3).
        0

      {:error, reason} ->
        if integration_warnings == [] do
          # A genuine load failure (not a lint finding) is a real error: a JSON
          # envelope under --json, a human stderr line otherwise. Exit non-zero.
          lint_load_error(goal_file, reason, opts)
        else
          # The goal does not LOAD because of the very unknown `[integration]`
          # mode we warn about. `kazi lint` is advisory: surface the warning
          # (naming the bad value) and exit 0, rather than the hard load error.
          report_integration_lint(goal_file, raw, integration_warnings, opts)
          0
        end
    end
  end

  # The raw decoded goal-file TOML plus its `[integration]` advisory warnings
  # (`Kazi.Goal.IntegrationLint`). A file/TOML read failure yields no raw map and
  # no warnings — the load below reports that failure through the normal path.
  defp lint_integration_warnings(goal_file) do
    with {:ok, contents} <- File.read(goal_file),
         {:ok, raw} <- Toml.decode(contents) do
      {raw, Kazi.Goal.IntegrationLint.warnings(raw)}
    else
      _ -> {nil, []}
    end
  end

  # A roadmap file decodes to a table with a top-level [[goals]] array of tables.
  # A read/decode failure falls through to the goal-file path, which reports the
  # real load error — this peek only ROUTES, it never fails.
  defp roadmap_file?(file) do
    with {:ok, contents} <- File.read(file),
         {:ok, %{"goals" => [%{} | _]}} <- Toml.decode(contents) do
      true
    else
      _ -> false
    end
  end

  # T45.1 (ADR-0075): lint a roadmap through the real loader. A cycle or an
  # unresolvable ref is a load ERROR (non-zero, naming the ref); a roadmap that
  # loads is a valid DAG (exit 0), reporting its node/edge/frontier counts.
  defp execute_roadmap_lint(file, opts) do
    case Kazi.Goal.Roadmap.load(file) do
      {:ok, roadmap} ->
        report_roadmap_lint(file, roadmap, opts)
        0

      {:error, reason} ->
        message = "roadmap #{file} is invalid: #{reason}"

        if json?(opts) do
          emit_json_error(message)
        else
          IO.puts(:stderr, "error: #{message}")
        end

        1
    end
  end

  defp report_roadmap_lint(file, %Kazi.Goal.Roadmap{} = roadmap, opts) do
    frontiers = Kazi.Goal.Roadmap.frontiers(roadmap)

    json = %{
      schema_version: @run_schema_version,
      kind: "roadmap",
      goal_count: length(roadmap.nodes),
      edge_count: length(roadmap.edges),
      frontier_count: length(frontiers),
      goals: Enum.map(roadmap.nodes, & &1.id)
    }

    emit(json?(opts), json, fn ->
      IO.puts(
        "LINT  roadmap=#{file} — valid DAG " <>
          "(#{length(roadmap.nodes)} goal(s), #{length(roadmap.edges)} edge(s), " <>
          "#{length(frontiers)} wave(s))."
      )
    end)
  end

  # Render the lint result on the requested surface: under --json a single object
  # carrying the warning LISTs (empty when clean); the human report otherwise.
  defp report_lint(%Goal{} = goal, warnings, integration_warnings, opts) do
    emit(json?(opts), lint_json(goal, warnings, integration_warnings), fn ->
      report_lint_human(goal, warnings)
      report_integration_warnings_human(integration_warnings)
    end)
  end

  # The advisory-only path taken when the goal does NOT load solely because of an
  # unknown `[integration]` mode: no `Goal` struct exists, so the report is built
  # from the raw map's `id` (falling back to the goal-file path).
  defp report_integration_lint(goal_file, raw, integration_warnings, opts) do
    goal_id = raw |> Map.get("id") |> lint_goal_id(goal_file)

    emit(json?(opts), integration_lint_json(goal_id, integration_warnings), fn ->
      IO.puts("LINT  goal=#{goal_id} — the goal does not load; #{lint_advisory_note()}")
      report_integration_warnings_human(integration_warnings)
    end)
  end

  defp lint_goal_id(id, _goal_file) when is_binary(id) and id != "", do: id
  defp lint_goal_id(_id, goal_file), do: Path.basename(goal_file)

  defp lint_advisory_note,
    do: "ADVISORY warning(s) below. Fix them, or the goal will not run."

  # The human lines for `[integration]` warnings: one per unknown mode, naming the
  # bad value and the known set. Empty list -> nothing printed.
  defp report_integration_warnings_human([]), do: :ok

  defp report_integration_warnings_human(integration_warnings) do
    Enum.each(integration_warnings, &report_integration_warning_human/1)
  end

  defp report_integration_warning_human(%{mode: mode}) do
    IO.puts(
      "  warning: [integration] mode #{inspect(mode)} is not a known mode " <>
        "(known: #{Kazi.Goal.IntegrationLint.known_modes()})"
    )
  end

  # T44.5: an explicit allow-list that cannot do the landing mode's git work. The
  # message names the MISSING operations, because "permissions are wrong" is not
  # actionable — "this list cannot run git commit" is.
  defp report_integration_warning_human(%{integration_mode: mode, missing_tools: missing}) do
    IO.puts(
      "  warning: [harness] allowed_tools cannot perform [integration] mode #{inspect(mode)} — " <>
        "missing #{Enum.map_join(missing, ", ", &inspect/1)}. The agent will converge the code " <>
        "and then be REFUSED at landing (the harness still exits 0, so the run stalls with no " <>
        "visible cause — issue #769). Add them, or drop allowed_tools and let kazi inject the " <>
        "mode's defaults."
    )
  end

  # The human report: a clean line when there is nothing to flag, else one line per
  # near-duplicate PAIR naming BOTH groups (id + verbatim name) and the similarity.
  defp report_lint_human(%Goal{} = goal, []) do
    IO.puts(
      "LINT  goal=#{goal.id} — no near-duplicate group names (#{length(goal.groups)} group(s))."
    )
  end

  defp report_lint_human(%Goal{} = goal, warnings) do
    IO.puts("LINT  goal=#{goal.id} — #{length(warnings)} near-duplicate group name(s):")

    Enum.each(warnings, fn %{group_ids: {id_a, id_b}, names: {name_a, name_b}, similarity: sim} ->
      IO.puts(
        "  warning: #{inspect(name_a)} (#{id_a}) ~ #{inspect(name_b)} (#{id_b})" <>
          " — similarity #{format_similarity(sim)}"
      )
    end)

    IO.puts(
      "\nThese are ADVISORY (the goal still loads). Reconcile the names, or confirm the groups are distinct."
    )
  end

  # The `lint --json` result: the near-duplicate group-name warning LIST (each
  # naming both groups + the similarity), the count, the additive
  # `integration_warnings` list (T44.1), and `schema_version`. Empty lists = no
  # findings (advisory clean); the exit code is 0 regardless (ADR-0020 §Decision 3).
  defp lint_json(%Goal{} = goal, warnings, integration_warnings) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(goal.id),
      count: length(warnings),
      warnings: Enum.map(warnings, &lint_warning_json/1),
      integration_warnings: Enum.map(integration_warnings, &integration_warning_json/1)
    }
  end

  # The `lint --json` result for the load-failed-on-bad-mode advisory path: no
  # group warnings (the goal never loaded), just the `[integration]` findings.
  defp integration_lint_json(goal_id, integration_warnings) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(goal_id),
      count: 0,
      warnings: [],
      integration_warnings: Enum.map(integration_warnings, &integration_warning_json/1)
    }
  end

  defp integration_warning_json(%{mode: mode}), do: %{mode: mode}

  # T44.5: the permission-alignment warning. Distinct keys from the mode warning
  # above, so a consumer branches on shape rather than guessing.
  defp integration_warning_json(%{
         integration_mode: mode,
         missing_tools: missing,
         allowed_tools: allowed
       }),
       do: %{integration_mode: mode, missing_tools: missing, allowed_tools: allowed}

  defp lint_warning_json(%{group_ids: {id_a, id_b}, names: {name_a, name_b}, similarity: sim}) do
    %{
      group_ids: [to_string(id_a), to_string(id_b)],
      names: [name_a, name_b],
      similarity: sim
    }
  end

  defp format_similarity(sim), do: :erlang.float_to_binary(sim, decimals: 3)

  defp lint_load_error(goal_file, reason, opts) do
    message = "could not load goal-file #{goal_file}: #{reason}"

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # spec — the Gherkin behavior-spec importer (T40.2, ADR-0050)
  # =============================================================================
  #
  # `spec import <feature-file>... --into <goal-file>` is CLI wiring over the
  # already-shipped, already-tested `Kazi.Reconcile.GherkinImporter` (ADR-0021/
  # T13.2): read the `.feature` files, derive one `test_runner` acceptance
  # predicate per Scenario (grouped by Feature), and UPSERT those predicates +
  # their groups into the target goal-file. No new grammar, no new provider —
  # only wiring, so predicates are DERIVED from a reviewed behavior spec instead
  # of hand-typed. Re-importing the same spec is an upsert (the importer derives
  # stable ids from Feature + Scenario), never a duplicate.
  defp execute_spec_import(paths, opts) do
    with {:ok, sources} <- read_feature_files(paths),
         {:ok, imported} <- import_features(sources, paths, opts),
         {:ok, base} <- load_or_init_target(opts[:into]),
         merged = merge_goal_maps(base, imported),
         {:ok, _goal} <- validate_goal_map(merged),
         :ok <- write_goal_map(opts[:into], merged) do
      upserted = predicate_ids_of(imported)
      emit_spec_import(opts, opts[:into], upserted, base != nil)
      0
    else
      {:error, message} -> spec_import_error(message, opts)
    end
  end

  # Read every positional `.feature` file into its text. A missing/unreadable
  # file is a clear error naming the path — the importer takes text, so the CLI
  # owns the filesystem read (matching `GherkinImporter`'s pure-over-text contract).
  defp read_feature_files(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, text} ->
          {:cont, {:ok, [text | acc]}}

        {:error, reason} ->
          {:halt, {:error, "could not read feature file #{path}: #{:file.format_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      other -> other
    end
  end

  # Run the sources through the importer. The goal id defaults to the target
  # goal-file's stem so a fresh import produces a legibly-named goal; when the
  # target already exists its own id wins (the merge keeps the base header).
  defp import_features(sources, paths, opts) do
    GherkinImporter.import_map(sources,
      id: goal_id_from_path(opts[:into]),
      lower: opts[:lower] || :test_runner,
      spec_paths: paths
    )
  end

  defp goal_id_from_path(path) do
    path
    |> Path.basename()
    |> String.replace(~r/\.goal\.toml$|\.toml$/, "")
    |> case do
      "" -> "gherkin-import"
      stem -> stem
    end
  end

  # The base goal map the import merges into: the EXISTING goal-file's serialized
  # map when it exists (so its id/mode/other predicates are preserved), or `nil`
  # when the target is new (the imported map becomes the whole goal-file). A
  # target that exists but does not load is a real error — refuse rather than
  # clobber an unparseable file.
  defp load_or_init_target(into) do
    if File.exists?(into) do
      case Goal.Loader.load(into) do
        {:ok, %Goal{} = goal} -> {:ok, Authoring.serialize_goal(goal)}
        {:error, reason} -> {:error, "could not load target goal-file #{into}: #{reason}"}
      end
    else
      {:ok, nil}
    end
  end

  # Merge the imported groups/predicates into the base map. A `nil` base (new
  # target) means the import IS the goal. Otherwise UPSERT by id: an imported
  # predicate/group replaces the same-id base entry in place, a new one is
  # appended, and base-only entries are kept — so a hand-authored live predicate
  # in the target survives a spec re-import.
  defp merge_goal_maps(nil, imported), do: imported

  defp merge_goal_maps(base, imported) do
    base
    |> Map.put("group", upsert_by_id(base["group"] || [], imported["group"] || []))
    |> Map.put("predicate", upsert_by_id(base["predicate"] || [], imported["predicate"] || []))
  end

  # Upsert `incoming` onto `existing` keyed by the `"id"` field: same-id entries
  # are replaced in their original position (stable order), genuinely-new entries
  # are appended in incoming order. Deterministic and total.
  defp upsert_by_id(existing, incoming) do
    incoming_by_id = Map.new(incoming, &{&1["id"], &1})

    {replaced, seen} =
      Enum.map_reduce(existing, MapSet.new(), fn item, seen ->
        id = item["id"]
        {Map.get(incoming_by_id, id, item), MapSet.put(seen, id)}
      end)

    appended = Enum.reject(incoming, &MapSet.member?(seen, &1["id"]))
    replaced ++ appended
  end

  # The merged map must load through the SAME validated loader `apply` uses — a
  # merge that produced an invalid goal (e.g. a predicate referencing an
  # undeclared group) is refused, not written.
  defp validate_goal_map(map) do
    case Goal.Loader.from_map(map) do
      {:ok, %Goal{} = goal} ->
        {:ok, goal}

      {:error, %{} = _changeset} ->
        {:error, "the imported predicates did not form a valid goal"}

      {:error, reason} when is_binary(reason) ->
        {:error, "the imported predicates did not form a valid goal: #{reason}"}
    end
  end

  # Render the merged map to a goal-file (the same scaffold-free writer `approve
  # --write` uses) and write it, creating parent directories.
  defp write_goal_map(into, map) do
    toml = Adopt.Writer.to_goal_file(map)

    with :ok <- File.mkdir_p(Path.dirname(into)),
         :ok <- File.write(into, toml) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{into}: #{:file.format_error(reason)}"}
    end
  end

  defp predicate_ids_of(%{"predicate" => predicates}) when is_list(predicates),
    do: Enum.map(predicates, & &1["id"])

  defp predicate_ids_of(_map), do: []

  # Emit the import result on the requested surface: under --json a single object
  # carrying the target path + the upserted predicate ids (ADR-0023); a human
  # summary otherwise.
  defp emit_spec_import(opts, into, upserted, merged?) do
    emit(
      json?(opts),
      %{
        ok: true,
        into: into,
        merged: merged?,
        upserted: upserted,
        count: length(upserted),
        schema_version: @run_schema_version
      },
      fn ->
        verb = if merged?, do: "upserted into", else: "wrote"
        IO.puts("IMPORTED   #{length(upserted)} predicate(s) — #{verb} #{into}")
        Enum.each(upserted, fn id -> IO.puts("  + #{id}") end)
        IO.puts("The goal is now runnable: kazi apply #{into} --workspace <path>")
      end
    )
  end

  defp spec_import_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # context — the context-store wrapper (T35.7, ADR-0045)
  # =============================================================================
  #
  # A THIN wrapper over the `Kazi.ContextStore` provider behaviour so users learn
  # ONE CLI (`kazi context index|search|stats`) instead of a separate provider
  # tool — the provider (the `gist` binary, via `Kazi.ContextStore.GistCLI`) stays
  # independently usable. These subcommands re-derive NO provider logic: each
  # resolves a store and proxies straight through `Kazi.ContextStore.{index,
  # search,stats}`, the same seam the loop wiring uses. `--json` emits a single,
  # parseable JSON object on stdout (no human prose interleaved); the default is
  # human prose. `inject_opts[:context_store_opts]` is the test seam that points
  # the provider at a fake binary; production passes none (the real `gist` + env
  # DSN are used).
  defp execute_context(subcommand, args, opts, inject_opts) do
    case context_store(opts, inject_opts) do
      {:ok, store} -> run_context(subcommand, args, store, opts)
      {:error, message} -> context_error(message, opts)
    end
  end

  # Resolve the `--provider` name (default `gist`) to a `{module, init_opts}`
  # store. Unknown providers are a clear error, not a crash. The init opts come
  # from the test seam (a fake `gist`); production gets `[]` so the GistCLI uses
  # the real binary and the `KAZI_GIST_DSN` / `GIST_DSN` env it reads itself.
  defp context_store(opts, inject_opts) do
    provider_opts = Keyword.get(inject_opts, :context_store_opts, [])

    case Keyword.get(opts, :provider, "gist") do
      "gist" ->
        {:ok, {GistCLI, provider_opts}}

      other ->
        {:error,
         "unknown context provider #{inspect(other)} (currently only `gist` is supported)"}
    end
  end

  # `context stats` — proxy to `stats/1` and report the byte accounting.
  defp run_context("stats", [], store, opts) do
    case ContextStore.stats(context_store: store) do
      {:ok, stats} ->
        emit(json?(opts), context_stats_json(stats), fn -> print_context_stats(stats) end)
        0

      {:error, reason} ->
        context_error(context_error_message(reason), opts)
    end
  end

  defp run_context("stats", extra, _store, opts),
    do:
      context_error(
        "`context stats` takes no positional arguments (got: #{Enum.join(extra, " ")})",
        opts
      )

  # `context search "<query>" [--budget N]` — proxy to `search/3` and report the
  # budget-fitting snippets. A missing budget means "the provider's own default"
  # (the store treats budget 0 as no explicit cap).
  defp run_context("search", [query], store, opts) do
    case context_budget(opts) do
      {:ok, budget} ->
        case ContextStore.search(query, budget, context_store: store) do
          {:ok, snippets} ->
            emit(json?(opts), context_search_json(query, budget, snippets), fn ->
              print_context_search(query, snippets)
            end)

            0

          {:error, reason} ->
            context_error(context_error_message(reason), opts)
        end

      {:error, message} ->
        context_error(message, opts)
    end
  end

  defp run_context("search", [], _store, opts),
    do: context_error("`context search` requires a <query> argument (quote it)", opts)

  defp run_context("search", [_query | extra], _store, opts),
    do:
      context_error(
        "unexpected argument(s) after the search query: #{Enum.join(extra, " ")}",
        opts
      )

  # `context index <label> <file>` — read the artifact at <file> and proxy to
  # `index/3` under the stable source <label>.
  defp run_context("index", [label, file], store, opts) do
    case File.read(file) do
      {:ok, content} ->
        case ContextStore.index(label, content, context_store: store) do
          {:ok, result} ->
            emit(json?(opts), context_index_json(label, result), fn ->
              print_context_index(label, result)
            end)

            0

          {:error, reason} ->
            context_error(context_error_message(reason), opts)
        end

      {:error, posix} ->
        context_error(
          "could not read <file> #{file}: #{:file.format_error(posix)}",
          opts
        )
    end
  end

  defp run_context("index", args, _store, opts) when length(args) < 2,
    do: context_error("`context index` requires a <label> and a <file> argument", opts)

  defp run_context("index", [_label, _file | extra], _store, opts),
    do: context_error("unexpected argument(s) after <file>: #{Enum.join(extra, " ")}", opts)

  # The search byte budget: absent ⇒ 0 (the provider's own default); a negative
  # budget is a usage error (the store requires a non-negative cap).
  defp context_budget(opts) do
    case Keyword.get(opts, :budget) do
      nil -> {:ok, 0}
      n when is_integer(n) and n >= 0 -> {:ok, n}
      n -> {:error, "--budget must be a non-negative integer (got: #{inspect(n)})"}
    end
  end

  # The `context <sub> --json` envelopes: a single parseable object per subcommand,
  # carrying `command`/`subcommand` (so an orchestrator routes the result) and the
  # `schema_version` pin shared with the other --json surfaces.
  defp context_stats_json(stats) do
    %{
      schema_version: @run_schema_version,
      command: "context",
      subcommand: "stats",
      provider: to_string(stats.provider),
      indexed_bytes: stats.indexed_bytes,
      returned_bytes: stats.returned_bytes,
      saved_bytes: stats.saved_bytes
    }
  end

  defp context_search_json(query, budget, snippets) do
    %{
      schema_version: @run_schema_version,
      command: "context",
      subcommand: "search",
      query: query,
      budget: budget,
      count: length(snippets),
      snippets: Enum.map(snippets, &Snippet.to_serializable/1)
    }
  end

  defp context_index_json(label, result) do
    %{
      schema_version: @run_schema_version,
      command: "context",
      subcommand: "index",
      label: Map.get(result, :label, label),
      bytes: Map.get(result, :bytes, 0),
      chunks: Map.get(result, :chunks)
    }
  end

  defp print_context_stats(stats) do
    IO.puts(
      "CONTEXT  provider=#{stats.provider}  indexed=#{stats.indexed_bytes} B" <>
        "  returned=#{stats.returned_bytes} B  saved=#{stats.saved_bytes} B"
    )
  end

  defp print_context_search(query, []) do
    IO.puts("CONTEXT  no snippets for #{inspect(query)}.")
  end

  defp print_context_search(query, snippets) do
    IO.puts("CONTEXT  #{length(snippets)} snippet(s) for #{inspect(query)}:")

    Enum.each(snippets, fn %Snippet{} = s ->
      source = s.source || "(unattributed)"
      IO.puts("  [#{source}] #{s.bytes} B")
      IO.puts(s.text)
    end)
  end

  defp print_context_index(label, result) do
    chunks = Map.get(result, :chunks)
    chunk_note = if is_integer(chunks), do: " (#{chunks} chunk(s))", else: ""
    IO.puts("CONTEXT  indexed #{label}: #{Map.get(result, :bytes, 0)} B#{chunk_note}")
  end

  # Translate the provider's error shapes (Kazi.ContextStore.GistCLI) into a clear
  # operator-facing line. The "binary not available" case is the common one — a
  # machine without `gist` — and gets a fix hint, never a stack trace.
  defp context_error_message(:gist_not_available),
    do:
      "the context-store provider is unavailable: the `gist` binary is not on PATH " <>
        "(install gist, or run without the `context` command — the store is off by default)"

  defp context_error_message({:gist_timeout, ms}),
    do: "the context-store provider timed out after #{ms} ms"

  defp context_error_message({kind, code, output})
       when kind in [:gist_index_failed, :gist_search_failed, :gist_stats_failed],
       do: "the context-store provider failed (#{kind}, exit #{code}): #{output}"

  defp context_error_message({:gist_raised, message}),
    do: "the context-store provider raised: #{message}"

  defp context_error_message(reason), do: "the context-store provider errored: #{inspect(reason)}"

  # The error surface shared by the `context` subcommands: a JSON error envelope on
  # stdout under --json (the NON-INTERACTIVE contract), a human stderr line
  # otherwise; a stable non-zero exit either way.
  defp context_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # memory recall (ADR-0062): `memory recall <query> [--budget N] [--json]`
  # =============================================================================
  #
  # The loop's own third surface for `Kazi.Memory.SemanticIndex.recall/3`
  # (decision 3: "surfaced three ways, all the same function") — an operator or
  # orchestrating agent runs the SAME budgeted recall the dispatch-time
  # injection uses (T39.x), against a real workspace.

  defp execute_memory(subcommand, args, opts) do
    with_read_model(opts, fn -> run_memory(subcommand, args, opts) end)
  end

  # `memory recall "<query>" [--budget N] [--workspace <path>]` — proxy to
  # `SemanticIndex.recall/3` and report the ranked, budget-fitted snippets.
  defp run_memory("recall", [query], opts) do
    workspace = Keyword.get(opts, :workspace, ".")
    budget = Keyword.get(opts, :budget) || 0
    snippets = SemanticIndex.recall(query, budget, workspace: workspace)

    emit(json?(opts), memory_recall_json(query, budget, snippets), fn ->
      print_memory_recall(query, snippets)
    end)

    0
  end

  defp run_memory("recall", [], opts),
    do: memory_error("`memory recall` requires a <query> argument (quote it)", opts)

  defp run_memory("recall", [_query | extra], opts),
    do:
      memory_error(
        "unexpected argument(s) after the recall query: #{Enum.join(extra, " ")}",
        opts
      )

  # `memory list-proposed [--status <state>] [--json]`: the ADR-0063 review
  # queue -- candidates `Kazi.Memory.Harvest` proposed at run termination,
  # never anything the corpus already holds.
  defp run_memory("list-proposed", [], opts) do
    with_read_model(opts, fn ->
      rows = ReadModel.list_proposed_memories(memory_list_filter(opts[:status]))

      emit(json?(opts), memory_list_proposed_json(rows, opts[:status]), fn ->
        report_proposed_memories(rows, opts[:status])
      end)

      0
    end)
  end

  # `memory approve <proposal-ref> [--json]`: transition proposed → approved
  # AND write the entry into its routed corpus file (`Kazi.Memory.Promote`) --
  # an ordinary working-tree edit; kazi never commits it (ADR-0063 decision 3).
  defp run_memory("approve", [proposal_ref], opts) do
    with_read_model(opts, fn ->
      workspace = Keyword.get(opts, :workspace, ".")

      with {:ok, approved} <- ReadModel.transition_proposed_memory(proposal_ref, "approved"),
           {:ok, path} <- Kazi.Memory.Promote.promote(approved, workspace) do
        emit(json?(opts), memory_approval_json("approved", approved, path), fn ->
          IO.puts("APPROVED   proposal=#{proposal_ref}")
          IO.puts("promoted -> #{path}")
          IO.puts("Review the diff and land it like any other doc change (ADR-0034).")
        end)

        0
      else
        {:error, reason} -> memory_transition_error("approve", proposal_ref, reason, opts)
      end
    end)
  end

  # `memory reject <proposal-ref> [--json]`: transition proposed → rejected
  # (declined, kept for audit -- the fingerprint is never re-proposed).
  defp run_memory("reject", [proposal_ref], opts) do
    with_read_model(opts, fn ->
      case ReadModel.transition_proposed_memory(proposal_ref, "rejected") do
        {:ok, rejected} ->
          emit(json?(opts), memory_approval_json("rejected", rejected, nil), fn ->
            IO.puts("REJECTED   proposal=#{proposal_ref}")
          end)

          0

        {:error, reason} ->
          memory_transition_error("reject", proposal_ref, reason, opts)
      end
    end)
  end

  defp memory_recall_json(query, budget, snippets) do
    %{
      schema_version: @run_schema_version,
      command: "memory",
      subcommand: "recall",
      query: query,
      budget: budget,
      count: length(snippets),
      snippets: Enum.map(snippets, &memory_snippet_json/1)
    }
  end

  defp memory_snippet_json(%{path: path, line: line, text: text, score: score}) do
    %{"path" => path, "line" => line, "text" => text, "score" => score}
  end

  defp print_memory_recall(query, []) do
    IO.puts("no recalled snippets for #{inspect(query)}")
  end

  defp print_memory_recall(query, snippets) do
    IO.puts("recall #{inspect(query)} — #{length(snippets)} snippet(s):\n")

    Enum.each(snippets, fn %{path: path, line: line, text: text} ->
      IO.puts("### #{path}:#{line}\n#{text}\n")
    end)
  end

  # The error surface for `memory` subcommands: a JSON error envelope on stdout
  # under --json (the NON-INTERACTIVE contract — never a prompt), a human
  # stderr line otherwise; a stable non-zero exit either way. Mirrors
  # `context_error/2`.
  defp memory_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # memory list-proposed / approve / reject (ADR-0063 Slice 3, gated harvest)
  # =============================================================================
  #
  # `Kazi.Memory.Harvest` proposes candidate memory entries controller-side, at
  # run termination — never directly into the corpus. These three verbs are the
  # human review gate: browse the queue, then approve (which ALSO writes the
  # entry into its routed corpus file, `Kazi.Memory.Promote` — an ordinary
  # working-tree edit the operator reviews and lands like any other doc change)
  # or reject (declined, kept for audit — never re-proposed).

  defp memory_list_filter(nil), do: []
  defp memory_list_filter(status), do: [status: status]

  defp memory_transition_error(verb, proposal_ref, reason, opts),
    do: memory_error("could not #{verb} #{proposal_ref}: #{format_memory_error(reason)}", opts)

  defp format_memory_error(:not_found), do: "no proposal carries that ref"

  defp format_memory_error({:invalid_transition, from, to}),
    do: "cannot transition a #{from} proposal to #{to}"

  defp format_memory_error(%Ecto.Changeset{} = changeset),
    do: "could not persist the transition: #{inspect(changeset.errors)}"

  defp format_memory_error(other), do: inspect(other)

  defp report_proposed_memories([], status) do
    IO.puts("(no #{status || "proposed-memory"} proposals)")
  end

  defp report_proposed_memories(rows, status) do
    IO.puts("#{length(rows)} #{status || "proposed-memory"} proposal(s):\n")

    Enum.each(rows, fn %ProposedMemory{} = row ->
      IO.puts("  #{row.status}\t#{row.proposal_ref}\t#{row.class}\t-> #{row.target_doc}")
      IO.puts("    #{row.content}")
    end)
  end

  defp memory_list_proposed_json(rows, status_filter) do
    %{
      schema_version: @run_schema_version,
      command: "memory",
      subcommand: "list-proposed",
      status_filter: status_filter,
      count: length(rows),
      proposals: Enum.map(rows, &proposed_memory_json/1)
    }
  end

  defp proposed_memory_json(%ProposedMemory{} = row) do
    %{
      proposal_ref: row.proposal_ref,
      fingerprint: row.fingerprint,
      status: row.status,
      class: row.class,
      goal_ref: row.goal_ref,
      run_id: row.run_id,
      target_doc: row.target_doc,
      content: row.content,
      evidence: row.evidence
    }
  end

  defp memory_approval_json(status, %ProposedMemory{} = row, path) do
    %{
      schema_version: @run_schema_version,
      command: "memory",
      subcommand: status,
      proposal_ref: row.proposal_ref,
      status: status,
      class: row.class,
      target_doc: row.target_doc,
      promoted_to: path
    }
  end

  # =============================================================================
  # authoring commands (T3.5c, UC-017): propose / list-proposed / approve / reject
  # =============================================================================
  #
  # Each drives `Kazi.Authoring` (T3.5a/b) — the one WRITE path the operator
  # surfaces share — over the read-model the loop also persists to. They need a
  # live read-model (proposals are persisted/queried), so each ensures it first
  # and refuses cleanly if it is unavailable rather than crashing.

  # `propose "<idea>"`: draft a goal from a prose idea, persist it as `proposed`,
  # and print the proposal-ref the operator approves against. `inject_opts` carries
  # the test-only `:harness`/`:adapter_opts` seam (default the real adapter), so
  # production never names a concrete harness.
  # T11.6 (ADR-0019): `propose` runs the interactive clarify phase when a TTY is
  # attached (and not `--yes`), so the author answers high-leverage questions
  # before the draft. `--yes`/no-TTY drafts best-effort; `--strict` refuses an
  # underspecified idea non-interactively; `--adr` also writes an ADR-lite doc.
  # Tests inject `:ask`/`:review` via `inject_opts` instead of touching stdin.
  #
  # T15.2 (ADR-0023 decision 4): propose has TWO drive modes, both over this one
  # `Kazi.Authoring` write path. caller-drafts — predicates supplied
  # (--predicates / stdin under --json) — skips the harness entirely; kazi only
  # applies the deterministic floor + the gate. kazi-drafts — the existing path —
  # spawns the harness to draft. Either mode emits a single JSON object under
  # --json; human prose otherwise.
  defp execute_propose(idea, opts, inject_opts) do
    with_read_model(opts, fn ->
      # T45.2 (UC-059): `plan --project '<goals-json>'` carries a MULTI-GOAL roadmap
      # payload directly (mirroring how `--predicates` carries a single goal).
      if is_binary(opts[:project]) and opts[:project] != "" do
        caller_drafts_project(opts[:project], opts, inject_opts)
      else
        case caller_proposal(opts, inject_opts) do
          {:ok, payload} -> caller_drafts(idea, payload, opts, inject_opts)
          :none -> kazi_drafts(idea, opts, inject_opts)
          {:error, message} -> propose_input_error(message, opts)
        end
      end
    end)
  end

  # T45.2 (UC-059): the caller-drafts PROJECT path — a multi-goal roadmap payload
  # (`{"goals":[...]}`) persisted as N linked proposals sharing one roadmap ref,
  # via `Kazi.Authoring.propose_roadmap/2`. Each goal runs the per-goal floor
  # (byte-identical to a single-goal plan); the roadmap runs the roadmap-scope
  # floor. `--json` emits the roadmap ref + per-goal proposal refs.
  defp caller_drafts_project(payload, opts, inject_opts) do
    case Jason.decode(payload) do
      {:ok, %{} = map} ->
        propose_opts =
          inject_opts
          |> Keyword.take([:harness, :adapter_opts])
          |> Keyword.put(:workspace, opts[:workspace] || ".")
          |> Keyword.put(:replace, opts[:replace] || false)
          |> Keyword.put(:session_name, resolve_session_name(opts))

        case Authoring.propose_roadmap(map, propose_opts) do
          {:ok, result} ->
            emit(json?(opts), roadmap_json(result), fn -> report_roadmap(result) end)
            0

          {:error, reason} ->
            propose_error(reason, opts)
        end

      {:ok, _other} ->
        propose_input_error(
          "--project payload must be a JSON object with a \"goals\" array",
          opts
        )

      {:error, _} ->
        propose_input_error("supplied --project payload is not valid JSON", opts)
    end
  end

  defp roadmap_json(result) do
    %{
      schema_version: @run_schema_version,
      kind: "roadmap",
      roadmap_ref: result.roadmap_ref,
      proposals:
        Enum.map(result.proposals, fn draft ->
          %{
            proposal_ref: draft.proposal_ref,
            goal_id: to_string(draft.goal.id),
            status: to_string(draft.status),
            clarify: clarify_json(draft)
          }
        end),
      clarify:
        Enum.map(result.clarify, fn %Question{} = q ->
          %{id: q.id, prompt: q.prompt, recommended: q.recommended}
        end)
    }
  end

  defp report_roadmap(result) do
    IO.puts("Drafted roadmap #{result.roadmap_ref} (#{length(result.proposals)} goals):")

    Enum.each(result.proposals, fn draft ->
      IO.puts("  - #{draft.proposal_ref}  (#{draft.goal.id})")
    end)

    case result.clarify do
      [] -> :ok
      questions -> Enum.each(questions, fn q -> IO.puts("  clarify: #{q.prompt}") end)
    end
  end

  # The kazi-drafts path (the existing one): drive the harness to draft predicates
  # from the prose idea, after the interactive/floor gating.
  defp kazi_drafts(idea, opts, inject_opts) do
    base =
      inject_opts
      |> Keyword.take([:harness, :adapter_opts])
      |> Keyword.put(:workspace, opts[:workspace] || ".")
      |> Keyword.put(:replace, opts[:replace] || false)
      # T45.6 (UC-059): thread the opt-in `--discover` into the kazi-drafts path
      # only; caller-drafts (`caller_drafts/4`, `caller_drafts_project/3`) never
      # pass it, so a supplied proposal bypasses discovery.
      |> Keyword.put(:discover, opts[:discover] || false)
      |> Keyword.put(:session_name, resolve_session_name(opts))

    ask = propose_ask(opts, inject_opts)

    cond do
      # T15.1 (ADR-0023): under --json kazi is NON-INTERACTIVE. propose's clarify
      # phase WOULD prompt for an underspecified idea (gaps, no injected ask, not
      # --yes); rather than block on stdin we error LOUDLY as a JSON object on
      # stdout and return non-zero. The orchestrator either supplies --yes
      # (best-effort), supplies predicates (caller-drafts), or sharpens the idea —
      # it never hangs.
      json_block?(idea, ask, opts) ->
        emit_json_error(
          "propose requires interactive clarification under --json (idea is " <>
            "underspecified, missing: #{strict_missing(idea)}); pass --yes to draft " <>
            "best-effort, supply predicates (--predicates / stdin), or add the " <>
            "missing detail to the idea"
        )

        1

      strict_block?(idea, ask, opts) ->
        IO.puts(
          :stderr,
          "error: idea is underspecified (missing: #{strict_missing(idea)}); " <>
            "answer the clarify questions interactively or add detail to the idea"
        )

        1

      true ->
        do_propose(idea, maybe_ask(base, ask), opts, inject_opts)
    end
  end

  # The caller-drafts path (T15.2): the caller already authored the predicates, so
  # kazi spawns NO inner harness/model — it routes the supplied proposal through
  # the SAME `Kazi.Authoring.propose/2` write path via the `:proposal` opt, then
  # surfaces the deterministic floor (`Clarify.gaps/2`) over the parsed draft so a
  # missing live-verification target + scope is flagged, never silently accepted.
  defp caller_drafts(idea, payload, opts, inject_opts) do
    case normalize_caller_payload(payload) do
      {:ok, proposal} ->
        propose_opts =
          inject_opts
          |> Keyword.take([:harness, :adapter_opts])
          |> Keyword.put(:workspace, opts[:workspace] || ".")
          |> Keyword.put(:proposal, proposal)
          |> Keyword.put(:replace, opts[:replace] || false)
          |> Keyword.put(:session_name, resolve_session_name(opts))

        case Authoring.propose(caller_idea(idea), propose_opts) do
          {:ok, draft} ->
            report_drafted(draft, opts)
            maybe_write_adr(draft, opts, inject_opts)
            0

          {:error, reason} ->
            propose_error(reason, opts)
        end

      {:error, message} ->
        propose_input_error(message, opts)
    end
  end

  # Normalize a caller-supplied payload into the proposal map `Kazi.Authoring`
  # parses. Two shapes are accepted: the full proposal object
  # ({"name","predicates":[...],"rationale"}) — passed through — or a BARE JSON
  # array of predicate entries, wrapped as {"predicates": [...]} for the caller's
  # convenience. Anything else (a scalar, malformed JSON) is a clear input error.
  defp normalize_caller_payload(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, list} when is_list(list) -> {:ok, %{"predicates" => list}}
      {:ok, _other} -> {:error, "supplied predicates must be a JSON object or array"}
      {:error, _} -> {:error, "supplied predicates are not valid JSON"}
    end
  end

  # A caller-drafts idea may be omitted (the predicates carry the intent). A blank
  # idea would trip `Authoring`'s `:empty_idea` guard / derive an empty goal id, so
  # default it to a stable placeholder when the caller supplied predicates only.
  defp caller_idea(idea) do
    case String.trim(idea) do
      "" -> "caller-supplied predicates"
      trimmed -> trimmed
    end
  end

  # T15.1 (ADR-0023): the NON-INTERACTIVE guarantee for `propose` under `--json`.
  # An interactive requirement (clarify gaps, no injected `:ask`, not `--yes`)
  # cannot be satisfied without prompting, so under `--json` it is a hard, loud
  # error instead of a stdin block. `--yes` (best-effort) and a gap-free idea both
  # proceed; an injected `:ask` (tests) also proceeds.
  defp json_block?(idea, ask, opts) do
    opts[:json] and is_nil(ask) and not opts[:yes] and Clarify.gaps(idea) != []
  end

  defp do_propose(idea, propose_opts, opts, inject_opts) do
    case Authoring.propose(idea, propose_opts) do
      {:ok, draft} ->
        draft = maybe_refine(draft, propose_opts, opts, inject_opts)
        report_drafted(draft, opts)
        maybe_write_adr(draft, opts, inject_opts)
        0

      {:error, reason} ->
        propose_error(reason, opts)
    end
  end

  # Render a successful draft: a single JSON object under --json (the machine
  # surface, ADR-0023 decision 2), the existing human report otherwise. BOTH modes
  # share the same `Kazi.Authoring` draft, so the clarify floor and the proposal
  # are identical; only the OUTPUT shape differs.
  defp report_drafted(draft, opts) do
    emit(json?(opts), proposed_json(draft), fn -> report_proposed(draft) end)
  end

  # A draft-level error: a JSON error envelope on stdout under --json (so the
  # orchestrator parses one surface and branches on the non-zero exit), the
  # existing human stderr line otherwise.
  defp propose_error(reason, opts) do
    message = format_authoring_error(reason)

    if json?(opts) do
      emit_json_error("could not propose goal: #{message}")
    else
      IO.puts(:stderr, "error: could not propose goal: #{message}")
    end

    1
  end

  # An input error before drafting (bad/missing predicates, empty propose): same
  # split — JSON envelope under --json, human stderr otherwise.
  defp propose_input_error(message, opts) do
    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # =============================================================================
  # caller-drafts input (T15.2, ADR-0023 decision 4)
  # =============================================================================
  #
  # The caller supplies the proposal payload — the `{"name","predicates",
  # "rationale"}` object an inner model would otherwise draft — so kazi spawns no
  # model. Resolution order, all NON-BLOCKING:
  #
  #   1. `--predicates <json>` (an inline string), then
  #   2. stdin, but only under `--json` and only when stdin is PIPED (not a TTY),
  #      so kazi never blocks waiting for a human to type (the ADR-0023
  #      non-interactive guarantee). Tests inject stdin via `inject_opts[:stdin]`.
  #
  # Returns `{:ok, payload}` (a string the authoring layer decodes), `:none` (no
  # caller payload — kazi-drafts), or `{:error, message}` (a payload was supplied
  # but is blank).
  @spec caller_proposal(keyword(), keyword()) ::
          {:ok, String.t()} | :none | {:error, String.t()}
  defp caller_proposal(opts, inject_opts) do
    cond do
      is_binary(opts[:predicates]) -> non_blank_payload(opts[:predicates])
      (raw = read_stdin_payload(opts, inject_opts)) != nil -> non_blank_payload(raw)
      true -> :none
    end
  end

  defp non_blank_payload(raw) do
    case String.trim(raw) do
      "" -> {:error, "no predicates supplied (the --predicates / stdin payload was blank)"}
      trimmed -> {:ok, trimmed}
    end
  end

  # Read a caller payload from stdin, NON-BLOCKING. An injected `:stdin` (tests)
  # wins; otherwise read real stdin only under --json and only when it is PIPED —
  # a TTY would block, which --json forbids, so a TTY yields nil (→ kazi-drafts).
  defp read_stdin_payload(opts, inject_opts) do
    cond do
      Keyword.has_key?(inject_opts, :stdin) -> inject_opts[:stdin]
      opts[:json] and not interactive?(inject_opts) -> read_all_stdin()
      true -> nil
    end
  end

  # Drain stdin to EOF. On a piped/empty stdin this returns the content (or "")
  # immediately; it is only reached when stdin is NOT a TTY, so it cannot block.
  defp read_all_stdin do
    case IO.read(:stdio, :eof) do
      :eof -> nil
      {:error, _} -> nil
      data when is_binary(data) -> data
    end
  end

  # The clarify `:ask` callback: an injected one (tests) wins; otherwise interactive
  # terminal prompting when a TTY is attached and `--yes` was not passed. `nil`
  # means non-interactive -- propose stays a one-shot draft.
  defp propose_ask(opts, inject_opts) do
    cond do
      is_function(inject_opts[:ask], 1) -> inject_opts[:ask]
      opts[:yes] -> nil
      # T15.1 (ADR-0023): --json is NON-INTERACTIVE — never attach the terminal
      # prompt even when a TTY is present. An injected :ask (tests) still wins
      # above; a real underspecified --json run is caught by `json_block?/3`.
      opts[:json] -> nil
      interactive?(inject_opts) -> &terminal_ask/1
      true -> nil
    end
  end

  # Interactive when a TTY is attached, unless a test forces it via `:tty` in
  # inject_opts (so a clarify test never blocks on real stdin).
  defp interactive?(inject_opts), do: Keyword.get(inject_opts, :tty, tty?())

  defp maybe_ask(propose_opts, nil), do: propose_opts
  defp maybe_ask(propose_opts, ask), do: Keyword.put(propose_opts, :ask, ask)

  # `--strict` with no way to clarify (non-interactive) and an idea that still has
  # floor gaps is a hard refusal rather than a guessed draft.
  defp strict_block?(idea, ask, opts) do
    opts[:strict] and is_nil(ask) and Clarify.gaps(idea) != []
  end

  defp strict_missing(idea) do
    idea |> Clarify.gaps() |> Enum.map_join(", ", & &1.id)
  end

  # T11.8 review loop: after the draft, an interactive review may "refine" with a
  # sharper sentence, which re-runs clarify+draft and UPSERTS the same proposal
  # (same proposal_ref), keeping it `proposed`. An injected `:review` drives this
  # in tests; in production a terminal review runs only when a TTY is attached.
  defp maybe_refine(draft, propose_opts, opts, inject_opts) do
    case propose_review(opts, inject_opts) do
      nil ->
        draft

      review ->
        case review.(draft) do
          {:refine, sharper} when is_binary(sharper) and sharper != "" ->
            refine_opts = Keyword.put(propose_opts, :proposal_ref, draft.proposal_ref)

            case Authoring.propose(sharper, refine_opts) do
              {:ok, refined} -> maybe_refine(refined, propose_opts, opts, inject_opts)
              {:error, _reason} -> draft
            end

          _ ->
            draft
        end
    end
  end

  defp propose_review(opts, inject_opts) do
    cond do
      is_function(inject_opts[:review], 1) -> inject_opts[:review]
      opts[:yes] -> nil
      # T15.1 (ADR-0023): --json is NON-INTERACTIVE — no terminal review prompt.
      opts[:json] -> nil
      interactive?(inject_opts) -> &terminal_review/1
      true -> nil
    end
  end

  defp maybe_write_adr(draft, opts, inject_opts) do
    if opts[:adr] do
      adr_opts = if dir = inject_opts[:adr_dir], do: [dir: dir], else: []

      case RationaleAdr.write(draft, adr_opts) do
        {:ok, path} -> IO.puts("ADR written: #{path}")
        {:error, reason} -> IO.puts(:stderr, "warning: could not write ADR: #{inspect(reason)}")
      end
    end
  end

  # --- interactive terminal I/O (T11.6/T11.8) --------------------------------

  # Prompt each clarify question as numbered multiple-choice (plus a free-text
  # escape when allowed), read the author's choice from stdin, and return the
  # answers map keyed by question id. The recommended option is starred and is the
  # default on an empty line.
  defp terminal_ask(questions) do
    IO.puts("\nA few questions to make the goal precise (press Enter for the default):\n")
    Enum.reduce(questions, %{}, fn %Question{} = q, acc -> Map.put(acc, q.id, ask_one(q)) end)
  end

  # Render the question (pure, in Clarify), read one line, and resolve it to an
  # answer value (pure, in Clarify). Only the print/read glue lives here, so the
  # rendering and the choice resolution are unit-tested without a TTY.
  defp ask_one(%Question{} = q) do
    IO.puts(Clarify.render_question(q))
    Clarify.resolve_answer(q, read_line())
  end

  # The terminal review after a draft: accept / refine with a sharper sentence.
  defp terminal_review(_draft) do
    IO.puts("\nRefine this draft? Enter a sharper one-line idea, or press Enter to accept it.")

    case read_line() do
      "" -> :accept
      sharper -> {:refine, sharper}
    end
  end

  defp read_line do
    case IO.gets("> ") do
      :eof -> ""
      {:error, _} -> ""
      line -> String.trim(line)
    end
  end

  # A TTY is attached when the IO server reports terminal geometry; piped/CI
  # stdio reports an error, so we default to non-interactive there.
  defp tty?, do: match?({:ok, _}, :io.rows())

  # `list-proposed [--status <state>] [--json]`: print the proposal queue, newest
  # first. T15.6 (ADR-0023 decision 2): under --json emit a single JSON object —
  # the queue as a list an orchestrator drives plan → approve → apply on — the
  # human table otherwise.
  defp execute_list_proposed(opts) do
    with_read_model(opts, fn ->
      rows = ReadModel.list_proposed_goals(list_filter(opts[:status]))

      emit(json?(opts), list_proposed_json(rows, opts[:status]), fn ->
        report_proposed_list(rows, opts[:status])
      end)

      0
    end)
  end

  defp list_filter(nil), do: []
  defp list_filter(status), do: [status: status]

  # `approve <proposal-ref> [--json]`: transition proposed → approved. On success
  # the goal is now runnable by `kazi apply`. T15.6: under --json the transition
  # reports a machine-readable success object (or a JSON error on the same stdout
  # surface), the human lines otherwise.
  defp execute_approve(proposal_ref, opts) do
    with_read_model(opts, fn ->
      case Authoring.approve(proposal_ref) do
        {:ok, %Goal{} = goal} ->
          case maybe_materialize_goal_file(goal, opts[:write]) do
            {:ok, extra} ->
              emit(
                json?(opts),
                approval_json("approved", proposal_ref, goal.id, extra),
                fn ->
                  IO.puts("APPROVED   proposal=#{proposal_ref} goal=#{goal.id}")

                  case extra[:path] do
                    nil ->
                      IO.puts(
                        "The goal is now runnable: kazi apply <goal-file> --workspace <path>"
                      )

                    path ->
                      IO.puts("WROTE      #{path}")
                      IO.puts("The goal is now runnable: kazi apply #{path} --workspace <path>")
                  end
                end
              )

              0

            {:error, message} ->
              # The transition SUCCEEDED (the proposal is approved and persisted);
              # only the optional file write failed. Report the write error on the
              # requested surface, non-zero, without pretending approval failed.
              if json?(opts) do
                emit_json_error(message)
              else
                IO.puts(:stderr, "error: #{message}")
              end

              1
          end

        {:error, reason} ->
          transition_error("approve", proposal_ref, reason, opts)
      end
    end)
  end

  # T39.3 (ADR-0049): `--write <path>` materializes the approved goal to a
  # loadable goal-file. Absent, approval is unchanged (returns `{:ok, %{}}`, no
  # extra JSON keys). Present, render the FULL goal map (no live-scaffold), write
  # it, then RE-LOAD and compare to the approved goal — a written file that does
  # not round-trip to the same goal is refused rather than silently shipped.
  defp maybe_materialize_goal_file(_goal, nil), do: {:ok, %{}}
  defp maybe_materialize_goal_file(_goal, ""), do: {:ok, %{}}

  defp maybe_materialize_goal_file(%Goal{} = goal, path) when is_binary(path) do
    toml = Adopt.Writer.to_goal_file(Authoring.serialize_goal(goal))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, toml),
         {:ok, %Goal{} = reloaded} <- Goal.Loader.load(path),
         :ok <- verify_goal_roundtrip(goal, reloaded) do
      {:ok, %{path: path}}
    else
      {:error, %{} = _changeset_or_map} ->
        {:error, "could not materialize a loadable goal-file at #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, "could not materialize a loadable goal-file at #{path}: #{reason}"}

      {:error, reason} ->
        {:error,
         "could not write #{path}: " <>
           if(is_atom(reason), do: :file.format_error(reason), else: inspect(reason))}
    end
  end

  # The written file must load back to the SAME runnable goal (T39.3 acc): equal
  # id, mode, standing, and predicate set. A mismatch means the writer dropped or
  # mangled something — refuse the file rather than ship a goal that would
  # `apply` differently than the approved proposal.
  defp verify_goal_roundtrip(%Goal{} = original, %Goal{} = reloaded) do
    same? =
      original.id == reloaded.id and
        original.mode == reloaded.mode and
        original.standing == reloaded.standing and
        predicate_ids(original) == predicate_ids(reloaded)

    if same?, do: :ok, else: {:error, "the written goal-file did not round-trip to the same goal"}
  end

  defp predicate_ids(%Goal{} = goal) do
    goal |> Goal.all_predicates() |> Enum.map(&to_string(&1.id)) |> Enum.sort()
  end

  # `reject <proposal-ref> [--json]`: transition proposed → rejected (declined,
  # audited). T15.6: same JSON/human split as approve. #945: rejection never
  # requires the stored goal to load, so a stale/unloadable proposal still
  # rejects — the JSON result carries `loadable: false` for audit instead of
  # failing.
  defp execute_reject(proposal_ref, opts) do
    with_read_model(opts, fn ->
      case Authoring.reject(proposal_ref) do
        {:ok, draft} ->
          extra = if draft.loadable?, do: %{}, else: %{loadable: false}

          emit(
            json?(opts),
            approval_json("rejected", proposal_ref, draft.goal_id, extra),
            fn ->
              IO.puts("REJECTED   proposal=#{proposal_ref}")

              unless draft.loadable? do
                IO.puts("note: the stored goal is unloadable (kept for audit)")
              end
            end
          )

          0

        {:error, reason} ->
          transition_error("reject", proposal_ref, reason, opts)
      end
    end)
  end

  # A transition (approve/reject) error on the requested surface (T15.6): a JSON
  # error envelope on stdout under --json (so the orchestrator parses one surface
  # and branches on the non-zero exit), the existing human stderr line otherwise.
  defp transition_error(verb, proposal_ref, reason, opts) do
    message = "could not #{verb} #{proposal_ref}: " <> format_authoring_error(reason)

    if json?(opts) do
      emit_json_error(message)
    else
      IO.puts(:stderr, "error: #{message}")
    end

    1
  end

  # The authoring commands all require a live read-model (they persist/query
  # proposals); unlike `run` they cannot degrade to no-persistence. Ensure it, run
  # the command, or refuse cleanly with exit 1 if the DB is unavailable.
  #
  # `opts` is threaded through so the read-model-unavailable error follows the
  # same --json contract every other load/availability error does (deep review
  # L2): a JSON error envelope on stdout under --json (escript builds without the
  # NIF hit this path), the human stderr line otherwise.
  defp with_read_model(opts, fun) do
    if ensure_read_model() do
      fun.()
    else
      message =
        "the read-model is unavailable; authoring requires persistence. " <>
          "The escript build cannot bundle the SQLite NIF, so `plan`/`approve`/" <>
          "`reject`/`list-proposed` need the release binary (`kazi` from a GitHub " <>
          "release / Homebrew) or a dev `mix run` entrypoint"

      if json?(opts) do
        emit_json_error(message)
      else
        IO.puts(:stderr, "error: #{message}")
      end

      1
    end
  end

  defp report_proposed(draft) do
    IO.puts("PROPOSED   goal=#{draft.goal.id}")
    IO.puts("proposal:  #{draft.proposal_ref}")
    IO.puts("idea:      #{draft.idea}")
    IO.puts("\npredicates (acceptance criteria):")
    IO.puts(format_proposed_predicates(draft.goal))
    report_rationale(draft.goal)
    report_suggested_budget(draft.goal)
    IO.puts("\nReview, then: kazi approve #{draft.proposal_ref}")
  end

  # T48.9 (ADR-0058 decision 2): a learned `[budget]` suggestion for the drafted
  # goal's shape, printed as ADVISORY text -- never written into the draft
  # itself (`Kazi.Authoring.serialize_goal/1` carries no budget, so a suggestion
  # here can never silently reach an approved goal). Absent when local history
  # has nothing usable for this shape (no line printed at all).
  defp report_suggested_budget(%Goal{} = goal) do
    case suggested_budget(goal) do
      nil ->
        :ok

      suggestion ->
        IO.puts(
          "\nsuggested [budget] (advisory -- not applied; copy into the goal-file to opt in):"
        )

        IO.puts(format_suggested_budget_lines(suggestion))
    end
  end

  defp format_suggested_budget_lines(suggestion) do
    lines =
      [
        maybe_budget_line("max_tokens", suggestion[:max_tokens]),
        maybe_budget_line("max_dispatches", suggestion[:max_dispatches]),
        maybe_budget_line("max_wall_clock_ms", suggestion[:max_wall_clock_ms])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(["  # #{suggestion.provenance}" | lines], "\n")
  end

  defp maybe_budget_line(_key, nil), do: nil
  defp maybe_budget_line(key, value), do: "  #{key} = #{value}"

  # The T48.9 suggestion input is the drafted goal's own predicate count (its
  # "shape", `Kazi.Economy.History.goal_shape_bucket/1`) -- model/harness are
  # not yet chosen at draft time, so the lookup pools across the shape bucket
  # (see `Kazi.Economy.BudgetSuggestion`).
  defp suggested_budget(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> length()
    |> BudgetSuggestion.suggest()
  end

  # =============================================================================
  # plan/propose --json result schema (T15.2, ADR-0023 decision 2)
  # =============================================================================
  #
  # The single JSON object `plan --json` (alias `propose --json`) emits: the draft
  # a caller approves on.
  # It carries the goal id, the proposal_ref (the approve/reject handle), the
  # acceptance predicates, the optional rationale, and the deterministic clarify
  # FLOOR (`Clarify.gaps/2`) computed OVER the draft — so a missing
  # live-verification target + scope is FLAGGED even when nothing was asked
  # interactively. The floor applies in BOTH drive modes (kazi-drafts and
  # caller-drafts) because both produce the same `Kazi.Authoring.Draft` here.
  defp proposed_json(draft) do
    base = %{
      schema_version: @run_schema_version,
      goal_id: to_string(draft.goal.id),
      proposal_ref: draft.proposal_ref,
      status: to_string(draft.status),
      idea: draft.idea,
      predicates: Enum.map(Goal.all_predicates(draft.goal), &predicate_json/1),
      rationale: rationale_text(draft.goal),
      clarify: clarify_json(draft)
    }

    # T48.9 (ADR-0058 decision 2): the `suggested_budget` key is present ONLY
    # when local history has something usable for this goal's shape -- absent
    # (not `null`), so a fresh/empty read-model's `plan --json` output is
    # BYTE-IDENTICAL to before this feature existed.
    case suggested_budget(draft.goal) do
      nil -> base
      suggestion -> Map.put(base, :suggested_budget, suggestion)
    end
  end

  defp predicate_json(predicate) do
    %{
      id: to_string(predicate.id),
      provider: to_string(predicate.kind),
      description: predicate.description,
      acceptance: predicate.acceptance?,
      guard: predicate.guard?,
      config: predicate.config
    }
  end

  # The deterministic floor over the DRAFT: a question survives only when the gap
  # it guards is still open (e.g. no live-verification predicate present), so an
  # orchestrator sees exactly what is missing. Each question carries its id, prompt,
  # and recommended answer — enough to re-propose with the gap closed.
  defp clarify_json(draft) do
    draft.idea
    |> Clarify.gaps(draft: draft.goal)
    |> Enum.map(fn %Question{} = q ->
      %{id: q.id, prompt: q.prompt, recommended: q.recommended}
    end)
  end

  defp rationale_text(%Goal{metadata: metadata}) do
    case Map.get(metadata, "rationale") do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  # T11.5 (ADR-0019): surface the inline rationale ("why these predicates / what is
  # out of scope") the harness recorded on the draft, when present.
  defp report_rationale(%Goal{metadata: metadata}) do
    case Map.get(metadata, "rationale") do
      text when is_binary(text) and text != "" -> IO.puts("\nrationale: #{text}")
      _ -> :ok
    end
  end

  defp format_proposed_predicates(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.map_join("\n", fn predicate ->
      "  - #{predicate.id} (#{predicate.kind})" <> describe_predicate(predicate)
    end)
  end

  defp describe_predicate(%{description: description})
       when is_binary(description) and description != "",
       do: ": #{description}"

  defp describe_predicate(_predicate), do: ""

  defp report_proposed_list([], status) do
    IO.puts("(no #{status_label(status)} proposals)")
  end

  defp report_proposed_list(rows, status) do
    IO.puts("#{length(rows)} #{status_label(status)} proposal(s):\n")

    Enum.each(rows, fn %ProposedGoal{} = row ->
      IO.puts("  #{row.status}\t#{row.proposal_ref}\t#{row.goal_id}")
      IO.puts("    idea: #{row.idea}")
    end)
  end

  defp status_label(nil), do: "proposed-goal"
  defp status_label(status), do: status

  # =============================================================================
  # authoring --json result schemas (T15.6, ADR-0023 decision 2)
  # =============================================================================
  #
  # The structured JSON an orchestrator drives the plan → approve → apply state
  # machine on. `list-proposed --json` emits the queue (each row's ref, state,
  # goal id, idea) under the optional status filter; `approve`/`reject --json`
  # emit a machine-readable transition result. All carry `schema_version`.
  defp list_proposed_json(rows, status_filter) do
    %{
      schema_version: @run_schema_version,
      status_filter: status_filter,
      count: length(rows),
      proposals: Enum.map(rows, &proposed_row_json/1)
    }
  end

  defp proposed_row_json(%ProposedGoal{} = row) do
    %{
      proposal_ref: row.proposal_ref,
      status: row.status,
      goal_id: row.goal_id,
      idea: row.idea
    }
  end

  # The approve/reject transition result (T15.6): the resulting lifecycle state,
  # the proposal ref, and the goal id, so the orchestrator confirms the transition
  # and pipes the goal id into the next step. `extra` carries an optional
  # `%{loadable: false}` (#945) when `reject` succeeded on a proposal whose
  # stored goal no longer loads — an audit note, not an error.
  defp approval_json(status, proposal_ref, goal_id, extra) do
    %{
      schema_version: @run_schema_version,
      proposal_ref: proposal_ref,
      status: status,
      goal_id: to_string(goal_id)
    }
    |> Map.merge(extra)
  end

  defp format_authoring_error(:empty_idea), do: "the idea was blank"
  defp format_authoring_error(:not_found), do: "no proposal carries that ref"

  defp format_authoring_error({:invalid_transition, from, to}),
    do: "cannot transition a #{from} proposal to #{to}"

  defp format_authoring_error({:harness_failed, reason}),
    do: "the authoring harness could not run: #{inspect(reason)}"

  defp format_authoring_error({:invalid_proposal, reason}),
    do: "the harness produced no usable acceptance predicate (#{reason})"

  defp format_authoring_error({:invalid_goal, reason}),
    do: "the goal does not load: #{inspect(reason)}"

  defp format_authoring_error({:proposal_locked, ref, status}),
    do: "#{ref} already holds an #{status} proposal; pass --replace to overwrite it"

  defp format_authoring_error(%Ecto.Changeset{} = changeset),
    do: "could not persist the proposal: #{inspect(changeset.errors)}"

  defp format_authoring_error(other), do: inspect(other)

  # =============================================================================
  # read-model startup (boot the app + ensure DB exists & is migrated)
  # =============================================================================

  # Boot the :kazi application (starts Kazi.Repo) and make sure the SQLite
  # read-model is created and migrated, so the default path persists iterations on
  # the very first run. Returns whether persistence is available: true when the
  # DB is ready, false (degrade gracefully, with a warning) when it can't be
  # opened/migrated.
  #
  # An escript archive cannot bundle the native exqlite NIF, so under the escript
  # the SQLite driver simply isn't loadable. We detect that cheaply up front and
  # degrade quietly, rather than letting a connection pool crash-loop loudly on a
  # missing NIF. The `mix kazi.apply` task (and any real release) boots the full app
  # with the NIF present, so persistence works there on the default path.
  @spec ensure_read_model() :: boolean()
  defp ensure_read_model do
    cond do
      not sqlite_nif_available?() ->
        IO.puts(
          :stderr,
          "warning: SQLite read-model driver unavailable (running as an escript, " <>
            "which cannot bundle the native NIF); running without persistence. " <>
            "Use `mix kazi.apply` for a persistent read-model."
        )

        false

      true ->
        case migrate_read_model() do
          :ok ->
            true

          {:error, reason} ->
            IO.puts(
              :stderr,
              "warning: read-model unavailable (#{inspect(reason)}); " <>
                "running without persistence"
            )

            false
        end
    end
  end

  # The exqlite driver is a NIF; if its NIF module didn't load (e.g. inside an
  # escript), no SQLite connection can be opened. Checking the exported NIF
  # function is cheap and side-effect-free — it never starts a pool.
  defp sqlite_nif_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3NIF) and
      function_exported?(Exqlite.Sqlite3NIF, :open, 2)
  end

  @doc false
  # T52.6 (ADR-0068 points 2 & 5): the single-migrator cutover. When a daemon is
  # LIVE it has ALREADY migrated the read-model once at its own startup (T52.4,
  # migrate-before-serve) and is the ONE process that opens the file read-write.
  # This process must therefore NOT run `Ecto.Migrator` and must NOT open a
  # second write connection against the same file -- doing so would recreate the
  # exact #1019 mixed-migration-writer class ADR-0068 closes by construction. So
  # when the daemon control socket probes `:alive` we DEFER MIGRATION, never
  # running `Ecto.Migrator` or opening a write/`storage_up` path against the file.
  # Writes from this process route through the daemon over the socket
  # (T52.3/T52.5); the daemon is the single writer and the single migrator.
  #
  # This process is STILL a reader, though (#1483): the operator dashboard
  # (`KaziWeb.MissionControlLive` -> `RunRegistry.list/0` -> `Kazi.Repo.all/1`)
  # and every read verb query `Kazi.Repo` DIRECTLY -- only writes go over the
  # socket. Under a standalone binary the app supervision tree never started the
  # repo (`Kazi.Application` hands straight to the CLI before standing the tree
  # up), so on the `:alive` path we still START `Kazi.Repo` here as a read
  # connection -- WITHOUT migrating -- and leave it running. Absent that, a
  # reader crashes with "could not lookup Ecto repo Kazi.Repo because it was not
  # started" (the reported dashboard 500s / "no read-model persistence" under a
  # live daemon, e.g. one supervised by launchd).
  #
  # Absent a daemon (`:missing`/`:dead`), today's behavior stands UNCHANGED
  # (ADR-0068 point 5, the rollback path): create the file, start a
  # process-linked repo, run the bounded, version-stamp-checked, degrading boot
  # migration. A run that starts under a daemon and then loses it mid-run
  # degrades via the Writer's no-daemon path (T52.7); it does NOT retroactively
  # migrate here.
  #
  # The daemon control socket is resolved via the SAME `:read_model_writer_sock`
  # config seam the Writer uses, so the test env points presence at a
  # never-existing socket and unrelated suites never route to a developer's live
  # daemon. `:probe`/`:sock_path` are test seams (mirroring the Writer's presence
  # probe and the daemon supervisor's `:migrate_fun`). `:migrate_fun` (default
  # the bounded boot migration) is the migrator seam: a test asserts it is
  # NEVER invoked on the `:alive` path and invoked exactly once on the
  # no-daemon path.
  @spec migrate_read_model(keyword()) :: :ok | {:error, term()}
  def migrate_read_model(opts \\ []) do
    probe = Keyword.get(opts, :probe, &Kazi.Daemon.Probe.probe/1)
    sock_path = Keyword.get(opts, :sock_path, read_model_writer_sock())

    case probe.(sock_path) do
      :alive -> ensure_repo_started_for_read(opts)
      _missing_or_dead -> migrate_read_model_direct(opts)
    end
  end

  # The `:alive`-daemon reader path (#1483). A live daemon has ALREADY migrated
  # the read-model (T52.4) and is the single writer/migrator, so this process
  # must NOT migrate or open a write/`storage_up` path. It IS still a reader,
  # though -- the dashboard and the read verbs query `Kazi.Repo` directly -- and
  # under a standalone binary the supervision tree never started the repo, so we
  # START it HERE as a read connection and LEAVE IT RUNNING for the rest of this
  # (long-lived dashboard / short-lived CLI) process. Idempotent: a no-op when
  # the repo is already supervised (the mix task / dev / test path) or already
  # started here. `:read_start_fun` is the test seam, mirroring `:migrate_fun`.
  defp ensure_repo_started_for_read(opts) do
    start_fun =
      Keyword.get(opts, :read_start_fun, fn ->
        repo = Kazi.Repo

        if started?(repo) do
          :ok
        else
          case repo.start_link() do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end)

    start_fun.()
  rescue
    error -> {:error, Exception.message(error)}
  end

  # The daemon control socket dialed to decide migration ownership. Overridable
  # via `config :kazi, :read_model_writer_sock` (the same seam the Writer uses)
  # so the test env points it at a never-existing socket.
  defp read_model_writer_sock do
    Application.get_env(:kazi, :read_model_writer_sock) ||
      Kazi.Daemon.Supervisor.default_sock_path()
  end

  # The no-daemon (rollback) path: direct open, unchanged from before T52.6.
  defp migrate_read_model_direct(opts) do
    repo = Kazi.Repo
    migrate_fun = Keyword.get(opts, :migrate_fun, fn -> run_migrations_bounded(repo) end)

    try do
      if started?(repo) do
        # Mix-task path: the supervision tree already started the repo (and its
        # SQLite connection creates the file on connect). Opening a *second*,
        # transient connection here to `storage_up` races the supervised pool and
        # SQLite's single writer ("database is locked"); instead just run pending
        # migrations against the live, already-connected repo.
        migrate_fun.()
      else
        # Standalone binary path (the Burrito release): no supervised repo, because
        # `Kazi.Application.start/2` hands straight to the CLI before standing up the
        # supervision tree. Create the SQLite file if absent (no-op if it exists),
        # then START the repo and LEAVE IT RUNNING for the rest of this process.
        #
        # We must NOT use `Ecto.Migrator.with_repo/2` here: it starts a transient
        # repo, runs the fun, and STOPS the repo when the fun returns -- leaving the
        # read-model migrated but with no live connection. Every read-model command
        # that runs AFTER this (the CLI `status`/`list-proposed`/`approve`, and the
        # long-lived `kazi mcp` server's `kazi_status` tool) then crashes the binary
        # with "could not lookup Ecto repo Kazi.Repo because it was not started". The
        # caller is short-lived (a CLI command halts; the MCP server runs until EOF),
        # so a process-linked repo that lives until exit is exactly right and races
        # nothing (no supervised pool exists in this path).
        _ = repo.__adapter__().storage_up(repo.config())

        case repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

        migrate_fun.()
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # Boot migrations run under `Kazi.ReadModel.Migrate.run/2` -- a SHORT bound
  # (issue #1019: several DIFFERENT kazi versions on one machine can contend
  # on the migration lock during a release window), version-stamp checked
  # BEFORE migrating so an older binary never migrates a schema newer than it
  # knows. On timeout (or a newer-schema refusal) it degrades to
  # no-persistence -- the same path as a raised migration error -- instead of
  # hanging the whole process at boot (lore L-0035).
  @migrate_timeout_ms 5_000

  defp run_migrations_bounded(repo) do
    Kazi.ReadModel.Migrate.run(repo, timeout_ms: @migrate_timeout_ms)
  end

  defp started?(repo) do
    is_pid(Process.whereis(repo)) or is_pid(GenServer.whereis(repo))
  end

  # =============================================================================
  # outcome reporting
  # =============================================================================

  defp report(%Goal{} = goal, outcome, result, economy) do
    IO.puts(outcome_line(goal, outcome, result))
    IO.puts("iterations: #{result.iterations}")
    IO.puts("actions:    #{format_actions(result.actions)}")
    # T3.3d deploy wiring: surface the release ref of the artifact deployed this
    # run (T3.3c tagging) so the operator sees WHAT was shipped, not just the
    # outcome. Omitted when nothing was deployed (no release ref).
    maybe_report_release(result)
    IO.puts("\npredicate vector:")
    IO.puts(format_vector(result.vector))
    report_landing(result)
    print_convergence_cost_table(goal, result, economy)
  end

  # issue #1550: LOUDLY name WHERE the converged work landed, so an operator is
  # never left thinking a `converged` run did nothing. A worktree-isolated serial
  # run lands its commits on a branch (the base checkout's branch when it
  # rebase-merges, or a surviving task branch when landing failed); without this
  # line the human report showed convergence but not the branch, and the work
  # sat on a kazi-internal branch (`task/...`, `kazi/integrate-...`) with the
  # checkout looking clean. The same facts are on the `--json` surface's
  # `integration` object. Absent an attempted landing (in-place run, nothing to
  # land) this prints nothing -- byte-identical to before.
  defp report_landing(%{integration: %{landed: true} = info}) do
    branch = info[:task_branch] || landed_branch(info)
    base = info[:base]
    where = if is_binary(base) and base != "", do: "#{branch} → #{base}", else: branch

    IO.puts("\nlanded: #{where}#{landed_commit_suffix(info)}")
  end

  defp report_landing(%{integration: %{landed: false} = info}) do
    IO.puts(
      "\nNOT LANDED: work survives on branch #{info[:task_branch] || "?"}" <>
        "#{if info[:base], do: " (base #{info[:base]})", else: ""} -- " <>
        "#{info[:reason] || "integration failed"}"
    )
  end

  defp report_landing(_result), do: :ok

  # The landed branch from the integrator refs when the verdict map itself did
  # not carry a task branch (defensive; SerialLanding always sets `task_branch`).
  defp landed_branch(%{refs: refs}) when is_map(refs), do: refs[:branch] || refs["branch"]
  defp landed_branch(_), do: nil

  # A compact "(commit <sha>)" / "(PR <url>)" suffix from whatever the integrator
  # surfaced in `refs`, so the operator can jump straight to the landed work.
  defp landed_commit_suffix(%{refs: refs}) when is_map(refs) do
    cond do
      pr = refs[:pr] || refs["pr"] -> " (PR #{pr})"
      sha = refs[:merge_commit] || refs["merge_commit"] -> " (commit #{short_sha(sha)})"
      sha = refs[:commit] || refs["commit"] -> " (commit #{short_sha(sha)})"
      true -> ""
    end
  end

  defp landed_commit_suffix(_info), do: ""

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(sha), do: to_string(sha)

  # T60.5 (#1070): the human-readable cost/token breakdown table on
  # convergence/budget-exhaustion. `--json` already carries this data
  # (`economy`/`usage`); this is purely additive terminal UX. Skipped when
  # the run reported no usage at all (honest-unknown -- no fabricated $0 row).
  defp print_convergence_cost_table(%Goal{id: id}, result, economy) do
    usage = Map.get(result, :usage) || %{}

    if map_size(usage) > 0 or is_map(economy) do
      IO.puts("")
      print_cost_table([cost_row(to_string(id), result, economy, usage)])
    end
  end

  defp cost_row(goal_id, result, economy, usage) do
    %{
      goal: goal_id,
      iterations: result.iterations,
      cost_usd: economy_field(economy, :cost_usd),
      predicates: predicates_label(result.vector),
      token_breakdown: Kazi.Economy.KPIs.token_breakdown(usage)
    }
  end

  defp economy_field(economy, key) when is_map(economy), do: Map.get(economy, key)
  defp economy_field(_economy, _key), do: nil

  defp predicates_label(nil), do: "—"

  defp predicates_label(%Kazi.PredicateVector{results: results}) do
    total = map_size(results)
    passing = Enum.count(results, fn {_id, r} -> r.status == :pass end)
    "#{passing}/#{total} pass"
  end

  # A single, reusable ASCII table renderer for the per-goal cost/token
  # breakdown (T60.5, #1070) -- shared by the single-goal report above and the
  # fleet report below so both surfaces render the SAME shape (the issue's
  # explicit "not two separate implementations" requirement), one row per
  # goal. Column widths size to content (never truncate a goal id/number).
  defp print_cost_table(rows) when is_list(rows) and rows != [] do
    headers = ["Goal", "Iterations", "Cost", "Predicates"]

    cells =
      Enum.map(rows, fn r ->
        [r.goal, to_string(r.iterations), cost_cell(r.cost_usd), r.predicates]
      end)

    widths =
      Enum.zip([headers | cells])
      |> Enum.map(fn col ->
        col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
      end)

    IO.puts(table_border(widths, "┌", "┬", "┐"))
    IO.puts(table_row(headers, widths))
    IO.puts(table_border(widths, "├", "┼", "┤"))

    Enum.each(Enum.zip(rows, cells), fn {row, cell} ->
      IO.puts(table_row(cell, widths))
      print_token_breakdown_line(row.token_breakdown)
    end)

    IO.puts(table_border(widths, "└", "┴", "┘"))
  end

  defp print_cost_table(_rows), do: :ok

  defp cost_cell(nil), do: "—"

  defp cost_cell(usd) when is_number(usd),
    do: "$" <> :erlang.float_to_binary(usd / 1.0, decimals: 2)

  defp table_border(widths, left, mid, right) do
    left <> Enum.map_join(widths, mid, &String.duplicate("─", &1 + 2)) <> right
  end

  defp table_row(cells, widths) do
    "│ " <>
      Enum.map_join(Enum.zip(cells, widths), " │ ", fn {cell, w} ->
        String.pad_trailing(cell, w)
      end) <>
      " │"
  end

  defp print_token_breakdown_line(%{
         input: input,
         output: output,
         cached: cached,
         cache_write: cache_write
       }) do
    if input || output || cached || cache_write do
      IO.puts(
        "    tokens: input=#{token_cell(input)} output=#{token_cell(output)} " <>
          "cached=#{token_cell(cached)} cache_write=#{token_cell(cache_write)}"
      )
    end
  end

  defp token_cell(nil), do: "—"
  defp token_cell(n) when is_integer(n), do: to_string(n)

  # Print the release ref line only when a deploy produced one this run.
  defp maybe_report_release(%{release_ref: ref}) when is_binary(ref),
    do: IO.puts("release:    #{ref}")

  defp maybe_report_release(_result), do: :ok

  defp outcome_line(%Goal{id: id}, :converged, _result),
    do: "CONVERGED  goal=#{id} — every predicate is satisfied."

  defp outcome_line(%Goal{id: id}, :stopped, _result),
    do: "STOPPED    goal=#{id} — the loop stopped before converging."

  defp format_actions([]), do: "(none)"
  defp format_actions(actions), do: Enum.map_join(actions, " → ", &to_string/1)

  defp format_vector(nil), do: "  (no observation recorded)"

  defp format_vector(%Kazi.PredicateVector{results: results}) when map_size(results) == 0,
    do: "  (empty)"

  defp format_vector(%Kazi.PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map_join("\n", fn {id, result} ->
      "  #{status_glyph(result.status)} #{id}: #{result.status}"
    end)
  end

  defp status_glyph(:pass), do: "[pass]"
  defp status_glyph(:fail), do: "[fail]"
  defp status_glyph(:error), do: "[err ]"
  defp status_glyph(_), do: "[ ?  ]"

  # =============================================================================
  # run --json result schema (T15.3, ADR-0023 decision 2)
  # =============================================================================
  #
  # The single, VERSIONED JSON object `kazi apply --json` emits on termination. It
  # renders the loop's OWN terminal result (Kazi.Loop.result/0) — nothing is
  # re-derived or re-run — into the orchestrator-facing contract documented in
  # `docs/schemas/run-result.md`:
  #
  #   * `status`         — the terminal status the orchestrator branches on, one of
  #                        "converged" / "stuck" / "over_budget" / "error". Derived
  #                        from the loop outcome + reason: `:converged` →
  #                        "converged"; `:over_budget` → "over_budget"; a `:stopped`
  #                        loop with `reason: :stuck` → "stuck"; any other
  #                        non-converged stop → "stuck" as well (an operator/await
  #                        stop is a non-converged halt the orchestrator should
  #                        investigate). A pre-loop failure renders "error" via
  #                        `run_error_json/3` instead.
  #   * `predicates`     — the PREDICATE VECTOR: one `{id, verdict}` per predicate
  #                        at the terminal observation, sorted by id for a stable
  #                        diff. `verdict` is the predicate status string
  #                        (pass / fail / error / unknown).
  #   * `iterations`     — the loop's observation count.
  #   * `budget_spent`   — what the run consumed: iterations, and the exceeded
  #                        dimension when the stop was `over_budget` (else nil).
  #   * `next_action`    — a single hint the orchestrator branches on:
  #                        "done" (converged), "investigate" (stuck / non-converged),
  #                        "raise_budget" (over_budget). NOT a kazi action — an
  #                        orchestration hint, per ADR-0023 ("the orchestrator owns
  #                        the policy; kazi stays a pure tool").
  #   * `reason`         — the loop's stop reason (the budget dimension, or "stuck"),
  #                        as a string, or nil on a clean converge.
  #   * `release_ref`    — WHAT was shipped (the T3.3c release tag), or nil.
  #   * `quarantine`     — i795/#795: additive, optional array of predicate ids
  #                        quarantined as flaky (T1.3) at the terminal
  #                        observation. Present only when non-empty. A
  #                        quarantined predicate's status is `:unknown`, so
  #                        `status` can never be "converged" while this is
  #                        present — it names WHY a non-converged result stalled.
  #   * `schema_version` — the contract version (`@run_schema_version`); a breaking
  #                        change bumps it.
  #   * `usage`          — the ADR-0046 economy envelope: an ADDITIVE, optional
  #                        object of the run's token/cost components
  #                        (`input_tokens`, `cached_input_tokens`,
  #                        `cache_write_tokens`, `output_tokens`,
  #                        `reasoning_tokens`, `cost_usd`). Present only when the
  #                        harness reported at least one component; each field is
  #                        omitted when unreported (absent ≠ zero). Strictly
  #                        additive, so `schema_version` stays 2 — the same rule
  #                        ADR-0041's predicate envelope followed; the single
  #                        rolled-up total stays in `budget_spent.tokens` for
  #                        back-compat. See `Kazi.CLI.Usage`.
  #   * `usage_fidelity` — T48.5 (ADR-0058 §4): an ADDITIVE, optional string,
  #                        present ONLY as `"unreported"` when a `max_tokens`
  #                        ceiling was set but a dispatch this run reported no
  #                        usage the loop could count — the ceiling could never
  #                        bind. Absent on every other run.
  #   * `cause`          — T48.4 (ADR-0058 decision 4, UC-064): an ADDITIVE,
  #                        optional object naming the honest terminal cause
  #                        alongside `status`/`reason` — `over_budget` is not
  #                        always genuine budget exhaustion, and `stuck` is not
  #                        always an ordinary failing-set stall. Present only
  #                        when the loop classified one: `{ "class": string,
  #                        "ids": [string] (optional), "reasons": object
  #                        (optional), "exhausted": string (optional) }`, class
  #                        one of `budget_exhausted` / `error_wedged` /
  #                        `quarantine_blocked`. Absent ⇒ no cause classified,
  #                        byte-identical to before this field existed. See
  #                        `Kazi.Loop.CauseClass`.
  #   * `collateral`     — issue #860 proposal 3: an ADDITIVE array of files
  #                        changed during the run that sit outside the goal's
  #                        write scope, net-deletion entries ranked first (see
  #                        `Kazi.CollateralReport`). Present only when non-empty
  #                        (absent ⇒ nothing collateral was found, byte-identical
  #                        to before this field existed).
  #   * `goal_drifted`   — goal-drift-guard-1415: an ADDITIVE boolean, present
  #                        only `true` when the goal-file this run was loaded
  #                        from no longer matches the predicate bar it was
  #                        fingerprinted against at t0 (see
  #                        `Kazi.Runtime.GoalDrift`). Paired with `goal_drift`
  #                        (the added/removed/changed predicate ids). Absent ⇒
  #                        no drift detected, byte-identical to before this
  #                        field existed. Never changes `status` — the loop
  #                        always converges against the ORIGINAL t0 bar.
  @spec run_result_json(
          Goal.t(),
          :converged | :stopped | :over_budget,
          map(),
          map(),
          String.t() | nil
        ) ::
          map()
  defp run_result_json(%Goal{id: id} = goal, outcome, result, economy, workspace) do
    status = run_status(outcome, result)

    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      status: status,
      predicates: predicate_vector_json(result.vector),
      iterations: result.iterations,
      budget_spent: budget_spent_json(result),
      next_action: next_action(status),
      reason: reason_string(Map.get(result, :reason)),
      release_ref: Map.get(result, :release_ref),
      enforcement: enforcement_json(Map.get(result, :enforcement))
    }
    |> put_usage(result)
    |> put_usage_fidelity(result)
    |> put_economy(economy)
    |> put_context_store(result)
    |> put_stuck_bundle(result)
    |> put_quarantine(result)
    |> put_cause(result)
    |> put_integration(result)
    |> put_collateral(goal, workspace)
    |> put_goal_drifted(result)
  end

  # T50.2 (ADR-0065 decision 2): the additive `integration` object — how a
  # worktree-isolated serial run's converged commits landed on the base
  # (`landed: true` + refs), or the surviving `task_branch` + reason when they
  # did not (issue #1407: converged-but-unlanded exits 0 by default, 1 under
  # --strict-landing). Present only when a landing was attempted; absent ⇒
  # byte-identical to before this field existed.
  defp put_integration(map, %{integration: info}) when is_map(info),
    do: Map.put(map, :integration, info)

  defp put_integration(map, _result), do: map

  # issue #860: the additive `collateral` array — files changed this run that
  # sit outside the goal's write scope, net-deletion first. Present only when
  # non-empty; a missing/non-git workspace yields `[]` (degrades to absent,
  # never an error) via `Kazi.CollateralReport.collateral/2`.
  defp put_collateral(map, %Goal{} = goal, workspace) do
    case Kazi.CollateralReport.collateral(goal, workspace) do
      [] -> map
      entries -> Map.put(map, :collateral, Enum.map(entries, &collateral_entry_json/1))
    end
  end

  # goal-drift-guard-1415: the additive `goal_drifted` boolean + `goal_drift`
  # diff — whether the goal-file this run was loaded from (`:goal_source`) no
  # longer matches the predicate bar it was fingerprinted against at t0 by the
  # time the run terminated (see `Kazi.Runtime.GoalDrift`). Present only when a
  # drift was actually detected (`result.goal_drifted` was set by
  # `Kazi.Runtime.run/2`); absent ⇒ byte-identical to before this field
  # existed. Never affects `status` — the ORIGINAL bar already governed
  # convergence regardless of what happened to the file on disk.
  defp put_goal_drifted(map, %{goal_drifted: true, goal_drift: diff}) do
    map
    |> Map.put(:goal_drifted, true)
    |> Map.put(:goal_drift, %{
      added: Enum.map(diff.added, &to_string/1),
      removed: Enum.map(diff.removed, &to_string/1),
      changed: Enum.map(diff.changed, &to_string/1)
    })
  end

  defp put_goal_drifted(map, _result), do: map

  defp collateral_entry_json(%{
         path: path,
         additions: additions,
         deletions: deletions,
         net_deletion: net_deletion
       }) do
    %{path: path, additions: additions, deletions: deletions, net_deletion: net_deletion}
  end

  # i795/#795: the additive `quarantine` array — the predicate ids quarantined
  # as flaky (T1.3) at the terminal observation, named so a non-converged result
  # is diagnosable without re-deriving quarantine state. Present only when
  # non-empty; absent ⇒ byte-identical to today (the ADR-0041/0046 additive
  # rule this whole envelope follows).
  defp put_quarantine(map, %{quarantine: [_ | _] = ids}),
    do: Map.put(map, :quarantine, Enum.sort_by(ids, &to_string/1) |> Enum.map(&to_string/1))

  defp put_quarantine(map, _result), do: map

  # T48.4 (ADR-0058 decision 4, UC-064): the additive `cause` object — the
  # honest terminal cause class alongside `status`/`reason`, so `over_budget`
  # is never the whole story (an operator seeing it should not always raise
  # the budget — a config error stays a config error no matter how big the
  # ceiling is). Present only when the loop classified one (see
  # `Kazi.Loop.CauseClass`); absent ⇒ byte-identical to before this field
  # existed.
  defp put_cause(map, %{cause: %{class: class} = cause}) when is_atom(class) do
    Map.put(map, :cause, cause_json(cause))
  end

  defp put_cause(map, _result), do: map

  defp cause_json(%{class: class, ids: ids, reasons: reasons, exhausted: exhausted}) do
    %{class: to_string(class)}
    |> put_cause_ids(ids)
    |> put_cause_reasons(reasons)
    |> put_cause_exhausted(exhausted)
  end

  defp put_cause_ids(map, [_ | _] = ids),
    do: Map.put(map, :ids, ids |> Enum.sort_by(&to_string/1) |> Enum.map(&to_string/1))

  defp put_cause_ids(map, _ids), do: map

  defp put_cause_reasons(map, reasons) when is_map(reasons) and map_size(reasons) > 0 do
    Map.put(
      map,
      :reasons,
      Map.new(reasons, fn {id, reason} -> {to_string(id), cause_reason_string(reason)} end)
    )
  end

  defp put_cause_reasons(map, _reasons), do: map

  defp put_cause_exhausted(map, nil), do: map
  defp put_cause_exhausted(map, exhausted), do: Map.put(map, :exhausted, to_string(exhausted))

  # A `Kazi.Loop.ErrorPermanence` reason is a bare atom, a `{tag, detail}`
  # tuple, or a string (the live HTTP providers inspect connection errors) —
  # only the atom/string shapes render as plain JSON strings; anything else
  # (a tuple) is rendered with `inspect/1` so the JSON contract never breaks on
  # an un-encodable term.
  defp cause_reason_string(reason) when is_binary(reason), do: reason

  defp cause_reason_string(reason) when is_atom(reason) and not is_nil(reason),
    do: to_string(reason)

  defp cause_reason_string(reason), do: inspect(reason)

  # T35.5 (ADR-0045 §6): the additive `context_store` byte-accounting object, present
  # only when the run used a store. Absent ⇒ the result is byte-identical to today.
  defp put_context_store(map, %{context_store: cs}) when is_map(cs),
    do: Map.put(map, :context_store, cs)

  defp put_context_store(map, _result), do: map

  # T35.6 (ADR-0045 §5): the additive `stuck_bundle` object, present only on a stuck
  # stop, so an escalating orchestrator hands the higher model rung the compact
  # bundle instead of the full transcript. Absent ⇒ byte-identical.
  defp put_stuck_bundle(map, %{stuck_bundle: bundle}) when is_map(bundle),
    do: Map.put(map, :stuck_bundle, bundle)

  defp put_stuck_bundle(map, _result), do: map

  # T34.6 (ADR-0046 §5): attach the additive `economy` object — the run-end KPIs
  # derived from the per-iteration envelopes (cost / converged-predicate, wall-clock
  # / converged-predicate, iterations-to-convergence, fresh-input-avoided,
  # rediscovery-tool-calls-avoided, and this run's stuck flag). `Kazi.Economy.KPIs`
  # OMITS every unavailable KPI (absent ≠ zero), and `status`/`stuck`/`iterations`
  # are always present, so the object is never empty. Strictly additive —
  # `schema_version` stays 2 (the ADR-0041/0046 additive rule).
  defp put_economy(map, economy) when is_map(economy) do
    Map.put(map, :economy, Kazi.Economy.KPIs.to_json(economy))
  end

  defp put_economy(map, _economy), do: map

  # T32.4 (ADR-0042 §7): surface the anti-gaming guarantees that were ACTIVE for the
  # run and any flagged gaming event, so an orchestrator (and a human) can see the
  # bar was held — honesty per the global definition of done. `active: false` when
  # enforcement was off, so the field is always present and machine-parseable. The
  # guarantee atoms render as strings for a stable JSON contract.
  defp enforcement_json(%{active: active, guarantees: guarantees, gaming_events: events}) do
    %{
      active: active,
      guarantees: Enum.map(guarantees, &to_string/1),
      gaming_events: Enum.map(events, &gaming_event_json/1)
    }
  end

  defp enforcement_json(_), do: %{active: false, guarantees: [], gaming_events: []}

  defp gaming_event_json(%{type: type} = event) do
    %{
      type: to_string(type),
      path: Map.get(event, :path),
      iteration: Map.get(event, :iteration)
    }
  end

  # ADR-0046 economy envelope: attach the additive `usage` object ONLY when the
  # harness reported at least one component, omitting the key entirely otherwise
  # (honest-unknown — an absent envelope means "unreported", never zeros). The
  # renderer drops absent fields; here we drop the whole object when nothing was
  # reported, so the pre-envelope contract is byte-identical on a no-usage run.
  defp put_usage(map, result) do
    case Kazi.CLI.Usage.render(Map.get(result, :usage, %{})) do
      usage when map_size(usage) == 0 -> map
      usage -> Map.put(map, :usage, usage)
    end
  end

  # T48.5 (ADR-0058 §4): the additive `usage_fidelity` string — `"unreported"`
  # ONLY when a `max_tokens` ceiling was set and at least one dispatch this run
  # reported no usage at all (the `claw` profile, ADR-0022, by design), so the
  # ceiling could never bind. Absent on every other run (byte-identical to
  # before this field existed) — an orchestrator sees the key only when it
  # names a real problem with its `max_tokens` budget.
  defp put_usage_fidelity(map, %{usage_fidelity: :unreported}),
    do: Map.put(map, :usage_fidelity, "unreported")

  defp put_usage_fidelity(map, _result), do: map

  # A pre-loop run error (vacuous goal, unknown provider/harness, await timeout):
  # the SAME envelope shape, with `status: "error"` and a `next_action` of
  # "investigate", so an orchestrator parses ONE stdout surface across success and
  # failure and branches on the non-zero exit code, never on prose.
  @spec run_error_json(Goal.t(), term(), String.t()) :: map()
  defp run_error_json(%Goal{id: id}, reason, message) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      status: "error",
      error: message,
      reason: reason_string(reason),
      next_action: "investigate"
    }
  end

  # Map the loop outcome (+ reason) to the contract's terminal status. A stuck
  # stop is a `:stopped` loop carrying `reason: :stuck` (T1.5); any other
  # non-converged stop (operator/await) is also surfaced as "stuck" — a
  # non-converged halt the orchestrator should investigate, never a success.
  defp run_status(:converged, _result), do: "converged"
  defp run_status(:over_budget, _result), do: "over_budget"
  defp run_status(:stopped, _result), do: "stuck"

  # The orchestrator's branch hint, derived purely from the terminal status.
  defp next_action("converged"), do: "done"
  defp next_action("over_budget"), do: "raise_budget"

  defp next_action("paused"),
    do: "paused at a frontier boundary; resume by re-running with --resume <resume_token>"

  defp next_action(_), do: "investigate"

  # The predicate vector as a list of `{id, verdict}` objects, sorted by id for a
  # stable, diffable order. An absent/empty vector renders as `[]`.
  #
  # ADR-0041 envelope v2: the graded `score` / `prior_score` / `direction` and the
  # structured `evidence` (LSP-Diagnostic-shaped items) are ADDITIVE, optional
  # per-predicate fields — emitted ONLY when present, so a boolean predicate stays
  # exactly `{id, verdict}` and `schema_version` does not bump (an additive field
  # leaves the contract compatible; docs/schemas/run-result.md §Compatibility).
  @spec predicate_vector_json(Kazi.PredicateVector.t() | nil) :: [map()]
  defp predicate_vector_json(nil), do: []

  defp predicate_vector_json(%Kazi.PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map(fn {id, result} ->
      %{id: to_string(id), verdict: to_string(result.status)}
      |> put_present("score", result.score)
      |> put_present("prior_score", result.prior_score)
      |> put_present("direction", result.direction && to_string(result.direction))
      |> put_evidence(result.diagnostics)
    end)
  end

  # Additive field helpers for the envelope-v2 predicate object: a key is written
  # only when its value is non-default, so a boolean predicate is byte-identical.
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_evidence(map, []), do: map

  defp put_evidence(map, diagnostics) when is_list(diagnostics) do
    Map.put(map, "evidence", Enum.map(diagnostics, &Kazi.Evidence.to_map/1))
  end

  # What the run consumed. `iterations` always; `exceeded` names the budget
  # dimension only when the stop was over-budget, else nil (a clean converge or a
  # stuck stop did not exceed a budget dimension). `tokens` is the single
  # rolled-up token total (ADR-0046 back-compat): an orchestrator pinning the
  # pre-envelope contract keeps reading `budget_spent.tokens` even as the richer,
  # cached-vs-fresh split moves into the additive `usage` envelope. A run with no
  # reported tokens renders 0 (the legacy field was always an integer).
  defp budget_spent_json(result) do
    %{
      iterations: result.iterations,
      exceeded: budget_exceeded(result),
      tokens: Map.get(result, :tokens_used, 0)
    }
  end

  defp budget_exceeded(%{outcome: :over_budget, reason: reason}), do: reason_string(reason)
  defp budget_exceeded(_result), do: nil

  # Render a loop stop reason (an atom dimension, `:stuck`, a tuple, or nil) as a
  # JSON-friendly string, or nil when there is no reason (a clean converge).
  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: to_string(reason)
  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason), do: inspect(reason)

  # =============================================================================
  # collective result (T21.8, ADR-0027): render + version the scheduler's verdict
  # =============================================================================
  #
  # `run --parallel` drives `Kazi.Scheduler.run_goals/2`, whose result is one of
  # two shapes:
  #
  #   * FLAT (ADR-0027) — `%{collective:, partitions: [{partition, status}]}` when
  #     no group declares `needs`; the CLI renders the per-partition view.
  #   * DAG  (ADR-0028) — `%{collective:, groups: [{group_id, status}], blocked:}`
  #     when the goal carries a `needs`-DAG over its groups; the CLI renders the
  #     per-GROUP SCHEDULE (T23.6): the topological frontier each group ran in, its
  #     convergence state, and any BLOCKED sub-DAG (naming the blocking dep).
  #
  # The CLI only RENDERS + VERSIONS the scheduler result — it invents no scheduler
  # semantics; the frontier layering is a PURE function of the goal's `needs` graph
  # (mirroring `Kazi.Goal.DepGraph`, the scheduler's own planner). Under --json it
  # emits the versioned COLLECTIVE object (docs/schemas/collective-result.md);
  # otherwise a human block. Both share the SAME result; only the shape differs.
  defp report_collective(%Goal{} = goal, result, json?) do
    emit(json?, collective_result_json(goal, result), fn ->
      report_collective_human(goal, result)
    end)
  end

  # The human collective block. For a FLAT result: the verdict + one line per
  # partition. For a DAG result (T23.6): the verdict + the per-GROUP schedule
  # (frontier order + state) + any blocked sub-DAG. The --json surface carries the
  # precise keys; the human block is a legible summary.
  defp report_collective_human(%Goal{id: id}, %{partitions: partitions} = result) do
    IO.puts("COLLECTIVE #{result.collective |> to_string() |> String.upcase()}  goal=#{id}")
    IO.puts("partitions: #{length(partitions)}")

    landed = landed_index(result)

    partitions
    |> Enum.with_index()
    |> Enum.each(fn {{partition, status}, index} ->
      IO.puts(
        "  [#{index}] #{partition_id(partition, index)}: #{status}" <>
          landed_human(Map.get(landed, partition_key(partition)))
      )
    end)
  end

  defp report_collective_human(%Goal{id: id} = goal, %{groups: groups} = result) do
    schedule = schedule_view(goal, groups)

    IO.puts("COLLECTIVE #{result.collective |> to_string() |> String.upcase()}  goal=#{id}")
    IO.puts("frontiers: #{length(schedule)}")
    print_schedule_frontiers(schedule)
    print_blocked_human(Map.get(result, :blocked, []))

    # T50.3/T50.6: a paused run's checkpoint handle, mirroring the fleet report.
    case Map.get(result, :resume_token) do
      nil -> :ok
      token -> IO.puts("resume_token: #{token}")
    end
  end

  # T44.10: the per-group landed refs appended to a partition's human status line,
  # e.g. " landed=kazi-partition/p-… pr=42". Empty when the group did not land.
  defp landed_human(nil), do: ""

  defp landed_human(refs) when is_map(refs) do
    parts =
      [
        {"landed", Map.get(refs, :branch)},
        {"pr", Map.get(refs, :pr)},
        {"merge", Map.get(refs, :merge_commit)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    if parts == "", do: "", else: "  " <> parts
  end

  defp print_schedule_frontiers(schedule) do
    Enum.each(schedule, fn %{frontier: index, groups: groups} ->
      line =
        Enum.map_join(groups, ", ", fn %{group: gid, state: state} ->
          "#{gid}(#{state})"
        end)

      IO.puts("  frontier #{index}: #{line}")
    end)
  end

  defp print_blocked_human([]), do: :ok

  defp print_blocked_human(blocked) do
    IO.puts("blocked: #{length(blocked)}")

    Enum.each(blocked, fn %{group: gid, blocked_by: dep, reason: reason} ->
      IO.puts("  #{gid} blocked by #{dep} (#{reason})")
    end)
  end

  # The versioned COLLECTIVE result object (T21.8/T23.6, ADR-0027 + ADR-0028,
  # docs/schemas/collective-result.md). The FLAT clause carries `partitions`; the
  # DAG clause carries `schedule` + `blocked`. Both share schema_version /
  # collective / next_action / goal_id.
  #
  #   * `schema_version` — the shared contract version (`@run_schema_version`).
  #   * `goal_id`        — the goal-set's goal id (the run's handle).
  #   * `collective`     — the COLLECTIVE verdict the scheduler folded:
  #                        "converged" / "stuck" / "over_budget".
  #   * `partitions`     — (FLAT only) one entry per partition, in input order:
  #                        `{partition_id, goal_ids, status}`.
  #   * `schedule`       — (DAG only, T23.6) the topological frontiers taken: one
  #                        `{frontier, groups: [{group, state}]}` per wave, plus a
  #                        per-group `frontier` index so a group maps to its wave.
  #   * `blocked`        — (DAG only, T23.6) the blocked sub-DAG: one
  #                        `{group, blocked_by, reason}` per group an unsatisfiable
  #                        dep poisoned (empty when nothing is blocked).
  #   * `next_action`    — a single orchestration hint derived from `collective`.
  defp collective_result_json(%Goal{id: id}, %{partitions: partitions} = result) do
    collective_str = to_string(result.collective)

    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      collective: collective_str,
      partitions: partitions_json(partitions, landed_index(result)),
      next_action: next_action(collective_str)
    }
  end

  defp collective_result_json(%Goal{id: id} = goal, %{groups: groups} = result) do
    collective_str = to_string(result.collective)
    blocked = Map.get(result, :blocked, [])

    base = %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      collective: collective_str,
      schedule: schedule_json(goal, groups),
      blocked: blocked_json(blocked),
      next_action: next_action(collective_str)
    }

    # T50.3/T50.6: a run paused at a wave boundary (--pause-between-waves)
    # carries its checkpoint handle — ADDITIVE (schema_version unchanged),
    # mirroring the fleet result's resume_token.
    case Map.get(result, :resume_token) do
      nil -> base
      token -> Map.put(base, :resume_token, token)
    end
  end

  defp partitions_json(partitions, landed_index) do
    partitions
    |> Enum.with_index()
    |> Enum.map(fn {{partition, status}, index} ->
      base = %{
        partition_id: partition_id(partition, index),
        goal_ids: partition_goal_ids(partition),
        status: to_string(status)
      }

      # T44.10 (ADR-0055): a converged partition that LANDED carries its per-group
      # landed refs (`{branch, pr, merge_commit}`) — ADDITIVE, so a run with no
      # `[integration]` landing (mode :none) omits the field entirely and the
      # object is byte-identical to the pre-T44.10 partition entry.
      case Map.get(landed_index, partition_key(partition)) do
        nil -> base
        refs -> Map.put(base, :landed, landed_json(refs))
      end
    end)
  end

  # T62.6 (issue #1241 part 2): project the collective's per-group landed refs
  # into the read-model, keyed by the run handle (`goal.id`) + each group's
  # stable partition id — the SAME id `partitions_json` surfaces — so `kazi
  # status <goal-id>` shows the per-group `{branch, pr, merge_commit}` detail
  # after the fact. A run with no landing (mode :none / an empty landed index)
  # writes nothing, leaving status byte-identical to the pre-T62.6 surface.
  defp persist_landed_refs(%Goal{id: id}, %{partitions: partitions} = result) do
    landed = landed_index(result)

    entries =
      partitions
      |> Enum.with_index()
      |> Enum.flat_map(fn {{partition, _status}, index} ->
        case Map.get(landed, partition_key(partition)) do
          nil ->
            []

          refs ->
            [
              Map.put(landed_json(refs), :partition_id, partition_id(partition, index))
            ]
        end
      end)

    if entries != [], do: ReadModel.record_landed_refs(id, entries)

    :ok
  end

  # A DAG/group collective (or any result without a flat `:partitions` list) has
  # no per-partition landed index to persist here (its landing is surfaced
  # per-group elsewhere); a no-op keeps this total.
  defp persist_landed_refs(_goal, _result), do: :ok

  # Index the collective integration's per-partition landed refs by the partition's
  # stable key, so `partitions_json` can attribute each group's landing to its
  # partition entry. Absent integration (mode :none / no landing) → an empty index,
  # so nothing is attached.
  defp landed_index(result) do
    case Map.get(result, :integration) do
      %{integrated: integrated} when is_list(integrated) ->
        for {partition, refs} <- integrated,
            key = partition_key(partition),
            is_binary(key),
            into: %{},
            do: {key, refs}

      _ ->
        %{}
    end
  end

  defp partition_key(%Kazi.Scheduler.Partitioner{key: key}), do: key
  defp partition_key(%{key: key}) when is_binary(key), do: key
  defp partition_key(_partition), do: nil

  # The per-group landed refs surfaced in the collective JSON: only the keys the
  # integrator actually returned (`branch`/`pr`/`merge_commit`), stringified.
  defp landed_json(refs) when is_map(refs) do
    %{}
    |> maybe_put_ref(:branch, Map.get(refs, :branch))
    |> maybe_put_ref(:pr, Map.get(refs, :pr))
    |> maybe_put_ref(:merge_commit, Map.get(refs, :merge_commit))
  end

  defp maybe_put_ref(map, _key, nil), do: map
  defp maybe_put_ref(map, key, value), do: Map.put(map, key, ref_value(value))

  defp ref_value(v) when is_binary(v) or is_integer(v), do: v
  defp ref_value(v), do: to_string(v)

  # A partition's stable id for the result: the `Kazi.Scheduler.Partitioner` lease
  # `:key` (overlapping partitions share it, disjoint differ). A bare/unkeyed
  # partition term falls back to its index so the surface is always total.
  defp partition_id(%Kazi.Scheduler.Partitioner{key: key}, _index) when is_binary(key), do: key
  defp partition_id(%{key: key}, _index) when is_binary(key), do: key
  defp partition_id(_partition, index), do: "partition-#{index}"

  # The ids of the goals a partition carries (the member `%Kazi.Goal{}` structs),
  # so an orchestrator can map a partition's verdict back to its goals. A partition
  # term that carries no goals renders an empty list.
  defp partition_goal_ids(%Kazi.Scheduler.Partitioner{goals: goals}) when is_list(goals),
    do: Enum.map(goals, &goal_id_string/1)

  defp partition_goal_ids(%{goals: goals}) when is_list(goals),
    do: Enum.map(goals, &goal_id_string/1)

  defp partition_goal_ids(_partition), do: []

  defp goal_id_string(%Goal{id: id}), do: to_string(id)
  defp goal_id_string(other), do: to_string(inspect(other))

  # =============================================================================
  # schedule reporting + --explain / --dry-run (T23.6, ADR-0028)
  # =============================================================================
  #
  # ADR-0028 §Consequences: "the scheduler can PRINT the computed order so
  # over-constraint is visible". This is that surface — both the schedule embedded
  # in the collective DAG result AND the standalone `--explain` dry-run. Both share
  # one PURE function — `frontiers/1` — that mirrors `Kazi.Goal.DepGraph`'s ready-set
  # logic (the planner the real scheduler drives) to layer the `needs`-DAG into
  # topological FRONTIERS, without touching the scheduler or dispatching anything.

  # The topological FRONTIERS of a goal's `needs`-DAG (T23.6): delegates to
  # `Kazi.Goal.DepGraph.frontiers/1`, the ONE place this layering is computed —
  # mission control's roadmap wave grouping (ADR-0070) reuses the same function, so
  # `--explain` and mission control can never disagree on a goal's schedule.
  @spec frontiers(Goal.t()) :: [[Group.id()]]
  defp frontiers(%Goal{} = goal), do: DepGraph.frontiers(goal)

  # The per-group SCHEDULE VIEW shared by the human + JSON collective renderers
  # (T23.6): one entry per frontier, in topological order, each carrying its groups
  # (in declared order) with the group's observed convergence STATE from the
  # scheduler's per-group outcomes. `groups` is the result's `[{group_id, status}]`.
  defp schedule_view(%Goal{} = goal, groups) do
    states = Map.new(groups, fn {id, status} -> {to_string(id), status} end)

    goal
    |> frontiers()
    |> Enum.with_index()
    |> Enum.map(fn {ids, index} ->
      %{
        frontier: index,
        groups:
          Enum.map(ids, fn id ->
            %{group: id, state: to_string(Map.get(states, id, :pending))}
          end)
      }
    end)
  end

  # The `schedule` JSON value for the collective DAG result (T23.6): the frontier
  # waves with each group's state, plus a flat `frontier` index per group so an
  # orchestrator maps a group to its wave without re-deriving the DAG.
  defp schedule_json(%Goal{} = goal, groups) do
    schedule_view(goal, groups)
  end

  # The `blocked` JSON value: one `{group, blocked_by, reason}` per blocked group,
  # passing through `Kazi.Goal.DepGraph.blocked_entry/0` (the scheduler's own
  # attribution), so the report NAMES the blocking dep rather than hanging silently.
  defp blocked_json(blocked) do
    Enum.map(blocked, fn %{group: group, blocked_by: dep, reason: reason} ->
      %{group: to_string(group), blocked_by: to_string(dep), reason: to_string(reason)}
    end)
  end

  # ---------------------------------------------------------------------------
  # --explain / --dry-run: print the schedule, dispatch NOTHING, exit 0
  # ---------------------------------------------------------------------------
  #
  # PURE PLANNING (ADR-0028 §Consequences). Computes the `needs`-DAG frontiers
  # (`frontiers/1`) and, within each frontier, the blast-radius PARTITIONING
  # (`Kazi.Partition.partition/3` over the injected graph source — the same
  # disjoint-by-construction grouping the real scheduler uses), prints them, and
  # returns 0. It dispatches NOTHING: no reconciler, harness, lease, or worktree is
  # ever invoked — so a spy reconciler in `runtime_opts` is provably never called.
  # Under --json it emits the schedule as one JSON object; NON-INTERACTIVE.
  defp explain_schedule(%Goal{} = goal, opts, runtime_opts) do
    workspace = opts[:workspace] || goal.scope.workspace
    json? = opts[:json] == true

    frontiers = frontiers(goal)
    partition_opts = Keyword.take(runtime_opts, [:graph_source])

    schedule = explain_frontiers(goal, frontiers, workspace, partition_opts)

    emit(json?, explain_json(goal, schedule, workspace), fn ->
      explain_human(goal, schedule, workspace)
    end)

    0
  end

  # For each frontier, expand the groups into their blast-radius partitions (the
  # parallelism WITHIN the wave). Each group becomes a `Kazi.Partition` input keyed
  # by its id, carrying the group's predicate terms; overlapping groups land in one
  # partition (they serialize), disjoint groups in separate partitions (they run in
  # parallel). A goal with no group-level partition terms yields one singleton
  # partition per group — still honest: each group is its own parallel unit.
  defp explain_frontiers(%Goal{} = goal, frontiers, workspace, partition_opts) do
    frontiers
    |> Enum.with_index()
    |> Enum.map(fn {group_ids, index} ->
      partitions = explain_partition(goal, group_ids, workspace, partition_opts)
      %{frontier: index, groups: group_ids, partitions: partitions}
    end)
  end

  # The blast-radius partitions of one frontier's groups: build a `{group_id, terms}`
  # input per group (terms = the group's predicate partition terms, falling back to
  # the group id so a group always has a non-empty radius and is its own unit), then
  # partition. Pure + hermetic with an injected `:graph_source` (a test stub); the
  # production default is the repo-map source.
  defp explain_partition(%Goal{} = goal, group_ids, workspace, partition_opts) do
    inputs = Enum.map(group_ids, fn id -> {id, group_terms(goal, id)} end)

    Partition.partition(inputs, workspace, partition_opts)
  end

  # A group's partition terms: the changed-file/symbol terms its predicates declare,
  # de-duplicated. Falls back to the group id when a group declares none, so every
  # group expands to a non-empty (singleton) blast radius rather than vanishing.
  defp group_terms(%Goal{} = goal, group_id) do
    terms =
      goal
      |> Goal.all_predicates()
      |> Enum.filter(fn pred -> Map.get(pred, :group) == group_id end)
      |> Enum.flat_map(&predicate_terms/1)
      |> Enum.uniq()

    case terms do
      [] -> [group_id]
      terms -> terms
    end
  end

  # A predicate's partition terms, if any — its declared `partition_terms` metadata
  # (mirroring `Kazi.Partition`'s goal-level seam). Absent ⇒ none (the group id is
  # the fallback in `group_terms/2`).
  defp predicate_terms(%{metadata: %{partition_terms: terms}}) when is_list(terms), do: terms
  defp predicate_terms(_pred), do: []

  # The human dry-run block: the frontier count, then one block per frontier showing
  # its groups and — within the frontier — the blast-radius partitions (the
  # parallelism). A single frontier means everything is parallel; N frontiers means
  # the DAG serializes into N waves (over-constraint made visible).
  defp explain_human(%Goal{id: id}, schedule, workspace) do
    IO.puts("SCHEDULE (dry-run, nothing dispatched)  goal=#{id}")
    IO.puts("frontiers: #{length(schedule)}")
    # T59.9 (#937 Gap F): the isolation base every partition's worktree lives
    # under — so a caller can CONFIRM per-partition isolation up front, before a
    # long grind, rather than discovering it via `git worktree list` mid-run.
    IO.puts("isolation: git worktree per partition, under #{explain_base_dir()}")
    IO.puts("workspace root (never a partition's cwd): #{workspace}")

    Enum.each(schedule, fn %{frontier: index, groups: groups, partitions: partitions} ->
      IO.puts("  frontier #{index}: #{Enum.join(groups, ", ")}")
      IO.puts("    parallelism: #{length(partitions)} partition(s)")

      partitions
      |> Enum.with_index()
      |> Enum.each(fn {partition, p_index} ->
        ids = Enum.join(partition.goal_ids, ", ")
        %{worktree_prefix: prefix} = partition_isolation(partition, workspace)
        IO.puts("    [#{p_index}] #{partition_id(partition, p_index)}: #{ids}")
        IO.puts("        isolated working dir: #{prefix}-<nonce>")
      end)
    end)
  end

  # The `--explain --json` object (T23.6): the computed schedule as a single JSON
  # object — the frontiers + the per-frontier partitioning — with `dispatched: false`
  # making the no-execution contract explicit and machine-checkable.
  defp explain_json(%Goal{id: id}, schedule, workspace) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      mode: "explain",
      dispatched: false,
      # T59.9 (#937 Gap F): the per-run isolation plan — git worktree per
      # partition, under the managed base dir, NEVER the workspace root. Each
      # partition below also carries its own `isolation` (the planned working dir).
      isolation: %{
        strategy: "worktree_per_partition",
        base_dir: explain_base_dir(),
        workspace_root: workspace
      },
      frontiers: Enum.map(schedule, &explain_frontier_json(&1, workspace)),
      next_action: "schedule"
    }
  end

  defp explain_frontier_json(
         %{frontier: index, groups: groups, partitions: partitions},
         workspace
       ) do
    %{
      frontier: index,
      groups: Enum.map(groups, &to_string/1),
      partitions:
        partitions
        |> Enum.with_index()
        |> Enum.map(fn {partition, p_index} ->
          %{
            partition_id: partition_id(partition, p_index),
            goal_ids: Enum.map(partition.goal_ids, &to_string/1),
            # T59.9: this partition's PLANNED isolated working dir — a managed
            # git worktree, provably distinct from the workspace root, so a
            # caller can confirm isolation before dispatching.
            isolation: explain_partition_isolation_json(partition, workspace)
          }
        end)
    }
  end

  defp explain_partition_isolation_json(partition, workspace) do
    %{worktree_prefix: prefix} = partition_isolation(partition, workspace)

    %{
      isolated: true,
      working_dir_prefix: prefix,
      workspace_root: workspace
    }
  end

  # T59.9 (#937 Gap F): the PLANNED per-partition isolation, derived from the SAME
  # `Kazi.Scheduler.Worktree` primitives the real run uses — the managed base dir
  # and the deterministic per-partition slug. The on-disk path appends a random
  # nonce at dispatch (so two runs never collide), so this surfaces the stable
  # PREFIX; the invariant a caller checks is that it is under the managed base dir
  # and is NOT the workspace root, which holds for every partition.
  defp partition_isolation(partition, workspace) do
    slug = Kazi.Scheduler.Worktree.slug_for(partition)
    prefix = Path.join(explain_base_dir(), slug)
    %{worktree_prefix: prefix, workspace_root: workspace}
  end

  defp explain_base_dir, do: Kazi.Scheduler.Worktree.default_base_dir()

  # ===========================================================================
  # --check: observe-only mode (issue #805, ADR-0026 L1)
  # ===========================================================================
  #
  # Evaluates the goal's full predicate vector EXACTLY ONCE through
  # `Kazi.Runtime.check/2` (the same real provider dispatch `run/2` uses at t0)
  # and reports a terminal PASS/FAIL — no harness dispatch, no integrate/deploy,
  # ever. Unlike a normal `apply`, an all-pass vector is the intended success case
  # (`status: "pass"`, exit 0), not the vacuous_goal rejection: confirming an
  # already-green vector is the whole point of a check.

  defp check_goal(%Goal{} = goal, opts, runtime_opts) do
    workspace = opts[:workspace] || goal.scope.workspace
    json? = opts[:json] == true

    check_opts = Keyword.take(runtime_opts, [:providers, :enforcement]) ++ [workspace: workspace]

    case Runtime.check(goal, check_opts) do
      {:ok, %{status: status, vector: vector}} ->
        report_check(goal, status, vector, json?)
        if status == :pass, do: 0, else: 1

      {:error, reason} ->
        report_run_error(goal, reason, json?)
        1
    end
  end

  defp report_check(%Goal{} = goal, status, vector, json?) do
    emit(json?, check_result_json(goal, status, vector), fn ->
      check_human(goal, status, vector)
    end)
  end

  defp check_human(%Goal{id: id}, status, vector) do
    IO.puts("CHECK (observe-only, nothing dispatched)  goal=#{id}")
    IO.puts("status: #{status}")

    Enum.each(check_results(vector), fn {predicate_id, result} ->
      IO.puts("  #{predicate_id}: #{result.status}")

      case format_reason(result) do
        nil -> :ok
        reason -> IO.puts("    #{reason}")
      end
    end)
  end

  # One human line for an ERRORED predicate's reason (issue #1096). An :error
  # means the checker could not run at all, and a check has no later iteration to
  # carry the evidence — so printing a bare `error` told the operator something
  # broke but never what. The --json surface keeps the reason structured; this is
  # its prose counterpart. Passing/failing predicates have no reason to print.
  defp format_reason(%{status: :error, evidence: %{reason: reason} = evidence}) do
    "reason: " <> reason_text(reason, evidence[:cmd])
  end

  defp format_reason(_result), do: nil

  defp reason_text({:cmd_unrunnable, message}, cmd),
    do: "exec failed: #{cmd}: #{exec_error_text(message)}"

  defp reason_text({:timeout_ms, ms}, _cmd), do: "timed out after #{ms}ms"
  defp reason_text({:error_exit, code}, _cmd), do: "checker could not run (exit #{code})"
  defp reason_text(reason, _cmd) when is_binary(reason), do: reason
  defp reason_text(reason, _cmd) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason, _cmd), do: inspect(reason)

  # A failed exec reaches us as the raw POSIX atom `System.cmd/3` raised
  # ("Erlang error: :enoent"), which reads as noise to an operator. Name the two
  # they actually hit; anything else passes through verbatim.
  defp exec_error_text(message) when is_binary(message) do
    cond do
      String.contains?(message, ":enoent") -> "not found"
      String.contains?(message, ":eacces") -> "permission denied"
      true -> message
    end
  end

  defp exec_error_text(message), do: inspect(message)

  # The `--check --json` object: a single terminal verdict (never a loop
  # outcome — `run_status/2` doesn't apply here) with `dispatched: false` making
  # the no-execution contract explicit and machine-checkable, mirroring the
  # `--explain` JSON shape.
  defp check_result_json(%Goal{id: id}, status, vector) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      mode: "check",
      status: to_string(status),
      dispatched: false,
      predicates: check_predicates_json(vector),
      next_action: if(status == :pass, do: "done", else: "investigate")
    }
  end

  # The check-mode predicate list: `{id, verdict}` (same shape as
  # `predicate_vector_json/1`) PLUS the captured `evidence` for a predicate that
  # did not pass — there is no later iteration to carry it, so a check's failure
  # report must be self-contained (issue #805). `:error` carries evidence for the
  # same reason `:fail` does: a checker that could not run is the case most in
  # need of a diagnostic, and dropping it left a bare, unactionable `error`
  # (issue #1096). Passing predicates omit `evidence` (nothing to investigate).
  defp check_predicates_json(%Kazi.PredicateVector{} = vector) do
    Enum.map(check_results(vector), fn {id, result} ->
      base = %{id: to_string(id), verdict: to_string(result.status)}

      if result.status in [:fail, :error] do
        Map.put(base, :evidence, evidence_json(result.evidence))
      else
        base
      end
    end)
  end

  defp check_results(%Kazi.PredicateVector{results: results}) do
    Enum.sort_by(results, fn {id, _} -> to_string(id) end)
  end

  # Evidence is provider-supplied and an `:error` result's carries terms Jason
  # cannot encode — notably a tuple `reason` like `{:cmd_unrunnable, "..."}`,
  # which would raise on the way out and take the whole report with it (the
  # encoder-side sibling of L-0010's persistence crash). Deep-sanitize to
  # JSON-safe: stringify keys and atoms, keep scalars, inspect anything else.
  # A JSON-safe map is unchanged by this, so `:fail` evidence renders as before.
  defp evidence_json(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp evidence_json(v) when is_atom(v), do: to_string(v)
  defp evidence_json(v) when is_list(v), do: Enum.map(v, &evidence_json/1)

  defp evidence_json(v) when is_map(v) and not is_struct(v) do
    Map.new(v, fn {k, val} -> {to_string(k), evidence_json(val)} end)
  end

  defp evidence_json(v), do: inspect(v)

  # =============================================================================
  # economy (T48.8, ADR-0058 decision 2 precursor): aggregate-view rendering
  # =============================================================================
  #
  # `execute_economy/1` above dispatches here for the default (non
  # `--rediscovery`) view. The percentile grouping + honest-unknown
  # nil-safety (ADR-0046) live in `Kazi.Economy.History`; this layer only
  # renders the aggregate on the --json / human surfaces, the same split as
  # `list-proposed`/`status`.

  # The `economy --json` result (T48.8): `groups` mirrors
  # `Kazi.Economy.History.aggregate/1`'s shape; `goal_filter` echoes the
  # optional --goal so a caller confirms what was aggregated (nil means every
  # goal on this read-model).
  defp economy_json(%{groups: groups}, goal_filter) do
    %{
      schema_version: @run_schema_version,
      goal_filter: goal_filter,
      groups: Enum.map(groups, &economy_group_json/1)
    }
  end

  defp economy_group_json(group) do
    %{
      goal_shape_bucket: group.goal_shape_bucket,
      model: group.model,
      harness: group.harness,
      n: group.n,
      n_with_usage: group.n_with_usage,
      tokens: group.tokens,
      cost_usd: group.cost_usd,
      dispatch_count: group.dispatch_count,
      # T49.9: `dispatch_count` above stays the both-roles total; this names who
      # spent it (fixer vs demonstrator). Keys are the iteration `action_kind`s.
      dispatch_by_role: group.dispatch_by_role,
      wall_clock_s: group.wall_clock_s
    }
  end

  defp report_economy(%{groups: []}, goal_filter) do
    IO.puts("ECONOMY    filter=#{goal_filter || "(all goals)"}")
    IO.puts("(no finished-run history yet)")
  end

  defp report_economy(%{groups: groups}, goal_filter) do
    IO.puts("ECONOMY    filter=#{goal_filter || "(all goals)"}")
    IO.puts("#{length(groups)} group(s):\n")

    Enum.each(groups, fn group ->
      IO.puts(
        "  bucket=#{group.goal_shape_bucket} model=#{group.model || "unknown"} " <>
          "harness=#{group.harness || "unknown"} n=#{group.n} n_with_usage=#{group.n_with_usage}"
      )

      IO.puts("    tokens p50/p95:         #{fmt_pair(group.tokens)}")
      IO.puts("    cost_usd p50/p95:       #{fmt_pair(group.cost_usd)}")
      IO.puts("    dispatch_count p50/p95: #{fmt_pair(group.dispatch_count)}")

      Enum.each(group.dispatch_by_role, fn {kind, pair} ->
        IO.puts("      #{fmt_role(kind)} p50/p95:#{fmt_role_pad(kind)}#{fmt_pair(pair)}")
      end)

      IO.puts("    wall_clock_s p50/p95:   #{fmt_pair(group.wall_clock_s)}")
    end)
  end

  # `dispatch_agent` -> "fixer", `dispatch_demonstrator` -> "demonstrator" (T49.9):
  # the human surface names the ROLE, not the internal action kind the JSON keys on.
  defp fmt_role(:dispatch_agent), do: "fixer"
  defp fmt_role(:dispatch_demonstrator), do: "demonstrator"
  defp fmt_role(kind), do: to_string(kind)

  defp fmt_role_pad(:dispatch_agent), do: "        "
  defp fmt_role_pad(_kind), do: " "

  defp fmt_pair(%{p50: p50, p95: p95}), do: "#{fmt_metric(p50)}/#{fmt_metric(p95)}"

  defp fmt_metric(nil), do: "unknown"
  defp fmt_metric(value), do: to_string(value)
end
