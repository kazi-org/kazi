defmodule Kazi.PredicateResult do
  @moduledoc """
  The outcome of evaluating one `Kazi.Predicate`: a `{status, evidence}` pair
  (ADR-0002).

  ADR-0002 defines a provider as returning `{pass | fail, evidence}`. This struct
  widens `status` to also cover the two states a real controller must
  distinguish from a genuine `fail`:

    * `:error`   — the provider itself could not run (binary missing, network
      down, malformed config). This is *not* failing work for the agent to fix;
      conflating it with `:fail` would dispatch an agent against an infra
      problem.
    * `:unknown` — not yet evaluated, or deliberately not evaluated this
      iteration (e.g. quarantined as flaky — concept §5). Carries no claim about
      the predicate.

  Only `:pass` counts toward convergence; `:fail` is real work; `:error` and
  `:unknown` are neither pass nor actionable failing work. The controller — not
  the agent — interprets these (concept §5).

  `evidence` is the *proof*: enough structured data to (a) justify the status and
  (b) seed a fixer agent's context (ADR-0002 consequences). It is provider-shaped
  (exit code + output for `:tests`; HTTP status + body for `:http_probe`) and
  carried as a map.

  ## Envelope v2 — graded score, direction, and structured evidence (ADR-0041)

  Boolean `{status, evidence}` is a *sparse* signal: it tells the agent WHETHER it
  is done, not whether the last edit moved CLOSER. ADR-0041 enriches the result
  envelope — **additively** — with four optional fields a checker may populate:

    * `score` — an optional float the checker already computes (47/50 tests,
      mutation 0.82, coverage 81%, an axe violation count). `nil` for an honestly
      boolean predicate (a secret either leaked or it didn't).
    * `direction` — `:higher_better | :lower_better`, so the controller reads which
      way is progress WITHOUT hardcoding per-provider knowledge (a mutation score
      is higher-better; a lint-finding count is lower-better). `nil` when there is
      no score to interpret.
    * `prior_score` — the same predicate's `score` from the previous iteration,
      threaded IN by the loop (not the provider) so the controller can read the
      direction-interpreted delta (`score_delta/1`, `progressed?/1`).
    * `evidence_items` — a list of LSP-`Diagnostic`-shaped items
      (`Kazi.Evidence.item/1`: `{file, line, col, rule, level, message, expected,
      got}`) providers map SARIF / JUnit-XML / counterexample data onto. Far better
      fix-context than 5KB of raw stdout, which is kept only as a truncated
      fallback in `evidence`.

  The score feeds **progress detection only** (the stuck-detector T1.5 and the
  ADR-0035 skill escalation), NEVER the convergence gate: `:converged` still
  requires every predicate `:pass` (the objective-termination guard, ADR-0002 /
  T0.8, is untouched). A score that improves but has not crossed its threshold is
  "progressing," not "done."

  All four fields default such that a **boolean predicate** (`score = nil`,
  `direction = nil`, `prior_score = nil`, `evidence_items = []`) is byte-identical
  to a pre-v2 result — both in memory and in its read-model serialization — so
  every existing provider and caller is unchanged.
  """

  @typedoc """
  The evaluation status.

    * `:pass`    — the predicate holds; counts toward convergence.
    * `:fail`    — the predicate does not hold; this is the work-list.
    * `:error`   — the provider could not evaluate (infra/config problem).
    * `:unknown` — not (yet) evaluated; carries no claim.
  """
  @type status :: :pass | :fail | :error | :unknown

  @typedoc """
  Structured proof for the status, shaped by the provider. Examples: `%{exit:
  0, output: "...", duration_ms: 1200}` for a test run; `%{http_status: 200,
  body: "...", url: "..."}` for an http probe.
  """
  @type evidence :: map()

  @typedoc """
  Which direction of `score` movement is progress (ADR-0041). `:higher_better`
  for a metric like a mutation/coverage score; `:lower_better` for a count like
  lint findings or bundle size. `nil` when there is no score to interpret.
  """
  @type direction :: :higher_better | :lower_better

  @typedoc """
  One LSP-`Diagnostic`-shaped evidence item (`Kazi.Evidence.item/1`): a localized,
  actionable finding a fixer agent can act on directly, far better than raw
  stdout. All keys optional/`nil`able.
  """
  @type evidence_item :: %{
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          col: non_neg_integer() | nil,
          rule: String.t() | nil,
          level: String.t() | nil,
          message: String.t() | nil,
          expected: term(),
          got: term()
        }

  @type t :: %__MODULE__{
          status: status(),
          evidence: evidence(),
          score: float() | nil,
          direction: direction() | nil,
          prior_score: float() | nil,
          evidence_items: [evidence_item()]
        }

  @enforce_keys [:status]
  defstruct status: nil,
            evidence: %{},
            # ADR-0041 envelope v2 — all default to the boolean shape so a pre-v2
            # result is byte-identical (in memory and serialized). Appended last so
            # the existing field order / positional construction is untouched.
            score: nil,
            direction: nil,
            prior_score: nil,
            evidence_items: []

  @valid_statuses [:pass, :fail, :error, :unknown]
  @valid_directions [:higher_better, :lower_better]

  @doc "The list of valid statuses, in convergence-relevance order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @valid_statuses

  @doc """
  Builds a result with the given `status`, optional `evidence`, and optional
  envelope-v2 fields (ADR-0041) supplied as `opts`.

  `status` must be one of #{inspect(@valid_statuses)}; any other value raises
  `FunctionClauseError` (the guard rejects it).

  `opts` (all optional — omitting them yields the byte-identical boolean shape):

    * `:score` — the checker's scalar (float | integer | nil).
    * `:direction` — `:higher_better | :lower_better` (or `nil`); any other value
      raises `ArgumentError`.
    * `:prior_score` — usually threaded by the loop, not the provider.
    * `:evidence_items` — a list of `t:evidence_item/0` (normalized via
      `Kazi.Evidence.item/1`).

  ## Examples

      iex> Kazi.PredicateResult.new(:pass, %{exit: 0}).status
      :pass

      iex> Kazi.PredicateResult.new(:fail).evidence
      %{}

      iex> Kazi.PredicateResult.new(:fail, %{}, score: 40.0, direction: :lower_better).score
      40.0
  """
  @spec new(status(), evidence(), keyword()) :: t()
  def new(status, evidence \\ %{}, opts \\ [])
      when status in @valid_statuses and is_map(evidence) and is_list(opts) do
    %__MODULE__{
      status: status,
      evidence: evidence,
      score: Keyword.get(opts, :score),
      direction: validate_direction(Keyword.get(opts, :direction)),
      prior_score: Keyword.get(opts, :prior_score),
      evidence_items: List.wrap(Keyword.get(opts, :evidence_items, []))
    }
  end

  # A direction must be one of the two valid atoms, or nil (no score to interpret).
  # Anything else is a programming error — reject it loudly rather than silently
  # storing a meaningless direction the controller would misread.
  defp validate_direction(nil), do: nil
  defp validate_direction(dir) when dir in @valid_directions, do: dir

  defp validate_direction(other) do
    raise ArgumentError,
          "direction must be one of #{inspect(@valid_directions)} or nil, got: #{inspect(other)}"
  end

  @doc "Convenience constructor for a passing result."
  @spec pass(evidence()) :: t()
  def pass(evidence \\ %{}), do: new(:pass, evidence)

  @doc "Convenience constructor for a failing result."
  @spec fail(evidence()) :: t()
  def fail(evidence \\ %{}), do: new(:fail, evidence)

  @doc "Convenience constructor for a provider-error result."
  @spec error(evidence()) :: t()
  def error(evidence \\ %{}), do: new(:error, evidence)

  @doc "Convenience constructor for an unknown/unevaluated result."
  @spec unknown(evidence()) :: t()
  def unknown(evidence \\ %{}), do: new(:unknown, evidence)

  @doc """
  Returns true only when the status is `:pass`. Used to decide whether a single
  predicate contributes to convergence.

  ## Examples

      iex> Kazi.PredicateResult.passed?(Kazi.PredicateResult.pass())
      true

      iex> Kazi.PredicateResult.passed?(Kazi.PredicateResult.error())
      false
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: :pass}), do: true
  def passed?(%__MODULE__{}), do: false

  @doc """
  Threads a `prior_score` onto a result — the same predicate's `score` from the
  previous iteration. The LOOP calls this (not the provider): a provider has no
  memory of last iteration, so the controller carries the prior in so the
  direction-interpreted delta (`score_delta/1`, `progressed?/1`) can be read
  (ADR-0041). A boolean result (`score: nil`) is unaffected by a `nil` prior.
  """
  @spec with_prior_score(t(), float() | nil) :: t()
  def with_prior_score(%__MODULE__{} = result, prior) when is_number(prior) or is_nil(prior) do
    %{result | prior_score: prior}
  end

  @doc """
  The **direction-interpreted** score delta: a positive number means the score
  moved in the *progress* direction since `prior_score`, negative means it
  regressed, `0.0` means no change. `nil` when the delta cannot be read — there is
  no `score`, no `prior_score`, or no `direction` to interpret (so a boolean
  predicate always yields `nil`).

  For `:higher_better` it is `score - prior_score`; for `:lower_better` it is
  `prior_score - score`. This is the single signal the progress classifier and the
  stuck-detector (T1.5) read, so neither needs per-provider knowledge of which way
  is up.

  ## Examples

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 40.0, direction: :lower_better)
      iex> Kazi.PredicateResult.score_delta(Kazi.PredicateResult.with_prior_score(r, 50.0))
      10.0

      iex> Kazi.PredicateResult.score_delta(Kazi.PredicateResult.fail())
      nil
  """
  @spec score_delta(t()) :: number() | nil
  def score_delta(%__MODULE__{score: score, prior_score: prior, direction: :higher_better})
      when is_number(score) and is_number(prior),
      do: score - prior

  def score_delta(%__MODULE__{score: score, prior_score: prior, direction: :lower_better})
      when is_number(score) and is_number(prior),
      do: prior - score

  def score_delta(%__MODULE__{}), do: nil

  @doc """
  Returns true iff this result made **direction-interpreted progress** since the
  previous iteration — its `score_delta/1` is strictly positive. A boolean
  predicate, a first observation (no `prior_score`), or a flat/regressed score is
  not progress. Used by the stuck-detector (T1.5) and the ADR-0035 escalation to
  tell "slow progress" from "stuck" WITHOUT touching the `:converged` gate.

  ## Examples

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 40.0, direction: :lower_better)
      iex> Kazi.PredicateResult.progressed?(Kazi.PredicateResult.with_prior_score(r, 50.0))
      true

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 50.0, direction: :lower_better)
      iex> Kazi.PredicateResult.progressed?(Kazi.PredicateResult.with_prior_score(r, 50.0))
      false
  """
  @spec progressed?(t()) :: boolean()
  def progressed?(%__MODULE__{} = result) do
    case score_delta(result) do
      delta when is_number(delta) -> delta > 0
      nil -> false
    end
  end
end
