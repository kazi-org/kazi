defmodule Kazi.Goal.Loader do
  @moduledoc """
  Loads a goal from a TOML *goal-file* on disk and parses it into a
  `Kazi.Goal` struct (with its `Kazi.Predicate` list), faithful to the T0.3
  domain types (ADR-0002, concept §4). This is the on-disk authoring format the
  Slice 0 dogfood (T0.12) and the CLI (`kazi run <goal-file>`, T0.10) load.

  A goal-file is *declarative*: it names a goal, its budget/scope, and the
  predicates whose conjunction defines "done". The loader is the only place the
  string authoring format is translated into the in-memory domain; everything
  downstream (loop T0.7, providers T0.5/T0.5b, read-model T0.9) builds against
  the structs, never the TOML.

  ## Goal-file TOML schema

  Top level (the goal itself):

  | Key      | TOML type | Required | Maps to             |
  |----------|-----------|----------|---------------------|
  | `id`     | string    | yes      | `Goal.id`           |
  | `name`   | string    | no       | `Goal.name`         |
  | `mode`   | string    | no       | `Goal.mode` — `"repair"` (default) or `"create"` |
  | `standing` | boolean | no       | `Goal.standing` — `true` for a standing/maintenance goal (default `false`) |
  | `metadata` | table   | no       | `Goal.metadata` (string-keyed map, verbatim) |

  `mode = "create"` declares a *creation-mode* goal whose predicates are
  acceptance criteria for NEW behavior, authored to fail at t0 (T2.1, concept
  §10 Slice 2). It records authoring intent; it does not change how the loop
  evaluates predicates. An unknown `mode` is a validation error.

  `standing = true` declares a STANDING (continuous/maintenance) reconciler
  (T3.4d, UC-016): the loop does NOT terminate at convergence but keeps
  re-observing on a bounded interval to hold the predicates true forever
  (concept §10 "standing reconcilers"). Omitted (or `false`) is the default
  one-shot converge-and-stop goal. The standing-mode loop behaviour itself is
  T3.4a; this key is how a goal *authors* it. The CLI `--standing` flag
  (`kazi run … --standing`) overrides whatever the goal-file declares. A
  non-boolean `standing` is a validation error.

  ### `[budget]` table (optional, → `Kazi.Budget`)

  | Key                  | TOML type        | Maps to                  |
  |----------------------|------------------|--------------------------|
  | `max_iterations`     | positive integer | `Budget.max_iterations`  |
  | `max_wall_clock_ms`  | positive integer | `Budget.max_wall_clock_ms` |
  | `max_tokens`         | positive integer | `Budget.max_tokens`      |
  | `max_dispatches`     | positive integer | `Budget.max_dispatches`  |
  | `cached_read_weight` | float `0.0..1.0` | `Budget.cached_read_weight` |

  Omitted ceiling dimensions are unbounded (`nil`). `max_dispatches` (T48.6,
  ADR-0058) counts only `:dispatch_agent` actions — unlike `max_iterations`, a
  no-op observe tick never consumes it, so a run wedged on a persistently
  erroring predicate cannot trip `max_dispatches` by spinning observe ticks
  alone. `cached_read_weight` is not a ceiling: it is the fraction of a fresh
  token each cached-read input token counts as in the token budget (T34.4,
  ADR-0046) — cached reads are far cheaper than fresh input, so a cache-hit-heavy
  run is not falsely flagged `over_budget`. When omitted it defaults to
  `Budget.default_cached_read_weight/0`.

  ### `[scope]` table (optional, → `Kazi.Scope`)

  | Key           | TOML type        | Maps to               |
  |---------------|------------------|------------------------|
  | `workspace`   | string           | `Scope.workspace`     |
  | `repo`        | string           | `Scope.repo`          |
  | `paths`       | array of strings | `Scope.paths`         |
  | `write_paths` | array of strings | `Scope.write_paths` — issue #860: the EDITABLE subset of `paths` (distinct from the readable allow-list); absent/empty keeps today's `paths`-only behavior byte-identical. Used by `kazi apply --json`'s `collateral` field to flag out-of-write-scope changes. |
  | `deny`        | array of strings | `Scope.deny` — issue #860: protected paths that must NEVER be modified by this goal (entitlements, auth config, CI workflows). `Kazi.Scope.guard_predicates/1` synthesizes a `:scope_guard` GUARD predicate from it (independent of `[enforcement]`) that fails — with the offending paths as evidence — if a run changes anything under a `deny` path; absent/empty synthesizes no guard. |

  ### `[harness]` table (optional, → `Goal.harness`, T8.6/ADR-0016)

  Declares which coding harness this goal prefers to be driven by. Absent → the
  goal's `harness` stays `nil` (no goal-level preference; resolution falls
  through to config/default). Loaded as a `%{id:, model:, command:}` map.

  | Key              | TOML type        | Maps to              |
  |------------------|------------------|----------------------|
  | `id`             | string           | `harness.id` — a KNOWN harness id atom (`"claude"`, `"opencode"`, …); an unknown id is a validation error (never `String.to_atom/1`, so a typo cannot leak an atom) |
  | `model`          | string           | `harness.model` — optional provider/model override |
  | `command`        | string           | `harness.command` — optional binary override |
  | `effort`         | string           | `harness.effort` — optional Claude-only reasoning-effort level (`--effort <level>`, T36.6); overridden by the CLI `--effort` flag |
  | `permission_mode`| string           | `harness.permission_mode` — optional Claude-only permission mode (`--permission-mode <mode>`, issue #769); overridden by the CLI `--permission-mode` flag. **Defaults to `"auto"`** when unset: a headless dispatch into kazi's ephemeral partition worktree has no human to accept Claude Code's trust dialog, so an unset mode denies every tool call while the harness still exits 0 — a silent, billable no-op. Set `"bypassPermissions"` to widen, or `"plan"`/`"acceptEdits"` to narrow (note `acceptEdits` grants edits but NOT Bash, so a goal whose predicates need git cannot converge under it) |
  | `allowed_tools`  | array of strings | `harness.allowed_tools` — optional Claude-only tool allow-list (`--allowed-tools <t> …`, issue #769); overridden by the CLI `--allowed-tools` flag |

  `id` is required when a `[harness]` table is present. The loaded `id` threads
  into `Kazi.Harness.resolve/1` as `:goal_harness` (the wiring itself is T8.7).

  ### `[enforcement]` table (optional, → `Goal.enforcement`, T32.4/ADR-0042)

  Declares the goal's anti-gaming ENFORCEMENT profile — the guarantees that keep a
  capable agent from gaming a visible check (concept §2, Gap 1). Absent → the goal
  carries NO authored profile (`nil`) and the default policy is resolved at run
  time: **default-on for creation-mode goals, opt-in for repair**. Declaring the
  table is itself opting in (it defaults `enabled = true`); set `enabled = false`
  to opt a creation goal out.

  | Key               | TOML type        | Default  | Maps to / effect |
  |-------------------|------------------|----------|------------------|
  | `enabled`         | boolean          | `true`   | whether enforcement is active for the goal |
  | `clean_tree`      | boolean          | `true`   | run the GUARD + HELD-OUT graders from a clean detached worktree (so an in-iteration checker edit can't change their verdict); degrades gracefully + drops `clean_tree` from the reported guarantees when the workspace is not a git repo |
  | `clean_ref`       | string           | `"HEAD"` | the git ref the clean tree is checked out from |
  | `fail_on_skip`    | boolean          | `true`   | map skipped / errored / xfail sub-results to `:fail` |
  | `read_only_paths` | array of strings | `[]`     | repo-relative paths leased read-only to fixer agents; a post-iteration write to one is a FLAGGED gaming event (surfaced in `--json`) |

  A `[[enforcement.guard]]` array of tables declares test-count / coverage RATCHET
  guards (ADR-0042 §4) synthesized into the goal's `guards` as `:ratchet`
  predicates (the T32.3 machinery). Each guard:

  | Key                  | TOML type | Required | Maps to (the `:ratchet` config) |
  |----------------------|-----------|----------|---------------------------------|
  | `id`                 | string    | yes      | the guard predicate id |
  | `metric`             | table     | yes      | the metric (`cmd`/`args`/`env`/`path`/`timeout_ms`) producing the signal |
  | `direction`          | string    | no (`"higher_better"`) | `"higher_better"` (test count, coverage — down is worse) or `"lower_better"` |
  | `baseline`           | number/string | no (`"stored"`) | a literal, `"stored"`/`"prior"`, or a git ref |
  | `allowed_regression` | number    | no (`0`) | tolerated worsening; `0` = "may only improve" |

  See ADR-0042 and `docs/how-to/enforcement.md`; `kazi schema apply` documents the
  `enforcement` object surfaced in the `--json` run result.

  ### `[economy]` table (optional, → `Goal.debrief`, T48.11/ADR-0058)

  Opts a goal into the economy feedback loop's SELF-REPORT (hypothesis) tier
  (ADR-0058 §3). Absent → `Goal.debrief` stays `false`, and the dispatch prompt
  and envelope handling are BYTE-IDENTICAL to a goal-file with no `[economy]`
  table at all.

  | Key       | TOML type | Default | Maps to / effect |
  |-----------|-----------|---------|-------------------|
  | `debrief` | boolean   | `false` | when `true`, each dispatch prompt carries ONE capped debrief question ("list files/facts you needed but had to discover yourself"); a fenced structured answer in the agent's reply is parsed, capped, and persisted as HYPOTHESIS rows in the read-model. A debrief answer is WRITE-ONLY: no code path reads it back into a prompt (the gaming-surface rule, cf. T32.5) |

  A non-boolean `debrief` is a validation error. The CLI `--debrief` flag
  (`kazi apply … --debrief`) overrides whatever the goal-file declares, the
  same way `--standing` overrides `standing`.

  ### `[memory]` table (optional, → `Goal.memory_corpus`, ADR-0062)

  Overrides the semantic-recall corpus `Kazi.Memory.SemanticIndex` indexes for
  this goal. Absent, or present with no `corpus` key → `Goal.memory_corpus`
  stays `nil` (use `SemanticIndex.default_corpus/0`: `docs/adr/**/*.md`,
  `docs/lore.md`, `docs/devlog.md`, `AGENTS.md`, `CLAUDE.md`, `README.md`).

  | Key      | TOML type        | Maps to / effect |
  |----------|------------------|-------------------|
  | `corpus` | array of strings | `Goal.memory_corpus` — glob patterns relative to the workspace. An explicit `corpus = []` opts the goal OUT of recall entirely (zero recall, zero cost); this is distinct from omitting the key (default corpus). |

  A non-string-list `corpus` is a validation error.

  ### `[[group]]` array of tables (→ `Goal.groups`, T12.1/ADR-0020)

  Declares the goal's *group taxonomy* — the vocabulary by which a large goal
  organizes its predicates into a tree (pillar → domain → capability). Absent →
  `Goal.groups` stays `[]` (an ungrouped goal, loading exactly as before).

  | Key      | TOML type | Required | Maps to              |
  |----------|-----------|----------|----------------------|
  | `id`     | string    | yes      | `Group.id` — normalized to a canonical slug (case / whitespace / `&` collapse), so loosely-authored variants cannot fragment the tree |
  | `name`   | string    | no       | `Group.name` — the display label (defaults to the authored `id` when omitted) |
  | `parent` | string    | no       | `Group.parent` — a parent group id (normalized). Validated to reference a DECLARED group, and the parent chain to be acyclic (T12.2) |
  | `budget` | positive integer | no | `Group.budget` — an optional per-group cap (stored verbatim) |
  | `needs`  | array of strings | no | `Group.needs` — the group's dependency edges (T23.1, ADR-0028): ids that must converge BEFORE this group. Normalized; validated to reference DECLARED groups, with no self-edge and no cycle (a DAG). Absent → `[]` (fully parallel) |

  A DUPLICATE group id (after normalization) is a validation error, so the
  taxonomy is a set: declaring `"Identity & Access"` and `"identity-access"`
  twice fails loudly at load time rather than silently colliding.

  `needs` is the *execution-order* relation (T23.1, ADR-0028), DISTINCT from
  `parent`: `parent` drives budget rollup + reporting (ADR-0020); `needs`
  declares "must-converge-before" precedence for the predicate-graph waves (E23).
  The two are INDEPENDENT — a group may carry a `parent` AND `needs`, unrelated
  to each other. `needs` ABSENT means the group has no dependencies and is fully
  parallel (the ADR-0027 default; backward compatible). This is loader-only: it
  parses, stores, and validates the `needs` DAG; the scheduler's topological
  execution over it is T23.3.

  T12.2 adds the *drift guard* — cross-references validated after the taxonomy
  and predicates are both parsed (ADR-0020 §Decision 3); T23.1 (ADR-0028) extends
  it with the `needs` DAG checks:

    * a predicate whose `group` is not a declared id is a load error (catches the
      typo immediately, rather than fragmenting the tree silently);
    * a group whose `parent` is not a declared id is a load error;
    * a cycle in the `parent` chain is a load error;
    * a group whose `needs` references an undeclared id is a load error;
    * a group that `needs` ITSELF (a self-edge) is a load error;
    * a cycle over the `needs` graph is a load error (a DAG is required).

  ### `[[predicate]]` array of tables (→ `Kazi.Predicate` list)

  At least one is required. A predicate flagged `guard = true` is sorted into the
  goal's `guards` (an invariant that must not regress); all others become
  ordinary `predicates`.

  | Key           | TOML type | Required | Maps to                |
  |---------------|-----------|----------|------------------------|
  | `id`          | string    | yes      | `Predicate.id`         |
  | `provider`    | string    | yes      | `Predicate.kind` (see below) |
  | `description` | string    | no       | `Predicate.description` |
  | `guard`       | boolean   | no       | `Predicate.guard?` (default `false`) |
  | `acceptance`  | boolean   | no       | `Predicate.acceptance?` (default `false`) |
  | `held_out`    | boolean   | no       | `Predicate.held_out?` (default `false`) |
  | `group`       | string    | no       | `Predicate.group` — a declared `[[group]]` id (normalized); an unknown id is a load error (T12.2) |
  | *(any other)* | any       | no       | `Predicate.config` (atom-keyed, verbatim) |

  Every key on a `[[predicate]]` table other than the seven reserved keys above
  is collected, verbatim, into the predicate's `config` map (with atom keys).
  That config is handed untouched to the provider that evaluates the predicate.

  `acceptance = true` marks a predicate as an acceptance criterion (creation
  mode, T2.1) — desired NEW behavior expected to fail at t0. It is a declarative
  marker only; evaluation is unchanged. A predicate may not be both a `guard` and
  an `acceptance` predicate (a guard is an invariant, not a goal to reach).

  `held_out = true` withholds the predicate's id/definition/evidence from the
  agent's dispatch context while the controller still evaluates it and still
  requires it to pass for `:converged` (T32.6, ADR-0042 §6 — the
  visible-for-iteration vs hidden-for-acceptance split). It is orthogonal to
  `guard`/`acceptance`.

  #### Provider kinds

  The `provider` string is mapped to the registry `kind` atom the controller
  dispatches on:

  | `provider` string | `Predicate.kind` | Provider (task) |
  |-------------------|------------------|-----------------|
  | `"test_runner"`   | `:tests`         | test-runner (T0.5) |
  | `"http_probe"`    | `:http_probe`    | live probe (T0.5b) |
  | `"prod_log"`      | `:prod_log`      | prod-log query (T1.6) |
  | `"browser"`       | `:browser`       | Playwright UI check (T2.2) |
  | `"metrics"`       | `:metrics`       | live RED/SLO metrics (T32.10, ADR-0043) |
  | `"custom_script"` | `:custom_script` | generic command-runner (T32.1, ADR-0040) |
  | `"ratchet"`       | `:ratchet`       | signal-vs-baseline ratchet (T32.3, ADR-0041) |
  | `"static"`        | `:static`        | Dialyzer-led static analysis (T32.7, ADR-0043) |

  An unknown `provider` is a validation error rather than a silently-accepted
  atom, so a typo fails loudly at load time instead of at dispatch time.

  An `http_probe` or `browser` predicate REQUIRES a non-empty `url` (T48.1,
  ADR-0058) -- a missing or blank `url` is a load error naming the predicate
  and the key. Neither provider resolves any other key into a url at dispatch
  time: `Kazi.Providers.HttpProbe` and `Kazi.Providers.Browser` both bail with
  a bare `:missing_url` `:error` on every observation when `url` is absent, so
  without this check the failure is only ever discovered at dispatch --
  potentially not until the loop exhausts its budget (the motivating
  production incident behind ADR-0058 burned 40 iterations against exactly
  this config error). A relative `path` (an authoring-time-only shorthand some
  drafts emit before the real deployment target is known, see
  `Kazi.Pool.AccBridge`) does NOT satisfy this check.

  A `browser` predicate's `assertions` are additionally checked against the
  runner's assertion vocabulary (T43.1, ADR-0053): each entry must be a table
  with a known `type` (`visible`, `hidden`, `text`, `url`, `console_clean`), and
  `console_clean`'s optional `network` flag must be a boolean. kazi passes
  `assertions` VERBATIM to the runner, so an unknown type would otherwise come
  back as a permanent `ok: false` -- a :fail indistinguishable from a genuinely
  broken UI (the ADR-0058 failure shape again: a config error the loop can only
  find by burning budget). The list is kept in lockstep with the `ASSERTIONS`
  dispatch table in `priv/browser/playwright_runner.js`.

  A `custom_script` predicate carries extra keys (`verdict`, `path`, `pass_when`,
  `pass_codes`/`fail_codes`, `error_codes`, `evidence_format`, `timeout_ms`) that
  are VALIDATED at load time (an unknown verdict, a `json` verdict missing
  `path`/`pass_when`, a malformed `pass_when`, or an `exit_code` verdict without
  `pass_codes` is a load error). See `Kazi.Providers.CustomScript` and
  `kazi schema custom_script` for the full key reference.

  A `ratchet` predicate carries `metric` (an inline table with a `cmd`), a
  `baseline` (a number, `"stored"`/`"prior"`, or a git ref), a `direction`
  (`"higher_better"`/`"lower_better"`), and an optional `allowed_regression`,
  all VALIDATED at load time (a missing `metric.cmd`, an unknown `direction`, or
  a missing `baseline` is a load error). See `Kazi.Providers.Ratchet` and
  `kazi schema ratchet`.

  A `static` predicate carries `cmd` (the analyzer), an optional `format`
  (`"dialyzer"`/`"sarif"`), and an optional `baseline`/`allowed_regression` (the
  finding-count ratchet), all VALIDATED at load time (a missing `cmd`, an unknown
  `format`, an invalid `baseline`, or a non-numeric `allowed_regression` is a load
  error). See `Kazi.Providers.Static` and `kazi schema static`.

  ## Example

  See `priv/examples/deploy_target.toml` — the goal-file the Slice 0 dogfood
  (T0.12) drives, targeting the `fixtures/deploy-target/` Go service.

      {:ok, goal} = Kazi.Goal.Loader.load(path)

  Returns `{:ok, %Kazi.Goal{}}` or `{:error, reason}` with a human-readable,
  caller-facing reason string.
  """

  alias Kazi.{Budget, Goal, Predicate, Scope}
  alias Kazi.Goal.Group
  alias Kazi.Harness.Registry

  # provider string -> Predicate.kind atom. Adding a provider kind here is the
  # only change needed to author goals against a new provider (ADR-0002).
  @provider_kinds %{
    "test_runner" => :tests,
    "http_probe" => :http_probe,
    "prod_log" => :prod_log,
    "browser" => :browser,
    # T32.10 (ADR-0043): live RED/SLO metrics. Its pass_when/quantile/burn_rate
    # keys are validated below (validate_provider_config/3) so a mis-declared gate
    # fails loudly at load time, not silently at dispatch.
    "metrics" => :metrics,
    # T32.1 (ADR-0040): the generic command-runner. Its verdict/evidence keys are
    # validated below (validate_custom_script/2) so a mis-declared verdict fails
    # loudly at load time, not silently at dispatch.
    "custom_script" => :custom_script,
    # T32.3 (ADR-0041): the first-class ratchet mode — signal-vs-baseline within
    # an allowed regression. Its metric/baseline/direction keys are validated
    # below so a missing metric command or unknown direction fails at load time.
    "ratchet" => :ratchet,
    # T32.7 (ADR-0043): the first-class static-analysis provider. Its
    # cmd/format/baseline keys are validated below so an unknown format or a
    # missing command fails at load time, not silently at dispatch.
    "static" => :static,
    # T32.8 (ADR-0043): `:coverage` validates its patch metric + target below so a
    # mis-declared coverage gate fails at load, not at dispatch. `:property` runs
    # PropCheck under `mix test`; its `num_tests` (the score denominator) is
    # validated below. `:mutation` gates a 0-1 score on a threshold that is
    # validated `< 1.0` below (NEVER 100%). `:cve` scans dependencies; its tool +
    # (for the manifest tier) count_path are validated below.
    "coverage" => :coverage,
    "property" => :property,
    "mutation" => :mutation,
    "cve" => :cve
  }

  # T32.1b (ADR-0040 decision 7): the command-runner provider names that are
  # DEPRECATED — folded onto `custom_script` and kept only for the migration
  # window (removed in v2.0.0). Each maps to the custom_script form a goal should
  # migrate to, named in the STDERR deprecation hint. The names still RESOLVE
  # (their kinds are unchanged above) so no existing goal-file is broken; the hint
  # is advisory and goes to STDERR only (never `--json` stdout).
  @deprecated_providers %{
    "test_runner" => "custom_script (verdict = \"exit_zero\")",
    "prod_log" => "custom_script (verdict = \"match_count\")"
  }

  # Reserved keys on a [[predicate]] table; everything else falls through to
  # the predicate's `config`. `group` (T12.2) is reserved so a declared group
  # reference does not leak into the provider config.
  @predicate_reserved_keys ~w(id provider description guard acceptance held_out group)

  # goal-file `mode` string -> Goal.mode atom (T2.1 creation mode).
  @goal_modes %{"repair" => :repair, "create" => :create}

  @doc """
  The canonical `provider` string → `Kazi.Predicate.kind` atom mapping the loader
  validates against (ADR-0002).

  Exposed as the single source of truth so other write paths (notably
  `Kazi.Authoring`, which drafts goals from a prose idea) map providers to the
  exact same kinds the loader accepts — a provider added here flows to every
  caller, so the catalogs cannot drift (T26.8).
  """
  @spec provider_kinds() :: %{optional(String.t()) => atom()}
  def provider_kinds, do: @provider_kinds

  @doc """
  Reads the TOML goal-file at `path` and parses it into a `Kazi.Goal`.

  Returns `{:ok, goal}` on success, or `{:error, reason}` with a human-readable
  reason for a missing file, malformed TOML, or a schema violation.
  """
  @spec load(Path.t()) :: {:ok, Goal.t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, data} <- parse_toml(contents) do
      from_map(data)
    end
  end

  @doc """
  Parses an already-decoded TOML map (string-keyed) into a `Kazi.Goal`.

  Exposed so callers that obtain the map another way (e.g. an embedded goal)
  reuse the same validation as `load/1`.
  """
  @spec from_map(map()) :: {:ok, Goal.t()} | {:error, String.t()}
  def from_map(data) when is_map(data) do
    with {:ok, id} <- fetch_id(data),
         {:ok, mode} <- fetch_mode(data),
         # T3.4d standing wiring: optional top-level `standing` boolean (UC-016).
         {:ok, standing} <- fetch_standing(data),
         {:ok, budget} <- build_budget(Map.get(data, "budget", %{})),
         {:ok, scope} <- build_scope(Map.get(data, "scope", %{})),
         # T8.6 harness selection (ADR-0016): optional `[harness]` table.
         {:ok, harness} <- build_harness(Map.get(data, "harness")),
         # T12.1 group taxonomy (ADR-0020): optional `[[group]]` array.
         {:ok, groups} <- build_groups(Map.get(data, "group", [])),
         # T32.4 anti-gaming enforcement (ADR-0042): optional `[enforcement]` table.
         {:ok, enforcement} <- build_enforcement(Map.get(data, "enforcement")),
         # T48.11 (ADR-0058 §3): optional `[economy]` table (debrief opt-in).
         {:ok, debrief} <- build_economy(Map.get(data, "economy")),
         # ADR-0062: optional `[memory]` table (semantic-recall corpus override).
         {:ok, memory_corpus} <- build_memory(Map.get(data, "memory")),
         {:ok, all} <- build_predicates(Map.get(data, "predicate", [])),
         # T12.2 drift guard (ADR-0020 §Decision 3): cross-validate the taxonomy
         # once both groups and predicates are parsed — every predicate `group`
         # and every group `parent` must reference a DECLARED id, and the parent
         # chain must be acyclic.
         :ok <- validate_group_references(groups, all) do
      # T32.1b (ADR-0040 decision 7): the command-runner aliases `test_runner` /
      # `prod_log` are deprecated (folded onto `custom_script`). They keep
      # resolving through the migration window; emit a one-line migration hint to
      # STDERR — NEVER stdout — so a `--json` caller's stdout stays pure JSON.
      warn_deprecated_providers(Map.get(data, "predicate", []))

      {predicates, guards} = Enum.split_with(all, &(not &1.guard?))

      {:ok,
       Goal.new(id,
         name: Map.get(data, "name"),
         description: Map.get(data, "description"),
         mode: mode,
         predicates: predicates,
         guards: guards,
         budget: budget,
         scope: scope,
         standing: standing,
         harness: harness,
         groups: groups,
         enforcement: enforcement,
         debrief: debrief,
         memory_corpus: memory_corpus,
         metadata: Map.get(data, "metadata", %{})
       )}
    end
  end

  def from_map(_other), do: {:error, "goal-file must decode to a table (got a non-map value)"}

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read goal-file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_toml(contents) do
    case Toml.decode(contents) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "malformed TOML: #{format_toml_error(reason)}"}
    end
  end

  defp format_toml_error({:invalid_toml, message}) when is_binary(message), do: message
  defp format_toml_error(reason) when is_binary(reason), do: reason
  defp format_toml_error(reason), do: inspect(reason)

  defp fetch_id(data) do
    case Map.get(data, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "goal-file is missing required key \"id\""}
      _ -> {:error, "goal \"id\" must be a non-empty string"}
    end
  end

  # T2.1: optional goal `mode` ("repair" default | "create"). An unknown mode is
  # a validation error so a typo fails loudly at load time.
  defp fetch_mode(data) do
    case Map.get(data, "mode") do
      nil ->
        {:ok, :repair}

      mode when is_binary(mode) ->
        case Map.fetch(@goal_modes, mode) do
          {:ok, atom} ->
            {:ok, atom}

          :error ->
            {:error, "goal \"mode\" must be one of #{known_modes()} (got #{inspect(mode)})"}
        end

      _ ->
        {:error, "goal \"mode\" must be a string"}
    end
  end

  # T3.4d standing wiring: optional top-level `standing` boolean (UC-016).
  # Default false (one-shot converge-and-stop); a non-boolean fails loudly at
  # load time rather than being silently coerced.
  defp fetch_standing(data) do
    case Map.get(data, "standing", false) do
      standing when is_boolean(standing) -> {:ok, standing}
      _ -> {:error, "goal \"standing\" must be a boolean"}
    end
  end

  defp build_budget(budget) when is_map(budget) do
    keys = [:max_iterations, :max_wall_clock_ms, :max_tokens, :max_dispatches]

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.get(budget, Atom.to_string(key)) do
        nil -> {:cont, {:ok, acc}}
        value when is_integer(value) and value > 0 -> {:cont, {:ok, [{key, value} | acc]}}
        _ -> {:halt, {:error, "budget.#{key} must be a positive integer"}}
      end
    end)
    |> case do
      {:ok, opts} -> add_cached_read_weight(opts, budget)
      {:error, _} = err -> err
    end
  end

  defp build_budget(_), do: {:error, "[budget] must be a table"}

  # T34.4 (ADR-0046): the optional cached-read weight — the fraction of a fresh
  # token each cached-read input token counts as in the token budget. Absent →
  # the struct default; present → a number in `0.0..1.0` (an integer `0` or `1`
  # is accepted and coerced to a float). Out of range or non-numeric fails loudly
  # rather than being silently clamped, so a typo is caught at load time.
  defp add_cached_read_weight(opts, budget) do
    case Map.get(budget, "cached_read_weight") do
      nil ->
        {:ok, Budget.new(opts)}

      value when is_number(value) and value >= 0 and value <= 1 ->
        {:ok, Budget.new([{:cached_read_weight, value / 1} | opts])}

      _ ->
        {:error, "budget.cached_read_weight must be a number between 0.0 and 1.0"}
    end
  end

  defp build_scope(scope) when is_map(scope) do
    with {:ok, workspace} <- optional_string(scope, "workspace", "scope"),
         {:ok, repo} <- optional_string(scope, "repo", "scope"),
         {:ok, paths} <- optional_string_list(scope, "paths", "scope"),
         {:ok, write_paths} <- optional_string_list(scope, "write_paths", "scope"),
         {:ok, deny} <- optional_string_list(scope, "deny", "scope") do
      {:ok,
       Scope.new(
         workspace: workspace,
         repo: repo,
         paths: paths,
         write_paths: write_paths,
         deny: deny
       )}
    end
  end

  defp build_scope(_), do: {:error, "[scope] must be a table"}

  # T8.6 harness selection (ADR-0016): the optional `[harness]` table. Absent
  # (nil) → the goal carries no harness preference (`nil`), loading exactly as
  # before. Present → a `%{id:, model:, command:}` map. `id` is required and must
  # name a KNOWN harness (mapped via Registry.ids/0, never String.to_atom/1, so a
  # typo fails loudly at load time instead of leaking an atom). `model`/`command`
  # are optional strings. Modeled on the `[scope]` handling above.
  defp build_harness(nil), do: {:ok, nil}

  defp build_harness(harness) when is_map(harness) do
    with {:ok, id} <- fetch_harness_id(harness),
         {:ok, model} <- optional_string(harness, "model", "harness"),
         {:ok, command} <- optional_string(harness, "command", "harness"),
         # T36.6 (ADR-0047): optional Claude-only reasoning-effort lever (`--effort
         # <level>`), parsed exactly like `model`. Absent → nil (no goal-level effort).
         {:ok, effort} <- optional_string(harness, "effort", "harness"),
         # (issue #769): optional Claude-only permission mode (`--permission-mode
         # <mode>`), parsed exactly like `effort`. Absent → nil.
         {:ok, permission_mode} <- optional_string(harness, "permission_mode", "harness"),
         # (issue #769): optional Claude-only tool allow-list (`--allowed-tools
         # <t> …`). An empty/absent array means no goal-level override (nil, not
         # `[]`), mirroring the nil-means-unset convention every other harness
         # field here uses.
         {:ok, allowed_tools} <- optional_string_list(harness, "allowed_tools", "harness") do
      {:ok,
       %{
         id: id,
         model: model,
         command: command,
         effort: effort,
         permission_mode: permission_mode,
         allowed_tools: if(allowed_tools == [], do: nil, else: allowed_tools)
       }}
    end
  end

  defp build_harness(_), do: {:error, "[harness] must be a table"}

  # T32.4 anti-gaming enforcement (ADR-0042): the optional `[enforcement]` table.
  # Absent (nil) → the goal carries no authored profile (`nil`); the default-on-for-
  # creation policy is then resolved at run time (`Kazi.Enforcement.resolve/1`). A
  # present table is the author's intent: it defaults `enabled` to `true` (declaring
  # the table means opting in, including a creation OR repair goal), `clean_tree`
  # to `true`, `clean_ref` to `"HEAD"`, and `fail_on_skip` to `true`; an explicit
  # `enabled = false` opts a creation goal OUT. Each ratchet guard
  # (`[[enforcement.guard]]`) carries `id` + an inline `metric` table (passed
  # through to the `:ratchet` provider's own normalization) + optional
  # `direction`/`baseline`/`allowed_regression`. Wrong types fail loudly at load.
  defp build_enforcement(nil), do: {:ok, nil}

  defp build_enforcement(enf) when is_map(enf) do
    with {:ok, enabled} <- enforcement_bool(enf, "enabled", true),
         {:ok, clean_tree} <- enforcement_bool(enf, "clean_tree", true),
         {:ok, clean_ref} <- enforcement_clean_ref(enf),
         {:ok, fail_on_skip} <- enforcement_bool(enf, "fail_on_skip", true),
         {:ok, read_only_paths} <- enforcement_paths(enf),
         {:ok, guards} <- enforcement_guards(Map.get(enf, "guard", [])) do
      {:ok,
       Kazi.Enforcement.new(
         enabled: enabled,
         clean_tree: clean_tree,
         clean_ref: clean_ref,
         fail_on_skip: fail_on_skip,
         read_only_paths: read_only_paths,
         guards: guards
       )}
    end
  end

  defp build_enforcement(_), do: {:error, "[enforcement] must be a table"}

  # T48.11 (ADR-0058 §3): the optional `[economy]` table — currently a single
  # `debrief` boolean opt-in. Absent (nil) → `false` (byte-identical to today).
  # A non-boolean `debrief` fails loudly at load time rather than being coerced.
  defp build_economy(nil), do: {:ok, false}

  defp build_economy(econ) when is_map(econ) do
    case Map.get(econ, "debrief", false) do
      debrief when is_boolean(debrief) -> {:ok, debrief}
      _ -> {:error, "economy \"debrief\" must be a boolean"}
    end
  end

  defp build_economy(_), do: {:error, "[economy] must be a table"}

  # ADR-0062: the optional `[memory]` table — currently a single `corpus`
  # glob-list override. Absent (nil) -> `nil` (`Goal.memory_corpus` stays nil,
  # meaning "use `Kazi.Memory.SemanticIndex.default_corpus/0`"). A present
  # table with NO `corpus` key ALSO yields `nil` (same default), so declaring
  # an empty `[memory]` table is a no-op; an explicit `corpus = []` is the
  # only way to opt a goal OUT of recall entirely. A non-list/non-string-list
  # `corpus` fails loudly at load time.
  defp build_memory(nil), do: {:ok, nil}

  defp build_memory(mem) when is_map(mem) do
    case Map.get(mem, "corpus") do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "memory \"corpus\" must be an array of strings"}

      _ ->
        {:error, "memory \"corpus\" must be an array of strings"}
    end
  end

  defp build_memory(_), do: {:error, "[memory] must be a table"}

  defp enforcement_bool(enf, key, default) do
    case Map.get(enf, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "enforcement \"#{key}\" must be a boolean"}
    end
  end

  defp enforcement_clean_ref(enf) do
    case Map.get(enf, "clean_ref", "HEAD") do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ -> {:error, "enforcement \"clean_ref\" must be a non-empty string"}
    end
  end

  defp enforcement_paths(enf) do
    case Map.get(enf, "read_only_paths", []) do
      paths when is_list(paths) ->
        if Enum.all?(paths, &is_binary/1),
          do: {:ok, paths},
          else: {:error, "enforcement \"read_only_paths\" must be a list of strings"}

      _ ->
        {:error, "enforcement \"read_only_paths\" must be a list of strings"}
    end
  end

  defp enforcement_guards(guards) when is_list(guards) do
    Enum.reduce_while(guards, {:ok, []}, fn guard, {:ok, acc} ->
      case enforcement_guard(guard) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp enforcement_guards(_), do: {:error, "[[enforcement.guard]] must be an array of tables"}

  @known_guard_directions ["higher_better", "lower_better"]

  defp enforcement_guard(guard) when is_map(guard) do
    case Map.get(guard, "id") do
      id when is_binary(id) and id != "" ->
        with {:ok, direction} <-
               validate_guard_direction(Map.get(guard, "direction", "higher_better")),
             {:ok, baseline} <- validate_guard_baseline(Map.get(guard, "baseline", "stored")) do
          {:ok,
           %{
             id: id,
             metric: Map.get(guard, "metric", %{}),
             direction: direction,
             baseline: baseline,
             allowed_regression: Map.get(guard, "allowed_regression", 0)
           }}
        end

      _ ->
        {:error, "enforcement guard is missing a non-empty string \"id\""}
    end
  end

  defp enforcement_guard(_), do: {:error, "[[enforcement.guard]] must be a table"}

  # `metric`/`direction`/`baseline` were previously stored verbatim with no
  # validation, so a typo'd guard config was silently accepted (deep review
  # L12). `direction` has exactly two known values (`Kazi.Ratchet.regression/3`
  # only implements these two); `baseline` must be either a literal number or a
  # non-empty string (a "stored" keyword or a git ref —
  # `Kazi.Ratchet.resolve_baseline/5` accepts nothing else).
  defp validate_guard_direction(direction) when direction in @known_guard_directions,
    do: {:ok, direction}

  defp validate_guard_direction(other) do
    {:error,
     "enforcement guard \"direction\" must be \"higher_better\" or \"lower_better\", " <>
       "got #{inspect(other)}"}
  end

  defp validate_guard_baseline(baseline) when is_number(baseline), do: {:ok, baseline}

  defp validate_guard_baseline(baseline) when is_binary(baseline) and baseline != "",
    do: {:ok, baseline}

  defp validate_guard_baseline(other) do
    {:error,
     "enforcement guard \"baseline\" must be a number or a non-empty string, got #{inspect(other)}"}
  end

  defp fetch_harness_id(harness) do
    case Map.get(harness, "id") do
      nil ->
        {:error, "[harness] is missing required key \"id\""}

      id when is_binary(id) ->
        case Enum.find(Registry.ids(), &(Atom.to_string(&1) == id)) do
          nil ->
            {:error,
             "harness.id has unknown harness #{inspect(id)} (known: #{known_harnesses()})"}

          known ->
            {:ok, known}
        end

      _ ->
        {:error, "harness.id must be a string"}
    end
  end

  # T12.1 group taxonomy (ADR-0020): the optional `[[group]]` array. Absent (the
  # default []) → the goal carries no taxonomy (`groups: []`), loading exactly as
  # before. Present → each entry parses into a `Kazi.Goal.Group` with a NORMALIZED
  # id (case / whitespace / `&` collapse, so loosely-authored variants resolve to
  # one canonical slug). A duplicate id (after normalization) is a load error, so
  # the taxonomy is a set. `parent` is parsed and stored only; its reference /
  # cycle validation is T12.2. Modeled on the `[[predicate]]` handling above.
  defp build_groups([]), do: {:ok, []}

  defp build_groups(groups) when is_list(groups) do
    groups
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case build_group(raw, index, acc) do
        {:ok, group} -> {:cont, {:ok, [group | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, _} = err -> err
    end
  end

  defp build_groups(_), do: {:error, "[[group]] must be an array of tables"}

  # `acc` is the groups parsed so far (newest-first); a normalized id already in
  # `acc` is a duplicate and a load error.
  defp build_group(raw, index, acc) when is_map(raw) do
    with {:ok, id} <- fetch_group_id(raw, index),
         :ok <- reject_duplicate_group(id, acc, raw),
         {:ok, name} <- fetch_group_name(raw, id),
         {:ok, parent} <- fetch_group_parent(raw, id),
         {:ok, budget} <- fetch_group_budget(raw, id),
         {:ok, needs} <- fetch_group_needs(raw, id) do
      {:ok, Group.new(id, name, parent: parent, budget: budget, needs: needs)}
    end
  end

  defp build_group(_raw, index, _acc),
    do: {:error, "[[group]] ##{index} must be a table"}

  # The authored id string (required, non-empty). Group.new/3 normalizes it; the
  # raw string is returned here so error messages and the duplicate check report
  # the canonical id the author's value maps to.
  defp fetch_group_id(raw, index) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" ->
        case Group.normalize_id(id) do
          "" ->
            {:error, "[[group]] ##{index} \"id\" #{inspect(id)} normalizes to an empty id"}

          normalized ->
            {:ok, normalized}
        end

      nil ->
        {:error, "[[group]] ##{index} is missing required key \"id\""}

      _ ->
        {:error, "[[group]] ##{index} \"id\" must be a non-empty string"}
    end
  end

  defp reject_duplicate_group(id, acc, raw) do
    if Enum.any?(acc, &(&1.id == id)) do
      {:error,
       "duplicate group id #{inspect(id)}" <>
         duplicate_group_hint(Map.get(raw, "id"), id)}
    else
      :ok
    end
  end

  # If the authored value differed from the normalized id, name both so the
  # author sees WHY two distinct-looking ids collided (the drift guard's point).
  defp duplicate_group_hint(authored, id) when is_binary(authored) and authored != id,
    do: " (authored #{inspect(authored)} normalizes to #{inspect(id)})"

  defp duplicate_group_hint(_authored, _id), do: ""

  # Display label. Optional: defaults to the authored id string so a group always
  # has a name. A non-string name is a validation error.
  defp fetch_group_name(raw, id) do
    case Map.get(raw, "name") do
      nil -> {:ok, Map.get(raw, "id", id)}
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, "group #{inspect(id)} \"name\" must be a non-empty string"}
    end
  end

  # Optional parent group id (normalized via Group.new/3). Parsed and stored
  # only; T12.2 validates that it references a declared group and is acyclic.
  defp fetch_group_parent(raw, id) do
    case Map.get(raw, "parent") do
      nil -> {:ok, nil}
      parent when is_binary(parent) and parent != "" -> {:ok, parent}
      _ -> {:error, "group #{inspect(id)} \"parent\" must be a non-empty string"}
    end
  end

  # Optional per-group budget cap. Stored verbatim; a non-positive value fails
  # loudly, matching the goal `[budget]` table's rule.
  defp fetch_group_budget(raw, id) do
    case Map.get(raw, "budget") do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "group #{inspect(id)} \"budget\" must be a positive integer"}
    end
  end

  # T23.1 (ADR-0028): optional `needs` — the group's dependency edges, an array
  # of group ids that must converge BEFORE this group. Absent → [] (no
  # dependencies, fully parallel). Parsed here as a list of non-empty strings
  # (each normalized via Group.new/3 to match declared ids consistently); its
  # reference / self-edge / cycle validation is the `needs` DAG guard, run once
  # the whole taxonomy is known (validate_group_references/2).
  defp fetch_group_needs(raw, id) do
    case Map.get(raw, "needs") do
      nil ->
        {:ok, []}

      needs when is_list(needs) ->
        if Enum.all?(needs, &(is_binary(&1) and &1 != "")) do
          {:ok, needs}
        else
          {:error, "group #{inspect(id)} \"needs\" must be an array of non-empty strings"}
        end

      _ ->
        {:error, "group #{inspect(id)} \"needs\" must be an array of non-empty strings"}
    end
  end

  # The drift guard. Run after the taxonomy AND the predicates are both parsed,
  # so every cross-reference can be checked against the declared id set.
  # Short-circuits on the first failure:
  #
  # T12.2 (ADR-0020 §Decision 3) — the `parent` relation:
  #   1. every predicate `group` references a DECLARED id (the typo guard — a
  #      misspelled group would otherwise silently fragment the tree);
  #   2. every group `parent` references a DECLARED id;
  #   3. the `parent` chain is acyclic.
  #
  # T23.1 (ADR-0028) — the `needs` relation (an INDEPENDENT DAG):
  #   4. every group `needs` edge references a DECLARED id;
  #   5. no group `needs` ITSELF (no self-edge);
  #   6. the `needs` graph is acyclic (a DAG is required).
  #
  # Ids are already normalized at parse time (predicate group, group parent, and
  # each group `needs` edge all via Group.normalize_id/1), so set membership is
  # an exact compare.
  defp validate_group_references(groups, predicates) do
    declared = MapSet.new(groups, & &1.id)

    with :ok <- validate_predicate_groups(predicates, declared),
         :ok <- validate_group_parents(groups, declared),
         :ok <- validate_no_group_cycle(groups),
         :ok <- validate_group_needs(groups, declared),
         :ok <- validate_no_group_self_need(groups) do
      validate_no_needs_cycle(groups)
    end
  end

  defp validate_predicate_groups(predicates, declared) do
    Enum.reduce_while(predicates, :ok, fn predicate, :ok ->
      case predicate.group do
        nil ->
          {:cont, :ok}

        group ->
          if MapSet.member?(declared, group) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "predicate #{inspect(predicate.id)} references unknown group " <>
                "#{inspect(group)} (declared: #{known_groups(declared)})"}}
          end
      end
    end)
  end

  defp validate_group_parents(groups, declared) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case group.parent do
        nil ->
          {:cont, :ok}

        parent ->
          if MapSet.member?(declared, parent) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "group #{inspect(group.id)} references unknown parent " <>
                "#{inspect(parent)} (declared: #{known_groups(declared)})"}}
          end
      end
    end)
  end

  # Walk each group's parent chain; a node revisited within one walk is a cycle.
  # `parents` maps a group id to its (already-declared) parent id, so the walk is
  # a simple pointer-chase. Reported with the offending group so the author can
  # find the loop. Parent existence is guaranteed by validate_group_parents/2,
  # which runs first.
  defp validate_no_group_cycle(groups) do
    parents = Map.new(groups, &{&1.id, &1.parent})

    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case walk_parent_chain(group.id, parents, MapSet.new()) do
        :ok -> {:cont, :ok}
        {:cycle, id} -> {:halt, {:error, "group #{inspect(id)} has a cyclic parent chain"}}
      end
    end)
  end

  defp walk_parent_chain(nil, _parents, _seen), do: :ok

  defp walk_parent_chain(id, parents, seen) do
    if MapSet.member?(seen, id) do
      {:cycle, id}
    else
      walk_parent_chain(Map.get(parents, id), parents, MapSet.put(seen, id))
    end
  end

  # T23.1 (ADR-0028): every `needs` edge must reference a DECLARED group — the
  # same typo guard as `parent`, but on the independent dependency relation. An
  # unknown edge target is a load error naming the declared ids.
  defp validate_group_needs(groups, declared) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case Enum.find(group.needs, &(not MapSet.member?(declared, &1))) do
        nil ->
          {:cont, :ok}

        unknown ->
          {:halt,
           {:error,
            "group #{inspect(group.id)} needs unknown group " <>
              "#{inspect(unknown)} (declared: #{known_groups(declared)})"}}
      end
    end)
  end

  # T23.1 (ADR-0028): a group may not depend on ITSELF — a self-edge is a
  # degenerate one-node cycle and is rejected with a pointed message (separate
  # from the general cycle check so the author sees the exact mistake).
  defp validate_no_group_self_need(groups) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      if group.id in group.needs do
        {:halt, {:error, "group #{inspect(group.id)} needs itself (a self-edge is not allowed)"}}
      else
        {:cont, :ok}
      end
    end)
  end

  # T23.1 (ADR-0028): the `needs` graph must be a DAG. Unlike `parent` (a single
  # pointer per node, a simple chain-walk), a group may declare MANY `needs`
  # edges, so this is a depth-first cycle detection over the full edge set: a
  # node revisited on the current DFS stack closes a cycle. Edge targets are
  # guaranteed to be declared by validate_group_needs/2, which runs first.
  #
  # `walk_needs/4` threads a `finished` memo (a node whose subtree is already
  # PROVEN acyclic) across BOTH the recursive descent and the outer per-group
  # loop, in addition to the per-walk `stack` (deep review L1): without it, a
  # wide diamond lattice of `needs` edges re-walks each shared descendant once
  # per path to it — O(2^n) over a DAG with n diamond levels, hanging
  # `kazi apply`/`--explain` at load. Memoizing "already finished" turns every
  # node into a single expansion, O(V+E) total.
  defp validate_no_needs_cycle(groups) do
    needs_by_id = Map.new(groups, &{&1.id, &1.needs})

    {result, _finished} =
      Enum.reduce_while(groups, {:ok, MapSet.new()}, fn group, {:ok, finished} ->
        case walk_needs(group.id, needs_by_id, MapSet.new(), finished) do
          {:ok, finished} ->
            {:cont, {:ok, finished}}

          {:cycle, id} ->
            {:halt, {{:error, "group #{inspect(id)} has a cyclic needs chain"}, finished}}
        end
      end)

    result
  end

  defp walk_needs(id, needs_by_id, stack, finished) do
    cond do
      MapSet.member?(finished, id) ->
        {:ok, finished}

      MapSet.member?(stack, id) ->
        {:cycle, id}

      true ->
        stack = MapSet.put(stack, id)

        needs_by_id
        |> Map.get(id, [])
        |> Enum.reduce_while({:ok, finished}, fn dep, {:ok, finished} ->
          case walk_needs(dep, needs_by_id, stack, finished) do
            {:ok, finished} -> {:cont, {:ok, finished}}
            {:cycle, _} = cycle -> {:halt, cycle}
          end
        end)
        |> case do
          {:ok, finished} -> {:ok, MapSet.put(finished, id)}
          {:cycle, _} = cycle -> cycle
        end
    end
  end

  defp build_predicates([]), do: {:error, "goal-file must declare at least one [[predicate]]"}

  defp build_predicates(predicates) when is_list(predicates) do
    predicates
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case build_predicate(raw, index) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, _} = err -> err
    end
  end

  defp build_predicates(_), do: {:error, "[[predicate]] must be an array of tables"}

  defp build_predicate(raw, index) when is_map(raw) do
    with {:ok, id} <- fetch_predicate_id(raw, index),
         {:ok, kind} <- fetch_provider_kind(raw, id),
         {:ok, guard?} <- fetch_guard(raw, id),
         {:ok, acceptance?} <- fetch_acceptance(raw, id),
         :ok <- reject_guard_acceptance(guard?, acceptance?, id),
         {:ok, held_out?} <- fetch_held_out(raw, id),
         {:ok, group} <- fetch_predicate_group(raw, id),
         {:ok, config} <- predicate_config(raw, id, kind),
         # T32.1 (ADR-0040): provider-specific config validation. Generic for
         # every other kind (config is handed verbatim to the provider); for
         # custom_script the verdict/evidence keys are checked so a mis-declared
         # gate fails loudly at load time, not silently at dispatch.
         :ok <- validate_provider_config(kind, config, id) do
      {:ok,
       Predicate.new(id, kind,
         description: Map.get(raw, "description"),
         guard?: guard?,
         acceptance?: acceptance?,
         held_out?: held_out?,
         group: group,
         config: config
       )}
    end
  end

  defp build_predicate(_raw, index),
    do: {:error, "[[predicate]] ##{index} must be a table"}

  defp fetch_predicate_id(raw, index) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "[[predicate]] ##{index} is missing required key \"id\""}
      _ -> {:error, "[[predicate]] ##{index} \"id\" must be a non-empty string"}
    end
  end

  defp fetch_provider_kind(raw, id) do
    case Map.get(raw, "provider") do
      nil ->
        {:error, "predicate #{inspect(id)} is missing required key \"provider\""}

      provider when is_binary(provider) ->
        case Map.fetch(@provider_kinds, provider) do
          {:ok, kind} ->
            {:ok, kind}

          :error ->
            {:error,
             "predicate #{inspect(id)} has unknown provider #{inspect(provider)} " <>
               "(known: #{known_providers()})"}
        end

      _ ->
        {:error, "predicate #{inspect(id)} \"provider\" must be a string"}
    end
  end

  defp fetch_guard(raw, id) do
    case Map.get(raw, "guard", false) do
      guard? when is_boolean(guard?) -> {:ok, guard?}
      _ -> {:error, "predicate #{inspect(id)} \"guard\" must be a boolean"}
    end
  end

  # T2.1: optional `acceptance` boolean marking an acceptance criterion.
  defp fetch_acceptance(raw, id) do
    case Map.get(raw, "acceptance", false) do
      acceptance? when is_boolean(acceptance?) -> {:ok, acceptance?}
      _ -> {:error, "predicate #{inspect(id)} \"acceptance\" must be a boolean"}
    end
  end

  # T32.6 (ADR-0042 §6): optional `held_out` boolean. When true the controller
  # still evaluates the predicate and still requires it to pass for `:converged`,
  # but its id/definition/evidence are withheld from the agent's dispatch context.
  defp fetch_held_out(raw, id) do
    case Map.get(raw, "held_out", false) do
      held_out? when is_boolean(held_out?) -> {:ok, held_out?}
      _ -> {:error, "predicate #{inspect(id)} \"held_out\" must be a boolean"}
    end
  end

  # A guard is an invariant that must not regress, not a goal to reach; an
  # acceptance criterion is a goal to reach. They are mutually exclusive.
  defp reject_guard_acceptance(true, true, id),
    do: {:error, "predicate #{inspect(id)} may not be both a guard and an acceptance predicate"}

  defp reject_guard_acceptance(_guard?, _acceptance?, _id), do: :ok

  # T12.2 (ADR-0020 §Decision 2): optional `group` — a declared group id this
  # predicate belongs to. Absent → nil (ungrouped, unchanged). Present → the
  # value is NORMALIZED the same way group ids are (Group.normalize_id/1) so a
  # loosely-authored reference resolves to the canonical slug. Whether the
  # normalized id is actually DECLARED is checked once the taxonomy is known
  # (validate_group_references/2); here we only parse and normalize the field.
  defp fetch_predicate_group(raw, id) do
    case Map.get(raw, "group") do
      nil -> {:ok, nil}
      group when is_binary(group) and group != "" -> {:ok, Group.normalize_id(group)}
      _ -> {:error, "predicate #{inspect(id)} \"group\" must be a non-empty string"}
    end
  end

  # Every non-reserved key on the predicate table becomes config, atom-keyed,
  # handed verbatim to the provider.
  #
  # M3 (deep-review-001): `String.to_atom/1` on an UNBOUNDED set of untrusted
  # keys (a hallucinating inner agent via `kazi adopt --enrich`, or an inline-goal
  # MCP `kazi_apply` call) grows the BEAM atom table without limit — atoms are
  # never garbage collected, so enough distinct junk keys crash the VM. Every
  # LEGITIMATE provider config key is already a compile-time atom literal
  # somewhere in the provider modules, so `String.to_existing_atom/1` succeeds
  # for all real configs and only rejects keys no provider has ever declared —
  # turning an atom-exhaustion DoS into an ordinary load error. That only holds
  # if the provider module has actually been CODE-loaded, which a bare
  # module-name reference (e.g. `Kazi.Runtime`'s dispatch table) does NOT do —
  # so we force-load `kind`'s provider here first (a fixed, non-attacker-
  # controlled module), otherwise a provider referenced nowhere else (e.g.
  # `:metrics`) rejects its own real keys as "unknown" until first evaluated.
  defp predicate_config(raw, id, kind) do
    ensure_provider_loaded(kind)

    raw
    |> Map.drop(@predicate_reserved_keys)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case safe_config_key(key) do
        {:ok, atom_key} ->
          {:cont, {:ok, Map.put(acc, atom_key, value)}}

        :unknown ->
          {:halt, {:error, "predicate #{inspect(id)} has unknown config key #{inspect(key)}"}}
      end
    end)
  end

  # Documentation-only metadata keys the Gherkin importer (ADR-0050) records on a
  # predicate for self-description: `feature`, `scenario`, `steps`. NO provider
  # consumes them, so `ensure_provider_loaded/1` does not intern their atoms --
  # and in the RELEASE binary no other module that names them is loaded when a
  # goal loads, so `String.to_existing_atom/1` below would reject a spec-imported
  # `custom_script` goal as "unknown config key" (it loads fine under `mix`, where
  # the fuller module set + test code interns them -- which is why every test and
  # CI passed while `kazi apply` on the real binary failed; see docs/devlog.md
  # 2026-07-15). Declaring them here interns the atoms whenever THIS module loads
  # -- which is always, during any load -- and documents the bounded, fixed
  # allowlist (no atom-exhaustion risk). If the importer grows a new metadata key,
  # add it here too (pinned by a coherence test in gherkin_importer_test.exs).
  # `role`, `priority` and `interface` join them for a TAGGED behavior spec
  # (T41.1, ADR-0054): the same self-describing, provider-unconsumed metadata,
  # derived from `@role:`/`@priority:`/`@interface:` tags.
  @gherkin_doc_keys [:feature, :scenario, :steps, :role, :priority, :interface]

  defp safe_config_key(key) when is_binary(key) do
    case Enum.find(@gherkin_doc_keys, &(Atom.to_string(&1) == key)) do
      nil -> existing_atom_key(key)
      atom -> {:ok, atom}
    end
  end

  defp existing_atom_key(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :unknown
  end

  # Force-loads `kind`'s provider module (via `Kazi.Runtime.provider_modules/0`)
  # so any config-key atom it references in its own source is interned before
  # `safe_config_key/1` checks it. A no-op (fast, idempotent) once the module is
  # loaded; silently a no-op for a `kind` with no registered module (loader-level
  # validation still runs — this only affects atom interning).
  defp ensure_provider_loaded(kind) do
    case Map.fetch(Kazi.Runtime.provider_modules(), kind) do
      {:ok, module} -> Code.ensure_loaded(module)
      :error -> :ok
    end
  end

  # The verdict strings + evidence-format envelopes a custom_script predicate may
  # declare. Kept in lockstep with Kazi.Providers.CustomScript (the engine that
  # consumes them); validated here so a typo is a load error.
  @custom_script_verdicts ~w(exit_zero exit_code json match_count)
  @custom_script_evidence_formats ~w(sarif junit json raw)

  # T32.1 (ADR-0040): per-provider config validation. Every kind other than
  # custom_script hands its config verbatim to the provider (no extra schema), so
  # the default is a no-op. custom_script's verdict/evidence keys are checked so a
  # mis-declared gate (an unknown verdict, a json verdict missing `path`, a bad
  # `pass_when`) fails loudly at load time instead of silently at dispatch.
  defp validate_provider_config(:custom_script, config, id) do
    with :ok <- validate_custom_script_cmd(config, id),
         {:ok, verdict} <- validate_custom_script_verdict(config, id),
         :ok <- validate_custom_script_args(config, id),
         :ok <- validate_custom_script_error_codes(config, id),
         :ok <- validate_custom_script_timeout(config, id),
         :ok <- validate_custom_script_merge_stderr(config, id),
         :ok <- validate_custom_script_evidence_format(config, id) do
      validate_custom_script_for_verdict(verdict, config, id)
    end
  end

  # T32.3 (ADR-0041): a ratchet predicate's metric/baseline/direction keys are
  # checked so a missing metric command, an unknown direction, a missing baseline,
  # or a non-numeric allowed_regression fails loudly at load, not at dispatch.
  defp validate_provider_config(:ratchet, config, id) do
    with :ok <- validate_ratchet_metric(config, id),
         :ok <- validate_ratchet_direction(config, id),
         :ok <- validate_ratchet_baseline(config, id) do
      validate_ratchet_allowed_regression(config, id)
    end
  end

  # T32.10 (ADR-0043): metrics config validation. The mode is implicit (burn_rate
  # > quantile > scalar); each mode's required keys are checked so a mis-declared
  # gate (a bad pass_when, an out-of-range quantile, a burn_rate missing a window)
  # fails loudly at load time. A predicate with NO endpoint is intentionally
  # allowed (it degrades to :unknown / not-applicable at evaluation).
  defp validate_provider_config(:metrics, config, id) do
    with :ok <- validate_metrics_direction(config, id),
         :ok <- validate_metrics_pass_when(config, id) do
      validate_metrics_mode(config, id)
    end
  end

  # T32.7 (ADR-0043): a static predicate's analyzer/format/baseline keys are
  # checked so a missing cmd, an unknown format, an invalid baseline, or a
  # non-numeric allowed_regression fails loudly at load, not at dispatch.
  defp validate_provider_config(:static, config, id) do
    with :ok <- validate_static_cmd(config, id),
         :ok <- validate_static_args(config, id),
         :ok <- validate_static_format(config, id),
         :ok <- validate_static_baseline(config, id),
         :ok <- validate_static_timeout(config, id) do
      validate_static_allowed_regression(config, id)
    end
  end

  # T32.8 (ADR-0043): a coverage predicate requires a `patch` metric table with a
  # non-empty `cmd` and a numeric `target` (the patch-coverage floor), so a
  # mis-declared coverage gate fails at load, not at dispatch.
  defp validate_provider_config(:coverage, config, id) do
    with :ok <- validate_coverage_patch(config, id),
         :ok <- validate_coverage_target(config, id) do
      validate_coverage_project(config, id)
    end
  end

  # T32.8 (ADR-0043): a property predicate's `num_tests` (the score denominator)
  # must be a positive integer when declared; cmd/args default to `mix test`.
  defp validate_provider_config(:property, config, id) do
    case Map.get(config, :num_tests) do
      nil ->
        :ok

      n when is_integer(n) and n > 0 ->
        :ok

      other ->
        {:error,
         "property predicate #{inspect(id)} \"num_tests\" must be a positive integer " <>
           "(got #{inspect(other)})"}
    end
  end

  # T32.8 (ADR-0043): a mutation predicate's `threshold` must be a number in
  # [0, 1.0) — NEVER 100% (an unreachable, gameable target; equivalent mutants make
  # a perfect score impossible). It also needs a way to read the score: either a
  # `score_path` or BOTH `killed_path` and `survived_path`. Validated at load.
  defp validate_provider_config(:mutation, config, id) do
    with :ok <- validate_mutation_threshold(config, id) do
      validate_mutation_score_config(config, id)
    end
  end

  # T32.8 (ADR-0043): a cve predicate's `tool` (when declared) must be a known
  # scanner, and a manifest-tier tool (trivy/grype/npm_audit) requires a
  # `count_path` to read the vuln count it ratchets. govulncheck (tier 1, the
  # default) needs neither — it parses its reachability finding stream.
  defp validate_provider_config(:cve, config, id) do
    with {:ok, tool} <- validate_cve_tool(config, id) do
      validate_cve_count_path(tool, config, id)
    end
  end

  # T48.1 (ADR-0058): a live predicate (http_probe, browser) with no `url`
  # cannot ever pass or fail meaningfully -- both providers bail with a bare
  # `:missing_url` :error on every dispatch cycle (Kazi.Providers.HttpProbe /
  # Kazi.Providers.Browser `fetch_url/1`), which the loop previously could only
  # discover at OBSERVATION time. A production run burned 40 iterations against
  # exactly this config error before `max_iterations` finally tripped it as a
  # (mislabeled) `:over_budget`. `:url` is REQUIRED for these two kinds, checked
  # loudly here -- mirroring the `[budget]` table's load-time validation style --
  # so a missing/blank url fails at goal-load, naming the predicate and the key,
  # instead of silently wedging the loop. There is no runtime resolution of a
  # relative `path` into a `url` anywhere in the providers, so a `path`-only
  # config (an authoring-time-only shorthand some drafts emit before the real
  # target is known, see `Kazi.Pool.AccBridge`) does NOT satisfy this check --
  # it must be resolved to a full `url` before the goal is loadable.
  defp validate_provider_config(:http_probe, config, id),
    do: require_live_url(config, id, "http_probe")

  defp validate_provider_config(:browser, config, id) do
    with :ok <- require_live_url(config, id, "browser") do
      validate_browser_assertions(config, id)
    end
  end

  defp validate_provider_config(_kind, _config, _id), do: :ok

  defp require_live_url(config, id, provider) do
    case Map.get(config, :url) do
      url when is_binary(url) and url != "" ->
        :ok

      _ ->
        {:error,
         "#{provider} predicate #{inspect(id)} is missing required key \"url\" " <>
           "(a live predicate needs a url to probe)"}
    end
  end

  # --- browser assertion vocabulary (T43.1, ADR-0053 §1) ---------------------

  # Kept in lockstep with the ASSERTIONS dispatch table in
  # priv/browser/playwright_runner.js. The RUNNER owns the vocabulary -- kazi
  # passes `assertions` verbatim (the ADR-0040 dividend) -- but an unknown type
  # reaches the runner only to come back `ok: false`, i.e. a permanent :fail the
  # author reads as "my UI is broken" rather than "I typo'd the type". That is the
  # L-0018 class (a drafting harness GUESSES predicate config) and the same
  # failure shape ADR-0058 fixed for a missing `url`: a config error the loop can
  # only discover by burning its budget. Checking the vocabulary at LOAD names the
  # bad type and the valid set instead. A new runner type must be added here too.
  @browser_assertion_types ~w(visible hidden text url console_clean)

  defp validate_browser_assertions(config, id) do
    case Map.get(config, :assertions) do
      nil ->
        :ok

      assertions when is_list(assertions) ->
        Enum.reduce_while(assertions, :ok, fn assertion, :ok ->
          case validate_browser_assertion(assertion, id) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      other ->
        {:error,
         "browser predicate #{inspect(id)} \"assertions\" must be a list of tables " <>
           "(got #{inspect(other)})"}
    end
  end

  defp validate_browser_assertion(assertion, id) when is_map(assertion) do
    case assertion_key(assertion, "type") do
      type when type in @browser_assertion_types ->
        validate_browser_assertion_keys(type, assertion, id)

      nil ->
        {:error, "browser predicate #{inspect(id)} has an assertion with no \"type\""}

      other ->
        {:error,
         "browser predicate #{inspect(id)} has an assertion with unknown type " <>
           "#{inspect(other)} (valid: #{Enum.join(@browser_assertion_types, ", ")})"}
    end
  end

  defp validate_browser_assertion(other, id) do
    {:error,
     "browser predicate #{inspect(id)} \"assertions\" must be a list of tables " <>
       "(got element #{inspect(other)})"}
  end

  # `console_clean`'s opt-in `network` flag must be a real boolean: the runner is
  # JavaScript, where the string "false" is TRUTHY -- so `network = "false"` would
  # silently turn 4xx/5xx checking ON, the exact inverse of what was authored.
  defp validate_browser_assertion_keys("console_clean", assertion, id) do
    case assertion_key(assertion, "network") do
      network when is_boolean(network) or is_nil(network) ->
        :ok

      other ->
        {:error,
         "browser predicate #{inspect(id)} console_clean assertion \"network\" must be a " <>
           "boolean (got #{inspect(other)})"}
    end
  end

  defp validate_browser_assertion_keys(_type, _assertion, _id), do: :ok

  # An assertion table arrives string-keyed from TOML (the loader only atomizes
  # top-level predicate keys) or atom-keyed from an inline/authored map. Unlike
  # `fetch_either/2` this distinguishes a present `false` from an absent key --
  # `console_clean`'s `network` is a boolean, and `||` would read `false` as
  # missing.
  defp assertion_key(assertion, key) do
    with :error <- Map.fetch(assertion, key),
         :error <- atom_key_fetch(assertion, key) do
      nil
    else
      {:ok, value} -> value
    end
  end

  defp atom_key_fetch(assertion, key) do
    Map.fetch(assertion, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
  end

  # --- static (T32.7, ADR-0043) ----------------------------------------------

  # Kept in lockstep with Kazi.Providers.Static.formats/0.
  @static_formats ~w(dialyzer sarif)

  defp validate_static_cmd(config, id) do
    case Map.get(config, :cmd) do
      cmd when is_binary(cmd) and cmd != "" -> :ok
      _ -> {:error, "static predicate #{inspect(id)} requires a non-empty string \"cmd\""}
    end
  end

  defp validate_static_args(config, id) do
    case Map.get(config, :args) do
      nil ->
        :ok

      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1),
          do: :ok,
          else: {:error, "static predicate #{inspect(id)} \"args\" must be an array of strings"}

      _ ->
        {:error, "static predicate #{inspect(id)} \"args\" must be an array of strings"}
    end
  end

  defp validate_static_format(config, id) do
    case Map.get(config, :format) do
      nil ->
        :ok

      format when format in @static_formats ->
        :ok

      other ->
        {:error,
         "static predicate #{inspect(id)} has unknown format #{inspect(other)} " <>
           "(known: #{known_list(@static_formats)})"}
    end
  end

  # The baseline is OPTIONAL (absent = the zero-findings gate). When present it is
  # a number (a fixed finding budget), "stored"/"prior", or a non-empty git ref.
  defp validate_static_baseline(config, id) do
    case Map.get(config, :baseline) do
      nil ->
        :ok

      n when is_number(n) ->
        :ok

      s when is_binary(s) and s != "" ->
        :ok

      other ->
        {:error, "static predicate #{inspect(id)} \"baseline\" is invalid: #{inspect(other)}"}
    end
  end

  defp validate_static_timeout(config, id) do
    case Map.get(config, :timeout_ms) do
      nil -> :ok
      ms when is_integer(ms) and ms > 0 -> :ok
      _ -> {:error, "static predicate #{inspect(id)} \"timeout_ms\" must be a positive integer"}
    end
  end

  defp validate_static_allowed_regression(config, id) do
    case Map.get(config, :allowed_regression) do
      nil ->
        :ok

      n when is_number(n) ->
        :ok

      other ->
        {:error,
         "static predicate #{inspect(id)} \"allowed_regression\" must be a number " <>
           "(got #{inspect(other)})"}
    end
  end

  # --- cve (T32.8, ADR-0043) -------------------------------------------------

  @cve_tools ~w(govulncheck trivy grype npm_audit)
  @cve_manifest_tools ~w(trivy grype npm_audit)

  defp validate_cve_tool(config, id) do
    case Map.get(config, :tool, "govulncheck") do
      tool when tool in @cve_tools ->
        {:ok, tool}

      other ->
        {:error,
         "cve predicate #{inspect(id)} has unknown tool #{inspect(other)} " <>
           "(known: #{known_list(@cve_tools)})"}
    end
  end

  defp validate_cve_count_path(tool, config, id) when tool in @cve_manifest_tools do
    case Map.get(config, :count_path) do
      path when is_binary(path) and path != "" ->
        :ok

      _ ->
        {:error,
         "cve predicate #{inspect(id)} tool #{inspect(tool)} (manifest tier) requires a " <>
           "\"count_path\" to the vulnerability count it ratchets"}
    end
  end

  defp validate_cve_count_path(_tool, _config, _id), do: :ok

  # --- mutation (T32.8, ADR-0043) --------------------------------------------

  defp validate_mutation_threshold(config, id) do
    case Map.get(config, :threshold) do
      n when is_number(n) and n >= 0 and n < 1.0 ->
        :ok

      n when is_number(n) and n >= 1.0 ->
        {:error,
         "mutation predicate #{inspect(id)} \"threshold\" must be < 1.0 — a mutation gate is " <>
           "NEVER 100% (equivalent mutants make a perfect score unreachable; got #{inspect(n)})"}

      other ->
        {:error,
         "mutation predicate #{inspect(id)} requires a numeric \"threshold\" in [0, 1.0) " <>
           "(got #{inspect(other)})"}
    end
  end

  defp validate_mutation_score_config(config, id) do
    cond do
      is_binary(Map.get(config, :score_path)) ->
        :ok

      is_binary(Map.get(config, :killed_path)) and is_binary(Map.get(config, :survived_path)) ->
        :ok

      true ->
        {:error,
         "mutation predicate #{inspect(id)} needs a \"score_path\" OR both \"killed_path\" " <>
           "and \"survived_path\" to read the score"}
    end
  end

  # --- coverage (T32.8, ADR-0043) --------------------------------------------

  defp validate_coverage_patch(config, id) do
    if metric_with_cmd?(Map.get(config, :patch)) do
      :ok
    else
      {:error,
       "coverage predicate #{inspect(id)} requires a \"patch\" metric table with a " <>
         "non-empty string \"cmd\""}
    end
  end

  defp validate_coverage_target(config, id) do
    case Map.get(config, :target) do
      n when is_number(n) ->
        :ok

      _ ->
        {:error, "coverage predicate #{inspect(id)} requires a numeric \"target\""}
    end
  end

  # The project dimension is optional, but when present it must be a metric table
  # with a cmd (the same shape the patch metric uses).
  defp validate_coverage_project(config, id) do
    case Map.get(config, :project) do
      nil ->
        :ok

      project ->
        if metric_with_cmd?(project) do
          :ok
        else
          {:error,
           "coverage predicate #{inspect(id)} \"project\" must be a metric table with a " <>
             "non-empty string \"cmd\""}
        end
    end
  end

  # A metric inline table (string- or atom-keyed) declaring a non-empty `cmd`.
  defp metric_with_cmd?(metric) when is_map(metric) do
    case fetch_either(metric, "cmd") do
      cmd when is_binary(cmd) and cmd != "" -> true
      _ -> false
    end
  end

  defp metric_with_cmd?(_), do: false

  # --- ratchet (T32.3, ADR-0041) ---------------------------------------------

  # The metric is an inline table (string-keyed: the loader only atomizes
  # top-level predicate keys), and must declare a non-empty `cmd`.
  defp validate_ratchet_metric(config, id) do
    case Map.get(config, :metric) do
      metric when is_map(metric) ->
        case fetch_either(metric, "cmd") do
          cmd when is_binary(cmd) and cmd != "" ->
            :ok

          _ ->
            {:error,
             "ratchet predicate #{inspect(id)} requires a metric table with a non-empty " <>
               "string \"cmd\""}
        end

      _ ->
        {:error, "ratchet predicate #{inspect(id)} requires a \"metric\" table"}
    end
  end

  defp validate_ratchet_direction(config, id) do
    case Map.get(config, :direction) do
      direction when direction in ["higher_better", "lower_better"] ->
        :ok

      other ->
        {:error,
         "ratchet predicate #{inspect(id)} requires \"direction\" of " <>
           "\"higher_better\" or \"lower_better\" (got #{inspect(other)})"}
    end
  end

  # The baseline is a number (a fixed threshold), "stored"/"prior" (the stored
  # prior value), or a non-empty git ref string.
  defp validate_ratchet_baseline(config, id) do
    case Map.get(config, :baseline) do
      n when is_number(n) ->
        :ok

      s when is_binary(s) and s != "" ->
        :ok

      nil ->
        {:error, "ratchet predicate #{inspect(id)} requires a \"baseline\""}

      other ->
        {:error, "ratchet predicate #{inspect(id)} \"baseline\" is invalid: #{inspect(other)}"}
    end
  end

  defp validate_ratchet_allowed_regression(config, id) do
    case Map.get(config, :allowed_regression) do
      nil ->
        :ok

      n when is_number(n) ->
        :ok

      other ->
        {:error,
         "ratchet predicate #{inspect(id)} \"allowed_regression\" must be a number (got #{inspect(other)})"}
    end
  end

  # An inline-table value may arrive string- or atom-keyed depending on authoring;
  # read whichever is present.
  defp fetch_either(map, key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  # --- metrics (T32.10, ADR-0043) --------------------------------------------

  @metrics_pass_when_re ~r/^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$/

  defp validate_metrics_direction(config, id) do
    case Map.get(config, :direction) do
      nil ->
        :ok

      dir when dir in ["higher_better", "lower_better"] ->
        :ok

      other ->
        {:error,
         metrics_error(
           id,
           "has unknown direction #{inspect(other)} " <>
             "(known: \"higher_better\", \"lower_better\")"
         )}
    end
  end

  # A pass_when, when present, must be a well-formed "<op> <number>" comparison.
  # It is required for the scalar/quantile modes (checked in validate_metrics_mode)
  # but irrelevant to burn_rate; here we only reject a malformed one.
  defp validate_metrics_pass_when(config, id) do
    case Map.get(config, :pass_when) do
      nil ->
        :ok

      expr when is_binary(expr) ->
        if Regex.match?(@metrics_pass_when_re, expr),
          do: :ok,
          else:
            {:error,
             metrics_error(
               id,
               "has malformed pass_when #{inspect(expr)} " <>
                 "(expected \"<op> <number>\", op one of == != < <= > >=)"
             )}

      other ->
        {:error, metrics_error(id, "\"pass_when\" must be a string, got #{inspect(other)}")}
    end
  end

  defp validate_metrics_mode(config, id) do
    cond do
      Map.has_key?(config, :burn_rate) -> validate_metrics_burn_rate(config, id)
      Map.has_key?(config, :quantile) -> validate_metrics_quantile(config, id)
      true -> validate_metrics_scalar(config, id)
    end
  end

  defp validate_metrics_scalar(config, id) do
    with :ok <- require_metrics_query(config, id) do
      require_metrics_pass_when(config, id)
    end
  end

  defp validate_metrics_quantile(config, id) do
    case Map.get(config, :quantile) do
      q when is_number(q) and q >= 0 and q <= 1 ->
        with :ok <- require_metrics_query(config, id) do
          require_metrics_pass_when(config, id)
        end

      other ->
        {:error,
         metrics_error(id, "\"quantile\" must be a number in 0..1, got #{inspect(other)}")}
    end
  end

  defp validate_metrics_burn_rate(config, id) do
    case Map.get(config, :burn_rate) do
      %{} = spec ->
        cond do
          not (is_binary(spec["long"]) and spec["long"] != "") ->
            {:error, metrics_error(id, "burn_rate requires a non-empty string \"long\" query")}

          not (is_binary(spec["short"]) and spec["short"] != "") ->
            {:error, metrics_error(id, "burn_rate requires a non-empty string \"short\" query")}

          not is_number(spec["threshold"]) ->
            {:error, metrics_error(id, "burn_rate requires a numeric \"threshold\"")}

          true ->
            :ok
        end

      other ->
        {:error, metrics_error(id, "\"burn_rate\" must be a table, got #{inspect(other)}")}
    end
  end

  defp require_metrics_query(config, id) do
    case Map.get(config, :query) do
      q when is_binary(q) and q != "" -> :ok
      _ -> {:error, metrics_error(id, "requires a non-empty string \"query\"")}
    end
  end

  defp require_metrics_pass_when(config, id) do
    case Map.get(config, :pass_when) do
      expr when is_binary(expr) and expr != "" -> :ok
      _ -> {:error, metrics_error(id, "requires a \"pass_when\" comparison (e.g. \"<= 0.5\")")}
    end
  end

  defp metrics_error(id, detail), do: "metrics predicate #{inspect(id)} #{detail}"

  defp validate_custom_script_cmd(config, id) do
    case Map.get(config, :cmd) do
      cmd when is_binary(cmd) and cmd != "" -> :ok
      _ -> {:error, "custom_script predicate #{inspect(id)} requires a non-empty string \"cmd\""}
    end
  end

  defp validate_custom_script_verdict(config, id) do
    case Map.get(config, :verdict, "exit_zero") do
      verdict when verdict in @custom_script_verdicts ->
        {:ok, verdict}

      other ->
        {:error,
         "custom_script predicate #{inspect(id)} has unknown verdict #{inspect(other)} " <>
           "(known: #{known_list(@custom_script_verdicts)})"}
    end
  end

  defp validate_custom_script_args(config, id) do
    case Map.get(config, :args) do
      nil -> :ok
      args when is_list(args) -> if Enum.all?(args, &is_binary/1), do: :ok, else: bad_args(id)
      _ -> bad_args(id)
    end
  end

  defp bad_args(id),
    do: {:error, "custom_script predicate #{inspect(id)} \"args\" must be an array of strings"}

  defp validate_custom_script_error_codes(config, id) do
    case Map.get(config, :error_codes) do
      nil ->
        :ok

      codes when is_list(codes) ->
        if Enum.all?(codes, &is_integer/1), do: :ok, else: bad_codes(:error_codes, id)

      _ ->
        bad_codes(:error_codes, id)
    end
  end

  defp validate_custom_script_timeout(config, id) do
    case Map.get(config, :timeout_ms) do
      nil ->
        :ok

      ms when is_integer(ms) and ms > 0 ->
        :ok

      _ ->
        {:error,
         "custom_script predicate #{inspect(id)} \"timeout_ms\" must be a positive integer"}
    end
  end

  defp validate_custom_script_merge_stderr(config, id) do
    case Map.get(config, :merge_stderr) do
      nil ->
        :ok

      value when is_boolean(value) ->
        :ok

      _ ->
        {:error, "custom_script predicate #{inspect(id)} \"merge_stderr\" must be a boolean"}
    end
  end

  defp validate_custom_script_evidence_format(config, id) do
    case Map.get(config, :evidence_format) do
      nil ->
        :ok

      format when format in @custom_script_evidence_formats ->
        :ok

      other ->
        {:error,
         "custom_script predicate #{inspect(id)} has unknown evidence_format #{inspect(other)} " <>
           "(known: #{known_list(@custom_script_evidence_formats)})"}
    end
  end

  # The "json" verdict gates on parsed stdout, so it REQUIRES a `path` and a
  # well-formed `pass_when`; the "exit_code" verdict REQUIRES a non-empty
  # `pass_codes` list (which exit codes count as a pass). "exit_zero" needs no
  # extra keys.
  defp validate_custom_script_for_verdict("json", config, id) do
    with :ok <- require_string_key(config, :path, id),
         :ok <- require_string_key(config, :pass_when, id) do
      validate_pass_when(Map.get(config, :pass_when), id)
    end
  end

  defp validate_custom_script_for_verdict("exit_code", config, id) do
    with :ok <- validate_code_list(config, :pass_codes, id, required: true) do
      validate_code_list(config, :fail_codes, id, required: false)
    end
  end

  # The "match_count" verdict gates on a COUNT of output lines matching a regex, so
  # it REQUIRES a non-empty `match_regex` and a well-formed `pass_when`. (Regex
  # validity is checked at evaluation time — a bad pattern is an :error there, the
  # same as prod_log's `:invalid_regex`.)
  defp validate_custom_script_for_verdict("match_count", config, id) do
    with :ok <- require_match_count_key(config, :match_regex, id),
         :ok <- require_match_count_key(config, :pass_when, id) do
      validate_pass_when(Map.get(config, :pass_when), id)
    end
  end

  defp validate_custom_script_for_verdict(_verdict, _config, _id), do: :ok

  defp require_match_count_key(config, key, id) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        {:error,
         "custom_script predicate #{inspect(id)} with verdict \"match_count\" requires a " <>
           "non-empty string #{inspect(Atom.to_string(key))}"}
    end
  end

  defp require_string_key(config, key, id) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" ->
        :ok

      _ ->
        {:error,
         "custom_script predicate #{inspect(id)} with verdict \"json\" requires a non-empty " <>
           "string #{inspect(Atom.to_string(key))}"}
    end
  end

  defp validate_pass_when(expr, id) do
    if Regex.match?(~r/^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$/, expr) do
      :ok
    else
      {:error,
       "custom_script predicate #{inspect(id)} \"pass_when\" must be \"<op> <number>\" " <>
         "(op one of == != < <= > >=), got #{inspect(expr)}"}
    end
  end

  defp validate_code_list(config, key, id, required: required?) do
    case Map.get(config, key) do
      nil ->
        if required? do
          {:error,
           "custom_script predicate #{inspect(id)} with verdict \"exit_code\" requires a " <>
             "non-empty integer array #{inspect(Atom.to_string(key))}"}
        else
          :ok
        end

      [] when required? ->
        {:error,
         "custom_script predicate #{inspect(id)} \"#{key}\" must be a non-empty integer array"}

      codes when is_list(codes) ->
        if Enum.all?(codes, &is_integer/1), do: :ok, else: bad_codes(key, id)

      _ ->
        bad_codes(key, id)
    end
  end

  defp bad_codes(key, id),
    do: {:error, "custom_script predicate #{inspect(id)} \"#{key}\" must be an array of integers"}

  defp known_list(values), do: Enum.map_join(values, ", ", &inspect/1)

  defp optional_string(map, key, table) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{table}.#{key} must be a string"}
    end
  end

  defp optional_string_list(map, key, table) do
    case Map.get(map, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "#{table}.#{key} must be an array of strings"}
        end

      _ ->
        {:error, "#{table}.#{key} must be an array of strings"}
    end
  end

  defp known_providers do
    @provider_kinds |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end

  # T32.1b (ADR-0040 decision 7): emit a one-line deprecation hint to STDERR for
  # each DISTINCT deprecated command-runner provider the goal uses. Deduped so a
  # goal with many `test_runner` predicates warns once. Goes to `:stderr` only —
  # a `--json` caller reads JSON on stdout, which this never touches (the hard
  # requirement). Best-effort and side-effect-only: it never alters the load.
  defp warn_deprecated_providers(predicates) when is_list(predicates) do
    predicates
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, "provider"))
    |> Enum.uniq()
    |> Enum.each(fn provider ->
      case Map.fetch(@deprecated_providers, provider) do
        {:ok, replacement} ->
          IO.puts(
            :stderr,
            "kazi: provider #{inspect(provider)} is deprecated (ADR-0040) and will be removed " <>
              "in v2.0.0 — migrate to #{replacement}. See docs/deprecations.md."
          )

        :error ->
          :ok
      end
    end)
  end

  defp warn_deprecated_providers(_predicates), do: :ok

  # The declared group ids, sorted, for an unknown-reference error message. Empty
  # when no `[[group]]` was declared (so a stray `group =` on a predicate names
  # exactly that).
  defp known_groups(declared) do
    case Enum.sort(declared) do
      [] -> "none"
      ids -> Enum.map_join(ids, ", ", &inspect/1)
    end
  end

  defp known_modes do
    @goal_modes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end

  defp known_harnesses do
    Registry.ids()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.map_join(", ", &inspect/1)
  end
end
