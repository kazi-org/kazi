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

  ## Verbs (T27.1, ADR-0032)

  `apply` (converge a goal) and `plan` (author intent) are the PRIMARY verbs,
  matching the operator's `/apply` and `/plan` vocabulary. `run`/`propose` are kept
  as DEPRECATED ALIASES: they dispatch to the same handlers (`apply` == `run`,
  `plan` == `propose`) and print a one-line deprecation hint to STDERR — never into
  `--json` stdout, which stays JSON-only (T15.7). The aliases are scheduled for
  removal in a later minor (a written deprecation window).

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
  alias Kazi.Authoring.Clarify.Question
  alias Kazi.Authoring.RationaleAdr
  alias Kazi.Export.Obsidian
  alias Kazi.Goal.DepGraph
  alias Kazi.Goal.Group
  alias Kazi.Goal.GroupLint
  alias Kazi.Partition
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Teach.InstallSkill

  @typedoc "Process exit code: 0 on convergence, non-zero otherwise."
  @type exit_code :: non_neg_integer()

  # The versioned machine-result contract version (ADR-0023 decision 2). Shared by
  # every --json surface — `run` (T15.3), `status` (T15.5), and the authoring
  # transitions (T15.6) — so a breaking change to any of them bumps one number an
  # orchestrator pins. Defined here (before first use) so the helpers throughout
  # the module can reference it.
  @run_schema_version 1

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
    status: :string,
    enrich: :boolean,
    out: :string,
    dir: :string,
    harness: :string,
    model: :string,
    yes: :boolean,
    strict: :boolean,
    adr: :boolean,
    predicates: :string,
    obsidian: :string,
    json: :boolean,
    stream: :boolean,
    parallel: :boolean,
    parallelism: :integer,
    explain: :boolean,
    dry_run: :boolean,
    help: :boolean,
    version: :boolean
  ]

  @aliases [h: :help, v: :version]

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
    status:
      "Filter `list-proposed` to one lifecycle state (proposed / approved / rejected). Default: all.",
    enrich:
      "`init` only: opt into harness enrichment (off by default) to propose live predicates.",
    out: "`init` output goal-file (default <repo>/kazi.goal.toml).",
    dir:
      "`install-skill` only: target skill directory (default ~/.claude/skills/kazi). Injected to a tmp dir in tests.",
    harness:
      "Coding harness to drive: claude (default) or opencode. Overrides the goal-file/app config.",
    model:
      "Model the harness should use, e.g. dgx/qwen3.6. Overrides the goal-file's [harness] model.",
    yes: "`propose` only: skip the interactive clarify questions and draft best-effort.",
    strict:
      "`propose` only: refuse an underspecified idea non-interactively instead of guessing.",
    adr:
      "`propose` only: also write an ADR-lite rationale doc under docs/adr/ for the drafted goal.",
    predicates:
      "`propose` only (caller-drafts): a proposal payload the caller already authored; kazi spawns no model.",
    obsidian:
      "`export` only: the target directory for the Obsidian vault (group/predicate notes + Mermaid).",
    json:
      "Emit a single JSON object to stdout instead of human prose (the machine surface; NON-INTERACTIVE).",
    stream: "`run --json` only: emit a JSONL progress stream, one event per loop iteration.",
    parallel:
      "`run` only: drive the PARALLEL scheduler over the partitioned goal-set instead of the serial loop; under --json emits the collective result. An optional `--parallel N` records a concurrency hint.",
    explain:
      "`run` only: PRINT the computed wave schedule (the topological `needs`-DAG frontiers + the blast-radius parallelism within each) and EXIT 0 WITHOUT EXECUTING — dispatches nothing, so over-constraint is visible before a run. Under --json emits the schedule as JSON. Alias of --dry-run.",
    dry_run:
      "`run` only: alias of --explain — print the computed schedule and exit 0 without dispatching anything.",
    help: "Show this help and exit.",
    version: "Print the kazi version and exit."
  }

  # The command table. Each entry: a one-line summary, the positional args (name +
  # whether required), and the flags (the `@switches` atoms) it accepts. `help
  # --json` renders this verbatim; the parser dispatches on the same names below.
  #
  # T27.1 (ADR-0032): `apply`/`plan` are the PRIMARY verbs; `run`/`propose` stay as
  # DEPRECATED ALIASES (`deprecated: true`, `alias_of:` the primary). They dispatch
  # to the same handlers (`apply` == `run`, `plan` == `propose`) and emit a
  # one-line stderr deprecation hint when used; the table keeps both so the
  # coherence guard (T16.4) and the shipped skill/AGENTS.md (which reference
  # run/propose) stay valid through the deprecation window. T27.4 fully wires the
  # primary/alias distinction into `help --json`/`schema`; here apply/plan are real
  # commands the table knows and the parser dispatches.
  @commands [
    %{
      name: "apply",
      summary: "Drive a goal-file to convergence against a target workspace.",
      args: [%{name: "goal-file", required: true}],
      flags: [
        :workspace,
        :env,
        :standing,
        :harness,
        :model,
        :json,
        :stream,
        :parallel,
        :explain,
        :dry_run
      ]
    },
    %{
      name: "run",
      summary: "Deprecated alias of `apply` (drive a goal-file to convergence).",
      deprecated: true,
      alias_of: "apply",
      args: [%{name: "goal-file", required: true}],
      flags: [
        :workspace,
        :env,
        :standing,
        :harness,
        :model,
        :json,
        :stream,
        :parallel,
        :explain,
        :dry_run
      ]
    },
    %{
      name: "status",
      summary: "Report a run/proposal's current state from the read-model (a pure read).",
      args: [%{name: "ref", required: true}],
      flags: [:json]
    },
    %{
      name: "init",
      summary: "Adopt a repo by stack detection and write a starter goal-file.",
      args: [%{name: "repo-dir", required: true}],
      flags: [:out, :enrich, :workspace]
    },
    %{
      name: "install-skill",
      summary:
        "Write the kazi Claude Code skill (opt-in) so an orchestrating agent knows the recipe.",
      args: [],
      flags: [:dir]
    },
    %{
      name: "plan",
      summary:
        "Draft a goal of acceptance predicates from a prose idea (or caller-supplied predicates).",
      args: [%{name: "idea", required: false}],
      flags: [:workspace, :yes, :strict, :adr, :json, :predicates]
    },
    %{
      name: "propose",
      summary: "Deprecated alias of `plan` (draft a goal of acceptance predicates).",
      deprecated: true,
      alias_of: "plan",
      args: [%{name: "idea", required: false}],
      flags: [:workspace, :yes, :strict, :adr, :json, :predicates]
    },
    %{
      name: "list-proposed",
      summary: "List the proposal queue, optionally filtered by lifecycle state.",
      args: [],
      flags: [:status, :json]
    },
    %{
      name: "approve",
      summary: "Transition a proposal proposed → approved (then runnable by `kazi run`).",
      args: [%{name: "proposal-ref", required: true}],
      flags: [:json]
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
        "Advisory: warn on near-duplicate group NAMES in a goal-file (exit 0 even with warnings).",
      args: [%{name: "goal-file", required: true}],
      flags: [:json]
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
        "Emit the versioned result schema(s) for --json output, optionally for one command.",
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
      kazi apply <goal-file> --workspace <path> --json [--stream]
      kazi apply <goal-file> --workspace <path> --parallel [N] [--json] # parallel scheduler
      kazi apply <goal-file> --workspace <path> --explain [--json]      # print the schedule, run nothing
      kazi status <ref> [--json]
      kazi init <repo-dir> [--out <file>] [--enrich]
      kazi install-skill [--dir <path>]           # write the Claude Code skill (opt-in)
      kazi plan "<idea>" [--workspace <path>] [--yes] [--strict] [--adr] [--json]
      kazi plan --json [--predicates <json>]      # caller-drafts (predicates supplied)
      kazi list-proposed [--status <proposed|approved|rejected>] [--json]
      kazi approve <proposal-ref> [--json]
      kazi reject <proposal-ref> [--json]
      kazi export <goal-file> --obsidian <dir> [--json]   # write an Obsidian vault
      kazi lint <goal-file> [--json]              # advisory near-duplicate group-name warnings
      kazi help [--json]                          # --json: the command/flag surface
      kazi schema [<command>]                      # the versioned --json result schema(s)

      # `kazi run` and `kazi propose` are DEPRECATED ALIASES of `apply` and `plan`
      # (ADR-0032): they still work but print a one-line deprecation hint to stderr.

  ARGUMENTS:
      <goal-file>            Path to a TOML goal-file (see Kazi.Goal.Loader).
      <repo-dir>             A repo root to adopt — kazi detects the stack and
                             writes a starter goal-file (T5.5, UC-023, ADR-0013).
      <idea>                 A prose idea to draft into a goal of acceptance
                             predicates (T3.5a, UC-017).
      <proposal-ref>         A proposal's review handle (printed by `propose`).
      <ref>                  `status` only: a run's goal id (recorded iterations)
                             or a proposal-ref to report the current state of.

  OPTIONS:
      --workspace <path>     Target workspace where edits/integrate/deploy run
                             (or, for `propose`, where the harness drafts the
                             goal). Falls back to the goal-file's [scope]
                             workspace.
      --out <path>           `init` output goal-file (default
                             <repo>/kazi.goal.toml).
      --dir <path>           `install-skill` only: target skill directory
                             (default ~/.claude/skills/kazi). Opt-in,
                             consent-first — a normal `kazi` run never writes to
                             ~/.claude (ADR-0024). Injected to a tmp dir in tests.
      --enrich               `init` only: opt into harness enrichment (OFF by
                             default) to propose live predicates from discovered
                             endpoints. The deterministic detection always stands.
      --env <name>           Deploy environment to target, e.g. staging / prod
                             (T3.3d). Selects the goal/deploy's per-env target;
                             requires the goal-file's deploy config to define an
                             `envs` map for that environment.
      --standing             Run as a STANDING (continuous/maintenance)
                             reconciler (UC-016): instead of converging and
                             stopping, hold the goal's predicates true forever,
                             re-converging whenever one drifts. Overrides the
                             goal-file's `standing` field.
      --status <state>       Filter `list-proposed` to one lifecycle state
                             (proposed / approved / rejected). Default: all.
      --yes                  `propose` only: skip the interactive clarify
                             questions and draft best-effort (also implied when
                             no TTY is attached, e.g. piped/CI).
      --strict               `propose` only: when run non-interactively, refuse an
                             underspecified idea (exit non-zero) instead of
                             guessing. Interactively, the clarify questions resolve
                             it.
      --adr                  `propose` only: additionally write an ADR-lite
                             rationale doc under docs/adr/ for the drafted goal.
      --predicates <json>    `propose` only (caller-drafts, ADR-0023): a proposal
                             payload — {"name","predicates":[...],"rationale"} —
                             the CALLER already authored. kazi spawns NO model:
                             it applies the deterministic clarify floor (flags a
                             missing live-verification target + scope), persists,
                             and gates approval. Alternatively supply it on stdin
                             under --json. The orchestrator's drive mode.
      --json                 Emit a single JSON object to stdout instead of human
                             prose (the machine surface, ADR-0023). Implies
                             NON-INTERACTIVE: kazi never prompts/blocks on stdin
                             under --json; a command that would need interactive
                             input errors loudly (JSON error + non-zero exit).
                             Human output is the default.
      --stream               `run --json` only: emit a JSONL progress stream — one
                             JSON event per loop iteration on stdout, terminated by
                             the final run-result object — so an orchestrator
                             monitors a long convergence without blocking (T15.4).
      --parallel [N]         `run` only (T21.8, ADR-0027): drive the PARALLEL
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
      --explain              `run` only (T23.6, ADR-0028): PRINT the computed wave
      --dry-run              SCHEDULE and exit 0 WITHOUT EXECUTING. kazi computes
                             the topological `needs`-DAG frontiers (each frontier =
                             the groups whose every `needs` dep is satisfied by the
                             prior frontiers) and, within each frontier, the
                             blast-radius PARTITIONING (the parallelism), then prints
                             them and dispatches NOTHING — so over-constraint (too
                             many `needs` edges serializing everything) is VISIBLE
                             before a run. A goal with NO `needs` shows ONE frontier
                             (everything parallel); a chain shows N frontiers. Pure
                             planning: no reconciler/harness/lease is touched. Under
                             --json the schedule is emitted as a JSON object;
                             NON-INTERACTIVE. `--dry-run` is an alias of `--explain`.
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
                             `dgx/qwen3.6` for opencode. Overrides the goal-file's
                             [harness] model.
      --help, -h             Show this help and exit.
      --version, -v          Print the kazi version and exit.

  EXAMPLES:
      kazi run priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target
      kazi run priv/examples/deploy_target.toml --workspace ./target --env prod
      kazi run priv/examples/standing_maintenance.toml --workspace ./svc --standing
      kazi run my.goal.toml --workspace ./svc --harness opencode --model dgx/qwen3.6
      kazi init ./my-service --out my-service.goal.toml
      kazi install-skill
      kazi run my.goal.toml --workspace ./svc --json --stream
      kazi status cli-e2e --json
      kazi propose "a /healthz endpoint that returns 200"
      kazi list-proposed --status proposed
      kazi approve prop-a-healthz-endpoint-3f9c1a2b4d5e
      kazi export priv/examples/grouped_taxonomy.toml --obsidian ./vault
      kazi lint priv/examples/grouped_taxonomy.toml
  """

  @doc """
  Escript entry point. Parses `argv`, runs, and halts the VM with the resulting
  exit code (`0` converged, non-zero otherwise / on error).
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  @doc """
  The testable core: parse `argv`, execute the command, print a human-readable
  result, and return the exit code (without halting). `IO` is used directly so
  tests can capture stdout via `ExUnit.CaptureIO`.

  `inject_opts` are extra options the CLI threads into its underlying API for the
  `run` and `propose` commands. Production callers (the escript `main/1` and
  `mix kazi.run`) pass none; the Tier-2 boundary tests use them to point the
  existing injectable seams at local stubs — exactly as `Kazi.RuntimeTest` /
  `Kazi.AuthoringTest` do — without the CLI ever naming a concrete harness/action:

    * for `run`, merged into `Kazi.Runtime.run/2` (`:adapter_opts`, `:integrator`,
      `:deploy_cmd`, `:deploy_params`, …).
    * for `propose`, merged into `Kazi.Authoring.propose/2` (`:harness`,
      `:adapter_opts`), so the e2e test drafts via a stub harness with no real
      `claude`.

  Returns `0` on success (convergence / a recorded proposal / approval), a
  non-zero code on a stopped loop, a load/usage error, or an internal failure.
  """
  @spec run([String.t()], keyword()) :: exit_code()
  def run(argv, inject_opts \\ []) when is_list(argv) and is_list(inject_opts) do
    case parse(argv) do
      {:help, flags} ->
        # T16.1 (ADR-0024 decision 2): under --json emit the command/flag surface
        # GENERATED from the command table (so any agent can introspect kazi at
        # runtime); the human usage prose otherwise (the default).
        emit(json?(flags), help_json(), fn -> IO.puts(@usage) end)
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
        emit(json?(flags), %{kazi: version(), schema_version: 1}, fn ->
          IO.puts("kazi #{version()}")
        end)

        0

      {:run, goal_file, opts} ->
        # T27.1 (ADR-0032): if the deprecated `run` alias was used, print a one-line
        # hint to STDERR (never stdout) BEFORE executing, so the --json stdout
        # contract (T15.7) stays JSON-only.
        maybe_deprecation_hint(opts[:deprecated])
        execute_run(goal_file, opts, inject_opts)

      {:status, ref, opts} ->
        execute_status(ref, opts)

      {:init, source, opts} ->
        execute_init(source, opts, inject_opts)

      {:install_skill, opts} ->
        execute_install_skill(opts, inject_opts)

      {:propose, idea, opts} ->
        # T27.1 (ADR-0032): the deprecated `propose` alias prints a one-line stderr
        # hint before executing; never into --json stdout.
        maybe_deprecation_hint(opts[:deprecated])
        execute_propose(idea, opts, inject_opts)

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
          | {:status, String.t(), keyword()}
          | {:init, Path.t(), keyword()}
          | {:install_skill, keyword()}
          | {:propose, String.t(), keyword()}
          | {:list_proposed, keyword()}
          | {:approve, String.t(), keyword()}
          | {:reject, String.t(), keyword()}
          | {:export, Path.t(), keyword()}
          | {:lint, Path.t(), keyword()}
          | {:error, String.t()}

  @doc """
  Parses `argv` into a command. Exposed for unit testing the argument boundary.

  Returns one of:

    * `{:help, opts}` — `--help` was requested.
    * `{:run, goal_file, opts}` — the `run` subcommand with its positional
      goal-file and `opts`
      (`[workspace: path | nil, env: name | nil, standing: boolean | nil]`).
      `:env` is the T3.3d deploy-environment selector. `:standing` is `nil` when
      `--standing` was not given (the goal-file's own `standing` field then
      decides); `true` forces standing mode (T3.4d).
    * `{:propose, idea, opts}` — the `propose` subcommand (T3.5c) with its
      positional prose idea and `opts` (`[workspace: path | nil]`).
    * `{:list_proposed, opts}` — the `list-proposed` subcommand with `opts`
      (`[status: state | nil]`, an optional lifecycle-state filter).
    * `{:approve, proposal_ref, opts}` / `{:reject, proposal_ref, opts}` — the
      approval transitions over a proposal's review handle (T3.5b); `opts` carries
      `[json: boolean]` (T15.6, ADR-0023 decision 2).
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

  # T27.1 (ADR-0032): `apply` is the PRIMARY verb; `run` is the DEPRECATED ALIAS.
  # Both parse to the SAME `{:run, ...}` tuple (so the handler/dispatch is shared);
  # the alias carries `deprecated: "run"` so `run/2` emits a one-line stderr hint
  # (never into --json stdout). `apply` carries no `:deprecated`, so it is silent.
  defp parse_command(["apply", goal_file | rest], flags),
    do: parse_run(goal_file, rest, flags, nil)

  defp parse_command(["apply"], _flags),
    do: {:error, "the `apply` command requires a <goal-file> argument"}

  defp parse_command(["run", goal_file | rest], flags),
    do: parse_run(goal_file, rest, flags, "run")

  defp parse_command(["run"], _flags),
    do: {:error, "the `run` command requires a <goal-file> argument"}

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

  defp parse_command(["status"], _flags),
    do: {:error, "the `status` command requires a <ref> argument (a goal or proposal ref)"}

  # T5.5 adopt: `kazi init <repo-dir>` reverse-engineers a starter goal-file by
  # deterministic stack detection (ADR-0013). --out is the output file; --enrich
  # opts into harness enrichment (off by default).
  defp parse_command(["init", repo_dir | rest], flags) do
    case rest do
      [] ->
        {:init, repo_dir, out: flags[:out], enrich: flags[:enrich], workspace: flags[:workspace]}

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["init"], _flags),
    do: {:error, "the `init` command requires a <repo-dir> argument"}

  # T16.2 (ADR-0024 decision 1): `kazi install-skill` writes the kazi Claude Code
  # skill so an orchestrating agent already knows the propose → approve → run
  # recipe. OPT-IN/consent-first — only this explicit command writes, and only
  # under `--dir` (a tmp dir in tests) or the default ~/.claude/skills/kazi. A
  # normal `kazi` run never touches ~/.claude.
  defp parse_command(["install-skill" | rest], flags) do
    case rest do
      [] -> {:install_skill, dir: flags[:dir]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T3.5c authoring: `propose "<idea>"` drafts a goal from a prose idea. The idea
  # is a single positional argument (quote it in the shell); only --workspace is
  # carried through (where the harness drafts the goal).
  # T15.2 (ADR-0023 decision 4): in caller-drafts mode the predicates are supplied
  # (--predicates / stdin) so the positional idea is OPTIONAL — `kazi propose
  # --json` with predicates and no idea is the orchestrator's entry point.
  # T27.1 (ADR-0032): `plan` is the PRIMARY verb; `propose` is the DEPRECATED ALIAS.
  # Both parse to the SAME `{:propose, ...}` tuple; the alias threads
  # `deprecated: "propose"` into `propose_opts` so the dispatcher emits a one-line
  # stderr hint (never into --json stdout). `plan` carries no `:deprecated`.
  defp parse_command(["plan" | rest], flags), do: parse_propose(rest, flags, nil)
  defp parse_command(["propose" | rest], flags), do: parse_propose(rest, flags, "propose")

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

  defp parse_command([other | _], _flags),
    do:
      {:error,
       "unknown command #{inspect(other)} (try `apply`, `status`, `init`, `install-skill`, `plan`, `list-proposed`, `approve`, `reject`, `export`, `lint`, `schema`, or `help`)"}

  defp parse_command([], _flags),
    do: {:error, "no command given (expected `apply <goal-file> --workspace <path>`)"}

  defp approval_command(command, proposal_ref, [], flags),
    do: {command, proposal_ref, json: flags[:json] || false}

  defp approval_command(_command, _proposal_ref, extra, _flags),
    do: {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}

  # T27.1 (ADR-0032): shared `apply`/`run` parse body. `deprecated` is `nil` for the
  # primary verb (`apply`) or the old verb name (`"run"`) for the deprecated alias,
  # threaded into the parsed `{:run, ...}` opts so the dispatcher can emit the
  # one-line stderr hint. Both verbs reuse the SAME tuple/handler.
  defp parse_run(goal_file, rest, flags, deprecated) do
    case rest do
      # T3.3d deploy wiring: carry the optional --env selector alongside workspace.
      # T3.4d standing wiring: carry the --standing flag through to the run.
      # T8.7 harness wiring: carry --harness/--model through to the resolved adapter.
      [] ->
        {
          :run,
          goal_file,
          # T15.3 (ADR-0023 decision 2): --json switches `run` to its machine
          # surface — the versioned result contract instead of the human report.
          # T15.4 (ADR-0023 decision 3): --stream emits the JSONL progress stream
          # (one event per iteration) before the final run-result object. Only
          # meaningful under --json.
          # T21.8 (ADR-0027): --parallel routes `run` to the parallel scheduler;
          # the optional --parallel N records a concurrency hint (:parallelism).
          # T23.6 (ADR-0028): --explain / --dry-run is the PURE PLANNING surface —
          # print the computed wave schedule and dispatch NOTHING. The two spellings
          # are aliases; either sets :explain so the surface is one branch.
          workspace: flags[:workspace],
          env: flags[:env],
          standing: flags[:standing],
          harness: flags[:harness],
          model: flags[:model],
          json: flags[:json] || false,
          stream: flags[:stream] || false,
          parallel: flags[:parallel] || false,
          parallelism: flags[:parallelism],
          explain: flags[:explain] || flags[:dry_run] || false,
          deprecated: deprecated
        }

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T27.1 (ADR-0032): shared `plan`/`propose` parse body. `deprecated` is `nil`
  # (primary `plan`) or the old verb name (`"propose"`) for the deprecated alias.
  # T15.2: with no positional idea, only caller-drafts mode is valid (predicates
  # supplied via --predicates / stdin under --json); otherwise the missing-idea
  # usage error stands, so the existing human surface is unchanged.
  defp parse_propose([idea | rest], flags, deprecated) do
    case rest do
      [] -> {:propose, idea, propose_opts(flags, deprecated)}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_propose([], flags, deprecated) do
    if flags[:predicates] || flags[:json] do
      {:propose, "", propose_opts(flags, deprecated)}
    else
      {:error, "the `plan` command requires an <idea> argument (quote it)"}
    end
  end

  # The shared option bundle for the `plan`/`propose` subcommand (both modes).
  # T15.2: `:predicates` carries the caller-drafts payload; `:json` switches the
  # surface. T27.1 (ADR-0032): `:deprecated` is the old verb name (`"propose"`) when
  # the deprecated alias was used, so the dispatcher emits a one-line stderr hint;
  # `nil` for the primary `plan`.
  defp propose_opts(flags, deprecated) do
    [
      workspace: flags[:workspace],
      yes: flags[:yes] || false,
      strict: flags[:strict] || false,
      adr: flags[:adr] || false,
      json: flags[:json] || false,
      predicates: flags[:predicates],
      deprecated: deprecated
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

  # The render seam: under `--json` print exactly `Jason.encode!(payload)` and a
  # newline (a single JSON object, no human prose interleaved on stdout);
  # otherwise run `human_fun`, the command's existing human rendering. Returns
  # `:ok`; the caller owns the exit code.
  @spec emit(boolean(), map(), (-> any())) :: :ok
  defp emit(true, payload, _human_fun) when is_map(payload) do
    IO.puts(Jason.encode!(payload))
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
    IO.puts(Jason.encode!(%{error: message, schema_version: 1}))
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn {opt, _value} -> opt end)
  end

  # T27.1 (ADR-0032): the deprecated-alias hint. When a deprecated verb
  # (`run` → `apply`, `propose` → `plan`) was used, print ONE line to STDERR
  # pointing at the primary verb. It is STDERR-ONLY by construction, so it never
  # leaks into `--json` stdout (the JSON contract / self-conformance T15.7 stays
  # JSON-only on stdout regardless of which alias was typed). `nil` (the primary
  # verb) prints nothing.
  @deprecated_primary %{"run" => "apply", "propose" => "plan"}

  @spec maybe_deprecation_hint(String.t() | nil) :: :ok
  defp maybe_deprecation_hint(nil), do: :ok

  defp maybe_deprecation_hint(verb) when is_binary(verb) do
    primary = Map.get(@deprecated_primary, verb, verb)
    IO.puts(:stderr, "note: `kazi #{verb}` is deprecated; use `kazi #{primary}`")
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

  defp command_json(command) do
    %{
      name: command.name,
      summary: command.summary,
      args: Enum.map(command.args, &arg_json/1),
      flags: Enum.map(command.flags, &command_flag_json/1)
    }
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
    IO.puts(Jason.encode!(Kazi.CLI.Schema.all()))
    0
  end

  defp execute_schema(command) do
    case Kazi.CLI.Schema.fetch(command) do
      {:ok, schema} ->
        IO.puts(Jason.encode!(schema))
        0

      :error ->
        emit_json_error(
          "no result schema for #{inspect(command)} " <>
            "(schemas exist for: #{Enum.join(Kazi.CLI.Schema.commands(), ", ")})"
        )

        1
    end
  end

  # =============================================================================
  # run command
  # =============================================================================

  # Boot the app + read-model, load the goal, run it, report. Returns the exit
  # code (never halts) so it stays testable.
  defp execute_run(goal_file, opts, runtime_opts) do
    persist? = ensure_read_model()

    case Goal.Loader.load(goal_file) do
      {:ok, goal} ->
        run_goal(goal, opts, persist?, runtime_opts)

      {:error, reason} ->
        IO.puts(:stderr, "error: could not load goal-file #{goal_file}: #{reason}")
        1
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
      # T23.6 (ADR-0028): --explain / --dry-run is PURE PLANNING — compute and print
      # the wave schedule, dispatch NOTHING, exit 0. Checked FIRST so it never falls
      # through to a real serial/parallel run (the spy seam asserts no reconciler is
      # invoked). It runs before any execution branch regardless of --parallel.
      opts[:explain] == true ->
        explain_schedule(goal, opts, runtime_opts)

      opts[:parallel] == true ->
        run_goal_parallel(goal, opts, persist?, runtime_opts)

      true ->
        run_goal_serial(goal, opts, persist?, runtime_opts)
    end
  end

  defp run_goal_serial(%Goal{} = goal, opts, persist?, runtime_opts) do
    workspace = opts[:workspace] || goal.scope.workspace

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
      # T3.3d deploy wiring: fold the operator's --env selection into the deploy
      # action's params, so the deepened deploy (T3.3a) selects that environment's
      # per-env target. Merged OVER any caller-supplied :deploy_params so tests
      # passing their own deploy_params keep working and an explicit --env wins.
      |> maybe_put_deploy_env(opts[:env])
      |> maybe_put_standing(opts[:standing])
      # T8.7 harness wiring: forward --harness/--model to Kazi.Runtime, which
      # resolves the adapter (Kazi.Harness.resolve/1). Only set when given, so the
      # default path (no flags) stays byte-identical to the pre-T8.7 claude path.
      |> maybe_put(:harness, opts[:harness])
      |> maybe_put(:model, opts[:model])
      # T15.4 (ADR-0023 decision 3): under --json --stream, thread a per-iteration
      # streaming observer into the runtime's `:stream` seam, which composes it
      # OVER the read-model projection (one `on_iteration` fires both). It emits
      # one JSONL progress event per observation to stdout; the final run-result
      # object below TERMINATES the stream. Off (no `:stream`) unless both flags.
      |> maybe_put_stream(opts)

    json? = opts[:json] == true

    # T15.3 (ADR-0023 decision 2): map the loop's terminal result to the surface.
    # The loop's outcome/reason are reused verbatim — `:converged`, `:over_budget`,
    # and `:stopped` (which carries `reason: :stuck` for a stuck stop, T1.5) — and
    # rendered as the versioned JSON contract under --json or the human report
    # otherwise. The exit code is the same on both surfaces: 0 only on convergence.
    case Runtime.run(goal, run_opts) do
      {:ok, %{outcome: :converged} = result} ->
        report_outcome(goal, :converged, result, json?)
        0

      {:ok, %{outcome: :over_budget} = result} ->
        report_outcome(goal, :over_budget, result, json?)
        1

      {:ok, %{outcome: :stopped} = result} ->
        report_outcome(goal, :stopped, result, json?)
        1

      {:error, reason} ->
        report_run_error(goal, reason, json?)
        1
    end
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

    case Kazi.Scheduler.run_goals([goal], scheduler_opts) do
      {:ok, result} ->
        report_collective(goal, result, json?)
        collective_exit_code(result)

      {:error, reason} ->
        report_run_error(goal, reason, json?)
        1
    end
  end

  # The per-goal loop opts the default scheduler reconciler forwards to
  # `Kazi.Runtime.run/2`: persistence + any --harness/--model overrides, mirroring
  # the serial path so a single-partition parallel run behaves like the serial run.
  defp default_parallel_run_opts(opts, persist?) do
    [persist?: persist?]
    |> maybe_put(:harness, opts[:harness])
    |> maybe_put(:model, opts[:model])
  end

  # Merge the CLI-owned per-goal opts OVER any caller-supplied `:run_opts` (tests),
  # so an explicit injected `:run_opts` keeps its keys while persistence/harness are
  # still threaded.
  defp merge_parallel_run_opts(injected, opts, persist?) when is_list(injected) do
    injected
    |> Keyword.put_new(:persist?, persist?)
    |> maybe_put(:harness, opts[:harness])
    |> maybe_put(:model, opts[:model])
  end

  # The collective run's exit code: 0 only when the whole goal-set collectively
  # converged, non-zero otherwise — the same convergence-mirrors-exit contract the
  # serial run honors (concept §1, §5).
  defp collective_exit_code(%{collective: :converged}), do: 0
  defp collective_exit_code(_result), do: 1

  # Render the loop's terminal result on the requested surface (T15.3): the
  # versioned JSON result object under --json, the existing human report
  # otherwise. Both share the SAME loop result; only the OUTPUT shape differs.
  defp report_outcome(%Goal{} = goal, outcome, result, json?) do
    emit(json?, run_result_json(goal, outcome, result), fn ->
      report(goal, human_outcome(outcome), result)
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
      IO.puts(Jason.encode!(run_error_json(goal, reason, message)))
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

  # Set a run opt only when the value is present (a CLI flag was given). Keeping
  # absent flags unset means the default path is byte-identical to pre-T8.7.
  defp maybe_put(run_opts, _key, nil), do: run_opts
  defp maybe_put(run_opts, key, value), do: Keyword.put(run_opts, key, value)

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
    event = %{
      schema_version: @run_schema_version,
      event: "iteration",
      iteration: Map.get(payload, :iteration),
      predicates: predicate_vector_json(Map.get(payload, :vector)),
      converged: Map.get(payload, :converged?) == true,
      release_ref: Map.get(payload, :release_ref)
    }

    IO.puts(Jason.encode!(event))
  end

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
  defp execute_status(ref, opts) do
    with_read_model(fn ->
      cond do
        (iteration = ReadModel.latest_iteration(ref)) != nil ->
          report_run_status(ref, iteration, opts)

        (proposal = ReadModel.get_proposed_goal(ref)) != nil ->
          report_proposal_status(proposal, opts)

        true ->
          status_not_found(ref, opts)
      end
    end)
  end

  # Report a RUN's current state from its latest recorded iteration (T15.5): a
  # JSON object under --json, a human block otherwise.
  defp report_run_status(ref, iteration, opts) do
    vector = ReadModel.to_predicate_vector(iteration)

    emit(json?(opts), run_status_json(ref, iteration, vector), fn ->
      IO.puts("STATUS     ref=#{ref} kind=run")
      IO.puts("converged: #{iteration.converged}")
      IO.puts("iteration: #{iteration.iteration_index}")
      maybe_status_release(iteration.release_ref)
      IO.puts("observed:  #{iteration.observed_at}")
      IO.puts("\npredicate vector:")
      IO.puts(format_vector(vector))
    end)

    0
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
  defp run_status_json(ref, iteration, vector) do
    %{
      schema_version: @run_schema_version,
      kind: "run",
      ref: to_string(ref),
      status: if(iteration.converged, do: "converged", else: "in_progress"),
      converged: iteration.converged,
      iteration: iteration.iteration_index,
      predicates: predicate_vector_json(vector),
      release_ref: iteration.release_ref,
      observed_at: status_timestamp(iteration.observed_at)
    }
  end

  # The `status --json` result object for a PROPOSAL (T15.5): its lifecycle state,
  # idea, and goal id. `kind: "proposal"` distinguishes it from a run status.
  defp proposal_status_json(proposal) do
    %{
      schema_version: @run_schema_version,
      kind: "proposal",
      ref: proposal.proposal_ref,
      status: proposal.status,
      goal_id: proposal.goal_id,
      idea: proposal.idea
    }
  end

  defp status_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp status_timestamp(other), do: other

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
        write_goal_file(out, Adopt.to_toml(goal_map))

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
  defp stack_goal_map(repo_dir, adoption, opts) do
    guards = Adopt.guards(adoption, file_reader: File, path: repo_dir)
    proposed = Map.get(adoption, :proposed, [])
    base = repo_dir |> Path.expand() |> Path.basename()
    id = if base in ["", ".", "/"], do: "adopted", else: "adopt-#{base}"

    %{
      "id" => id,
      "name" => "Adopted baseline for #{base}",
      "scope" => %{"workspace" => opts[:workspace] || repo_dir},
      "predicate" => [adoption.predicate | guards] ++ proposed
    }
  end

  # Write a single goal-file (stack mode) and print the path + review hint.
  defp write_goal_file(out, toml) do
    dir = Path.dirname(out)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(out, toml) do
      IO.puts("WROTE  #{out}")
      IO.puts("\nReview the live-predicate TODO in the goal-file, then run:")
      IO.puts("  kazi run #{out} --workspace <path>")
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
  # agent already knows the propose → approve → run recipe (the two-tier
  # economics + branching on `next_action`). It is OPT-IN/consent-first: only this
  # explicit command writes, and a normal `kazi` run never touches ~/.claude
  # (`brew install` only PRINTS a hint to run it — the tap formula's `caveats`).
  #
  # The target dir is INJECTABLE so tests never write to the real ~/.claude:
  # `--dir <path>` wins, else `inject_opts[:skill_dir]` (the same seam pattern as
  # the other commands), else the default `~/.claude/skills/kazi`.
  defp execute_install_skill(opts, inject_opts) do
    write_opts = install_skill_opts(opts, inject_opts)

    case InstallSkill.write(write_opts) do
      {:ok, path} ->
        IO.puts("WROTE  #{path}")
        IO.puts("\nThe kazi skill is installed. In Claude Code, it teaches the recipe:")
        IO.puts("  propose --json → approve --json → run --harness <cheap> --json [--stream]")
        IO.puts("then branch on the result's next_action.")
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

  defp execute_lint(goal_file, opts) do
    case Goal.Loader.load(goal_file) do
      {:ok, goal} ->
        report_lint(goal, GroupLint.warnings(goal), opts)
        # ADVISORY: exit 0 whether or not warnings were emitted — the second net
        # never fails a goal that loads (ADR-0020 §Decision 3).
        0

      {:error, reason} ->
        # A genuine load failure (not a lint finding) is a real error: a JSON
        # envelope under --json, a human stderr line otherwise. Exit non-zero.
        lint_load_error(goal_file, reason, opts)
    end
  end

  # Render the lint result on the requested surface: under --json a single object
  # carrying the warning LIST (empty when clean); the human report otherwise. BOTH
  # share the same `GroupLint.warnings/1`; only the OUTPUT shape differs.
  defp report_lint(%Goal{} = goal, warnings, opts) do
    emit(json?(opts), lint_json(goal, warnings), fn -> report_lint_human(goal, warnings) end)
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

  # The `lint --json` result: the warning LIST (each naming both groups + the
  # similarity), the count, and `schema_version`. An empty list = no near-duplicate
  # (advisory clean); the exit code is 0 regardless (ADR-0020 §Decision 3).
  defp lint_json(%Goal{} = goal, warnings) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(goal.id),
      count: length(warnings),
      warnings: Enum.map(warnings, &lint_warning_json/1)
    }
  end

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
    with_read_model(fn ->
      case caller_proposal(opts, inject_opts) do
        {:ok, payload} -> caller_drafts(idea, payload, opts, inject_opts)
        :none -> kazi_drafts(idea, opts, inject_opts)
        {:error, message} -> propose_input_error(message, opts)
      end
    end)
  end

  # The kazi-drafts path (the existing one): drive the harness to draft predicates
  # from the prose idea, after the interactive/floor gating.
  defp kazi_drafts(idea, opts, inject_opts) do
    base =
      inject_opts
      |> Keyword.take([:harness, :adapter_opts])
      |> Keyword.put(:workspace, opts[:workspace] || ".")

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
  # the queue as a list an orchestrator drives propose → approve → run on — the
  # human table otherwise.
  defp execute_list_proposed(opts) do
    with_read_model(fn ->
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
  # the goal is now runnable by `kazi run`. T15.6: under --json the transition
  # reports a machine-readable success object (or a JSON error on the same stdout
  # surface), the human lines otherwise.
  defp execute_approve(proposal_ref, opts) do
    with_read_model(fn ->
      case Authoring.approve(proposal_ref) do
        {:ok, %Goal{} = goal} ->
          emit(json?(opts), approval_json("approved", proposal_ref, goal.id), fn ->
            IO.puts("APPROVED   proposal=#{proposal_ref} goal=#{goal.id}")
            IO.puts("The goal is now runnable: kazi run <goal-file> --workspace <path>")
          end)

          0

        {:error, reason} ->
          transition_error("approve", proposal_ref, reason, opts)
      end
    end)
  end

  # `reject <proposal-ref> [--json]`: transition proposed → rejected (declined,
  # audited). T15.6: same JSON/human split as approve.
  defp execute_reject(proposal_ref, opts) do
    with_read_model(fn ->
      case Authoring.reject(proposal_ref) do
        {:ok, draft} ->
          emit(json?(opts), approval_json("rejected", proposal_ref, draft.goal.id), fn ->
            IO.puts("REJECTED   proposal=#{proposal_ref}")
          end)

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
  defp with_read_model(fun) do
    if ensure_read_model() do
      fun.()
    else
      IO.puts(:stderr, "error: the read-model is unavailable; authoring requires persistence")
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
    IO.puts("\nReview, then: kazi approve #{draft.proposal_ref}")
  end

  # =============================================================================
  # propose --json result schema (T15.2, ADR-0023 decision 2)
  # =============================================================================
  #
  # The single JSON object `propose --json` emits: the draft a caller approves on.
  # It carries the goal id, the proposal_ref (the approve/reject handle), the
  # acceptance predicates, the optional rationale, and the deterministic clarify
  # FLOOR (`Clarify.gaps/2`) computed OVER the draft — so a missing
  # live-verification target + scope is FLAGGED even when nothing was asked
  # interactively. The floor applies in BOTH drive modes (kazi-drafts and
  # caller-drafts) because both produce the same `Kazi.Authoring.Draft` here.
  defp proposed_json(draft) do
    %{
      schema_version: 1,
      goal_id: to_string(draft.goal.id),
      proposal_ref: draft.proposal_ref,
      status: to_string(draft.status),
      idea: draft.idea,
      predicates: Enum.map(Goal.all_predicates(draft.goal), &predicate_json/1),
      rationale: rationale_text(draft.goal),
      clarify: clarify_json(draft)
    }
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
  # The structured JSON an orchestrator drives the propose → approve → run state
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
  # and pipes the goal id into the next step.
  defp approval_json(status, proposal_ref, goal_id) do
    %{
      schema_version: @run_schema_version,
      proposal_ref: proposal_ref,
      status: status,
      goal_id: to_string(goal_id)
    }
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
    do: "the stored goal no longer loads: #{inspect(reason)}"

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

  defp migrate_read_model do
    repo = Kazi.Repo

    try do
      if started?(repo) do
        # Mix-task path: the supervision tree already started the repo (and its
        # SQLite connection creates the file on connect). Opening a *second*,
        # transient connection here to `storage_up` races the supervised pool and
        # SQLite's single writer ("database is locked"); instead just run pending
        # migrations against the live, already-connected repo.
        _ = Ecto.Migrator.run(repo, :up, all: true)
        :ok
      else
        # Escript / bare path: no supervised repo. Create the SQLite file if absent
        # (no-op if it exists), then start the repo only for the migration. With no
        # competing pool there is no lock contention.
        _ = repo.__adapter__().storage_up(repo.config())

        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn r ->
            Ecto.Migrator.run(r, :up, all: true)
          end)

        :ok
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp started?(repo) do
    is_pid(Process.whereis(repo)) or is_pid(GenServer.whereis(repo))
  end

  # =============================================================================
  # outcome reporting
  # =============================================================================

  defp report(%Goal{} = goal, outcome, result) do
    IO.puts(outcome_line(goal, outcome, result))
    IO.puts("iterations: #{result.iterations}")
    IO.puts("actions:    #{format_actions(result.actions)}")
    # T3.3d deploy wiring: surface the release ref of the artifact deployed this
    # run (T3.3c tagging) so the operator sees WHAT was shipped, not just the
    # outcome. Omitted when nothing was deployed (no release ref).
    maybe_report_release(result)
    IO.puts("\npredicate vector:")
    IO.puts(format_vector(result.vector))
  end

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
  # The single, VERSIONED JSON object `kazi run --json` emits on termination. It
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
  #   * `schema_version` — the contract version (`@run_schema_version`); a breaking
  #                        change bumps it.
  @spec run_result_json(Goal.t(), :converged | :stopped | :over_budget, map()) :: map()
  defp run_result_json(%Goal{id: id}, outcome, result) do
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
      release_ref: Map.get(result, :release_ref)
    }
  end

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
  defp next_action(_), do: "investigate"

  # The predicate vector as a list of `{id, verdict}` objects, sorted by id for a
  # stable, diffable order. An absent/empty vector renders as `[]`.
  @spec predicate_vector_json(Kazi.PredicateVector.t() | nil) :: [map()]
  defp predicate_vector_json(nil), do: []

  defp predicate_vector_json(%Kazi.PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map(fn {id, result} ->
      %{id: to_string(id), verdict: to_string(result.status)}
    end)
  end

  # What the run consumed. `iterations` always; `exceeded` names the budget
  # dimension only when the stop was over-budget, else nil (a clean converge or a
  # stuck stop did not exceed a budget dimension).
  defp budget_spent_json(result) do
    %{
      iterations: result.iterations,
      exceeded: budget_exceeded(result)
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

    partitions
    |> Enum.with_index()
    |> Enum.each(fn {{partition, status}, index} ->
      IO.puts("  [#{index}] #{partition_id(partition, index)}: #{status}")
    end)
  end

  defp report_collective_human(%Goal{id: id} = goal, %{groups: groups} = result) do
    schedule = schedule_view(goal, groups)

    IO.puts("COLLECTIVE #{result.collective |> to_string() |> String.upcase()}  goal=#{id}")
    IO.puts("frontiers: #{length(schedule)}")
    print_schedule_frontiers(schedule)
    print_blocked_human(Map.get(result, :blocked, []))
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
      partitions: partitions_json(partitions),
      next_action: next_action(collective_str)
    }
  end

  defp collective_result_json(%Goal{id: id} = goal, %{groups: groups} = result) do
    collective_str = to_string(result.collective)
    blocked = Map.get(result, :blocked, [])

    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      collective: collective_str,
      schedule: schedule_json(goal, groups),
      blocked: blocked_json(blocked),
      next_action: next_action(collective_str)
    }
  end

  defp partitions_json(partitions) do
    partitions
    |> Enum.with_index()
    |> Enum.map(fn {{partition, status}, index} ->
      %{
        partition_id: partition_id(partition, index),
        goal_ids: partition_goal_ids(partition),
        status: to_string(status)
      }
    end)
  end

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

  # The topological FRONTIERS of a goal's `needs`-DAG: a PURE layering that mirrors
  # the scheduler's planner (`Kazi.Goal.DepGraph`). Repeatedly take the READY SET
  # (groups whose every `needs` dep is satisfied by earlier frontiers), emit it as a
  # frontier, then mark those groups converged and recompute — exactly the order the
  # pipelined `DepScheduler` WOULD take (we mirror it; we do not call it). A goal with
  # NO `needs` yields ONE frontier (every group ready at once — fully parallel); a
  # chain yields N frontiers (one group per wave). Groups that can never become ready
  # (none, for a valid load-time DAG) are excluded — the `needs` graph is a validated
  # DAG (T23.1), so the layering terminates and covers every group.
  #
  # Returns a list of frontiers, each a list of group ids in DECLARED order.
  @spec frontiers(Goal.t()) :: [[Group.id()]]
  defp frontiers(%Goal{groups: []}), do: []

  defp frontiers(%Goal{} = goal) do
    layer_frontiers(goal, %{}, [])
  end

  defp layer_frontiers(goal, states, acc) do
    ready = DepGraph.ready_set(goal, states)

    if ready == [] do
      Enum.reverse(acc)
    else
      # Mark this frontier's groups converged so the NEXT ready-set computation sees
      # their deps satisfied — the pure topological advance (no dispatch, no I/O).
      states = Enum.reduce(ready, states, fn id, acc -> Map.put(acc, id, :converged) end)
      layer_frontiers(goal, states, [ready | acc])
    end
  end

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

    emit(json?, explain_json(goal, schedule), fn ->
      explain_human(goal, schedule)
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
  defp explain_human(%Goal{id: id}, schedule) do
    IO.puts("SCHEDULE (dry-run, nothing dispatched)  goal=#{id}")
    IO.puts("frontiers: #{length(schedule)}")

    Enum.each(schedule, fn %{frontier: index, groups: groups, partitions: partitions} ->
      IO.puts("  frontier #{index}: #{Enum.join(groups, ", ")}")
      IO.puts("    parallelism: #{length(partitions)} partition(s)")

      partitions
      |> Enum.with_index()
      |> Enum.each(fn {partition, p_index} ->
        ids = Enum.join(partition.goal_ids, ", ")
        IO.puts("    [#{p_index}] #{partition_id(partition, p_index)}: #{ids}")
      end)
    end)
  end

  # The `--explain --json` object (T23.6): the computed schedule as a single JSON
  # object — the frontiers + the per-frontier partitioning — with `dispatched: false`
  # making the no-execution contract explicit and machine-checkable.
  defp explain_json(%Goal{id: id}, schedule) do
    %{
      schema_version: @run_schema_version,
      goal_id: to_string(id),
      mode: "explain",
      dispatched: false,
      frontiers: Enum.map(schedule, &explain_frontier_json/1),
      next_action: "schedule"
    }
  end

  defp explain_frontier_json(%{frontier: index, groups: groups, partitions: partitions}) do
    %{
      frontier: index,
      groups: Enum.map(groups, &to_string/1),
      partitions:
        partitions
        |> Enum.with_index()
        |> Enum.map(fn {partition, p_index} ->
          %{
            partition_id: partition_id(partition, p_index),
            goal_ids: Enum.map(partition.goal_ids, &to_string/1)
          }
        end)
    }
  end
end
