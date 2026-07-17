defmodule Kazi.Goal do
  @moduledoc """
  A goal: declared desired state as a set of machine-checkable predicates
  (ADR-0002, concept §4).

  A goal is a *declarative document*. Its acceptance is the **conjunction of all
  its predicates** — "done" is `∀ p ∈ predicates: eval(p) = true`, decided by the
  controller with stored evidence, never by the agent's self-report (concept §1).

  A goal carries:

    * `mode` — `:repair` (default) or `:create`. In *repair* mode the predicates
      describe existing behavior that has regressed; in *create* mode (Slice 2,
      T2.1, concept §10) they are **acceptance criteria** for NEW behavior,
      authored to fail at t0 and pass once kazi builds the feature. The mode does
      not change the convergence machinery — failing predicates are the work-list
      either way — it records the author's intent so a create goal is
      self-describing and tooling (the vacuous-goal guard T2.3) can reason about
      it.
    * `predicates` — the desired-state predicates (`Kazi.Predicate`); the goal is
      met iff every one evaluates `:pass`. In create mode these are the acceptance
      criteria.
    * `guards` — guard predicates: invariants that must never regress (e.g.
      test-count must not drop, coverage must not fall below baseline). Guards are
      `Kazi.Predicate`s flagged `guard?: true`; they are enforced as invariants,
      not goals to reach (ADR-0002).
    * `budget` — the hard token / wall-clock / iteration ceiling
      (`Kazi.Budget`).
    * `scope` — the repo and paths agents may touch (`Kazi.Scope`).
    * `standing` — whether this goal is a STANDING (continuous/maintenance)
      reconciler (T3.4d, UC-016). When `true` the loop does NOT terminate at
      convergence; it keeps re-observing on a bounded interval to hold the goal's
      predicates true forever (concept §10 "standing reconcilers"). Default
      `false` (a one-shot converge-and-stop goal). Like `mode`, this is authoring
      intent recorded on the goal — the loop's standing behaviour itself is
      T3.4a; here the goal just *declares* it so it can be authored in a
      goal-file and threaded into the loop opts by `Kazi.Runtime`.
    * `harness` — the goal's harness selection (T8.6, ADR-0016): which coding
      harness this goal prefers to be driven by, declared in the goal-file's
      `[harness]` table. A plain map `%{id: atom|nil, model: String.t()|nil,
      command: String.t()|nil, effort: String.t()|nil, permission_mode:
      String.t()|nil, allowed_tools: [String.t()]|nil}` — `id` is the harness id
      (e.g. `:opencode`), `model` an optional provider/model override, `command` an
      optional binary override, `effort` an optional Claude-only reasoning-effort
      level (`--effort`, T36.6), `permission_mode` an optional Claude-only
      permission mode (`--permission-mode`, issue #769), `allowed_tools` an
      optional Claude-only tool allow-list (`--allowed-tools`, issue #769).
      Default `nil` (no goal-level preference; resolution falls through to
      config/default, ADR-0016). Like `mode`/`standing`, this is authoring
      intent recorded on the goal; threading the loaded `id` into
      `Kazi.Harness.resolve/1` as `:goal_harness` is T8.7.
    * `groups` — the goal's declared **group taxonomy** (T12.1, ADR-0020): a list
      of `Kazi.Goal.Group` parsed from the goal-file's `[[group]]` array, by which
      a large goal organizes its predicates into a tree (pillar → domain →
      capability). Each group is `{id, name, parent?, budget?}` with a normalized
      slug `id`. Default `[]` (no taxonomy; an ungrouped goal behaves exactly as
      before). Like `harness`/`standing`, this is appended additively so the
      existing field order is untouched. Predicates referencing a group, and
      parent reference / cycle validation, are a separate task (T12.2).
    * `debrief` — opt-in post-dispatch debrief capture (T48.11, ADR-0058 §3
      "self-report" tier), declared in the goal-file's `[economy]` table. When
      `true`, each dispatch prompt carries one capped debrief question and any
      structured answer the agent gives is persisted as HYPOTHESIS rows in the
      read-model — the answer never mutates a future prompt (the gaming-surface
      rule, cf. T32.5). Default `false` (byte-identical to today).
    * `memory_corpus` — the semantic-recall corpus override (ADR-0062 decision
      1), declared in the goal-file's `[memory]` table's `corpus` key: a list
      of glob patterns (relative to the workspace) `Kazi.Memory.SemanticIndex`
      indexes instead of its own built-in default corpus. `nil` (the default)
      means "use the default corpus"; an explicit `[]` opts the goal OUT of
      recall entirely (zero recall, zero cost).
    * `integration` — how converged work LANDS (T44.1, ADR-0055), declared in
      the goal-file's `[integration]` table. A map `%{mode:, branch_prefix:,
      base:, commit_style:}` — `mode` is `:commit | :branch | :pr | :merge |
      :none`, `branch_prefix`/`base`/`commit_style` are optional strings applied
      by the landing machinery (T44.2+). Default `default_integration/0` (mode
      `:none` — converge-and-stop, no landing). `mode: :none` and an ABSENT
      `[integration]` block yield the IDENTICAL default map, so a `:none` goal is
      byte-identical to a goal-file with no block. This task parses/validates/
      exposes the block only; the synthesized `landed` predicate and the
      landing actions are later tasks (T44.2, T44.3).

  In Slice 0 a goal is loaded from a TOML goal-file (T0.4); this struct is the
  in-memory shape every later component (loader, loop T0.7, actions, read-model
  T0.9) builds against.
  """

  alias Kazi.{Budget, Predicate, Scope}
  alias Kazi.Goal.Group

  @typedoc "Stable identifier for a goal."
  @type id :: String.t() | atom()

  @typedoc """
  How the goal's predicates are intended. `:repair` (default) — predicates
  describe existing behavior that has regressed. `:create` — predicates are
  acceptance criteria for NEW behavior, authored to fail at t0 (T2.1).
  """
  @type mode :: :repair | :create

  @typedoc """
  A goal's harness selection (T8.6, ADR-0016): the harness `id` it prefers,
  plus optional `model`/`command`/`effort`/`permission_mode`/`allowed_tools`
  overrides. Any field may be `nil`.
  """
  @type harness :: %{
          id: atom() | nil,
          model: String.t() | nil,
          command: String.t() | nil,
          effort: String.t() | nil,
          permission_mode: String.t() | nil,
          allowed_tools: [String.t()] | nil
        }

  @typedoc """
  How a converged goal LANDS (T44.1, ADR-0055): the `mode` plus optional
  `branch_prefix`/`base`/`commit_style` from the goal-file's `[integration]`
  table. `mode: :none` (the default) means converge-and-stop with no landing.
  """
  @type integration :: %{
          mode: :commit | :branch | :pr | :merge | :none,
          branch_prefix: String.t() | nil,
          base: String.t() | nil,
          commit_style: String.t() | nil
        }

  # T44.1 (ADR-0055): the default `[integration]` block — mode :none, no landing.
  # An ABSENT block and an explicit `mode = "none"` both resolve to THIS exact
  # map, so a :none goal is byte-identical to a goal-file with no block at all.
  @default_integration %{mode: :none, branch_prefix: nil, base: nil, commit_style: nil}

  @type t :: %__MODULE__{
          id: id(),
          name: String.t() | nil,
          description: String.t() | nil,
          mode: mode(),
          predicates: [Predicate.t()],
          guards: [Predicate.t()],
          budget: Budget.t(),
          scope: Scope.t(),
          standing: boolean(),
          harness: harness() | nil,
          groups: [Group.t()],
          enforcement: Kazi.Enforcement.t() | nil,
          debrief: boolean(),
          memory_corpus: [String.t()] | nil,
          integration: integration(),
          metadata: map()
        }

  @enforce_keys [:id]
  defstruct id: nil,
            name: nil,
            # Optional one-line human summary of the goal ("what is being
            # worked on"), surfaced by the dashboard drill-in panel.
            description: nil,
            mode: :repair,
            predicates: [],
            guards: [],
            budget: %Budget{},
            scope: %Scope{},
            # T3.4d standing wiring: declared standing/maintenance mode (UC-016).
            # Default false = one-shot converge-and-stop. Appended last so the
            # existing field order is untouched.
            standing: false,
            # T8.6 harness selection (ADR-0016): the goal's preferred harness as
            # a `%{id:, model:, command:}` map, authored in the goal-file's
            # `[harness]` table. Default nil = no goal-level preference. Appended
            # additively so the existing field order is untouched.
            harness: nil,
            # T12.1 group taxonomy (ADR-0020): the declared `[[group]]` set by
            # which a large goal organizes predicates into a tree. Default [] =
            # no taxonomy (ungrouped goal, fully backward-compatible). Appended
            # additively so the existing field order is untouched.
            groups: [],
            # T32.4 anti-gaming enforcement (ADR-0042): the goal's authored
            # enforcement profile (`Kazi.Enforcement`) from the goal-file's
            # `[enforcement]` table, or nil = unspecified (the default-on for
            # creation / opt-in for repair policy is then resolved by
            # `Kazi.Enforcement.resolve/1`). Appended additively so the existing
            # field order is untouched.
            enforcement: nil,
            # T48.11 (ADR-0058 §3): opt-in post-dispatch debrief capture, declared
            # in the goal-file's `[economy]` table. Default false = byte-identical
            # to today (no debrief question, no hypothesis rows). Appended
            # additively so the existing field order is untouched.
            debrief: false,
            # ADR-0062: the declared `[memory] corpus` override. Default nil =
            # use `Kazi.Memory.SemanticIndex.default_corpus/0`. Appended
            # additively so the existing field order is untouched.
            memory_corpus: nil,
            # T44.1 (ADR-0055): the declared `[integration]` landing block.
            # Default = the mode-:none map (converge-and-stop, no landing), the
            # SAME value an absent block resolves to. Appended additively so the
            # existing field order is untouched.
            integration: @default_integration,
            metadata: %{}

  @doc """
  Builds a goal.

  `id` is required. Optional opts: `:name`, `:mode`, `:predicates`, `:guards`,
  `:budget`, `:scope`, `:standing`, `:harness`, `:groups`, `:enforcement`,
  `:metadata`. `:enforcement` (default `nil`) is the goal's authored
  `Kazi.Enforcement` anti-gaming profile (T32.4, ADR-0042); when unset the
  default-on-for-creation policy is resolved at run time. `:mode`
  is `:repair` (default) or `:create` (creation mode — predicates are acceptance
  criteria, T2.1). `:standing` (default `false`) declares a standing/maintenance
  goal (T3.4d, UC-016). `:harness` (default `nil`) is the goal's harness
  selection map (T8.6, ADR-0016). `:groups` (default `[]`) is the declared group
  taxonomy (`Kazi.Goal.Group` list, T12.1, ADR-0020). `:debrief` (default
  `false`) opts into post-dispatch debrief capture (T48.11, ADR-0058 §3).
  `:memory_corpus` (default `nil`) overrides the semantic-recall corpus
  (ADR-0062); `nil` means "use the built-in default corpus". `:integration`
  (default `default_integration/0`, mode `:none`) is the goal's `[integration]`
  landing block (T44.1, ADR-0055).
  `:budget` and `:scope` accept either a struct or a keyword list (forwarded to
  `Kazi.Budget.new/1` / `Kazi.Scope.new/1`).

  ## Examples

      iex> g = Kazi.Goal.new("ship-it",
      ...>   predicates: [Kazi.Predicate.new(:unit, :tests)],
      ...>   budget: [max_iterations: 5])
      iex> {g.id, g.mode, length(g.predicates), g.budget.max_iterations}
      {"ship-it", :repair, 1, 5}

      iex> Kazi.Goal.new("build-widgets", mode: :create).mode
      :create

      iex> Kazi.Goal.new("keep-it-green", standing: true).standing
      true
  """
  @spec new(id(), keyword()) :: t()
  def new(id, opts \\ []) when not is_nil(id) do
    %__MODULE__{
      id: id,
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      mode: Keyword.get(opts, :mode, :repair),
      predicates: Keyword.get(opts, :predicates, []),
      guards: Keyword.get(opts, :guards, []),
      budget: opts |> Keyword.get(:budget, %Budget{}) |> to_budget(),
      scope: opts |> Keyword.get(:scope, %Scope{}) |> to_scope(),
      # T3.4d standing wiring: declared standing/maintenance mode (UC-016).
      standing: Keyword.get(opts, :standing, false),
      # T8.6 harness selection (ADR-0016): the goal's preferred harness map.
      harness: Keyword.get(opts, :harness),
      # T12.1 group taxonomy (ADR-0020): the declared `[[group]]` set.
      groups: Keyword.get(opts, :groups, []),
      # T32.4 anti-gaming enforcement (ADR-0042): the authored enforcement profile.
      enforcement: Keyword.get(opts, :enforcement),
      # T48.11 (ADR-0058 §3): opt-in post-dispatch debrief capture.
      debrief: Keyword.get(opts, :debrief, false),
      # ADR-0062: the declared `[memory] corpus` override.
      memory_corpus: Keyword.get(opts, :memory_corpus),
      # T44.1 (ADR-0055): the declared `[integration]` landing block.
      integration: Keyword.get(opts, :integration, @default_integration),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  The default `[integration]` landing block (T44.1, ADR-0055): mode `:none` with
  no `branch_prefix`/`base`/`commit_style` — converge-and-stop, no landing.

  An ABSENT `[integration]` goal-file block and an explicit `mode = "none"` both
  resolve to this EXACT map, so a `:none` goal is byte-identical to a goal-file
  with no block. Exposed as the single source of truth the loader shares.

  ## Examples

      iex> Kazi.Goal.default_integration()
      %{mode: :none, branch_prefix: nil, base: nil, commit_style: nil}

      iex> Kazi.Goal.new("g").integration
      %{mode: :none, branch_prefix: nil, base: nil, commit_style: nil}
  """
  @spec default_integration() :: integration()
  def default_integration, do: @default_integration

  @doc """
  Returns all predicates the controller observes each iteration — the goal's
  `predicates` followed by its `guards`. Both are evaluated every observation;
  the distinction is in how the loop *interprets* a failure (a failing predicate
  is work; a failing guard is a blocked/gamed state).

  ## Examples

      iex> g = Kazi.Goal.new("g",
      ...>   predicates: [Kazi.Predicate.new(:unit, :tests)],
      ...>   guards: [Kazi.Predicate.new(:cov, :coverage, guard?: true)])
      iex> g |> Kazi.Goal.all_predicates() |> Enum.map(& &1.id)
      [:unit, :cov]
  """
  @spec all_predicates(t()) :: [Predicate.t()]
  def all_predicates(%__MODULE__{predicates: predicates, guards: guards}) do
    predicates ++ guards
  end

  @doc """
  Returns true if the goal is in creation mode — its predicates are acceptance
  criteria for new behavior, authored to fail at t0 (T2.1, concept §10 Slice 2).

  ## Examples

      iex> Kazi.Goal.create?(Kazi.Goal.new("g", mode: :create))
      true

      iex> Kazi.Goal.create?(Kazi.Goal.new("g"))
      false
  """
  @spec create?(t()) :: boolean()
  def create?(%__MODULE__{mode: :create}), do: true
  def create?(%__MODULE__{}), do: false

  @doc """
  Returns true if the goal is a STANDING (continuous/maintenance) reconciler
  (T3.4d, UC-016) — the loop holds its predicates true forever rather than
  converging and stopping.

  ## Examples

      iex> Kazi.Goal.standing?(Kazi.Goal.new("g", standing: true))
      true

      iex> Kazi.Goal.standing?(Kazi.Goal.new("g"))
      false
  """
  @spec standing?(t()) :: boolean()
  def standing?(%__MODULE__{standing: standing}), do: standing == true

  @doc """
  Returns the goal's acceptance predicates — the ordinary (non-guard) predicates
  marked `acceptance?: true`. In a create-mode goal these are the failing-at-t0
  criteria the loop drives the agent to satisfy (T2.1).

  ## Examples

      iex> g = Kazi.Goal.new("g", mode: :create,
      ...>   predicates: [Kazi.Predicate.new(:widgets, :http_probe, acceptance?: true),
      ...>                Kazi.Predicate.new(:health, :http_probe)])
      iex> g |> Kazi.Goal.acceptance_predicates() |> Enum.map(& &1.id)
      [:widgets]
  """
  @spec acceptance_predicates(t()) :: [Predicate.t()]
  def acceptance_predicates(%__MODULE__{predicates: predicates}) do
    Enum.filter(predicates, &Predicate.acceptance?/1)
  end

  defp to_budget(%Budget{} = budget), do: budget
  defp to_budget(opts) when is_list(opts), do: Budget.new(opts)

  defp to_scope(%Scope{} = scope), do: scope
  defp to_scope(opts) when is_list(opts), do: Scope.new(opts)
end
