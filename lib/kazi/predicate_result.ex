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

  ## Envelope v2 — graded score + structured evidence (ADR-0041)

  ADR-0041 enriches the result with FOUR optional fields, every one defaulting so
  a boolean predicate is byte-identical to today (`score`/`prior_score`/`direction`
  `nil`, `diagnostics` empty):

    * `score`       — an optional float the provider already computes (47/50 tests,
      mutation 0.82, an axe-violation count). A flat pass/fail is a sparse reward;
      the score is the dense gradient that tells the controller whether the last
      edit moved CLOSER, not just whether it is done.
    * `direction`   — `:higher_better | :lower_better`, so the controller reads
      progress WITHOUT per-provider knowledge (mutation score is higher-better; a
      lint-finding count is lower-better).
    * `prior_score` — the same predicate's `score` from the previous iteration,
      THREADED IN BY THE LOOP (`Kazi.Loop`), not the provider. With `direction` it
      yields the interpreted delta the progress classifier and stuck-detector
      (T1.5) consume.
    * `diagnostics` — a list of `Kazi.Evidence` items (LSP-`Diagnostic`-shaped:
      `{file, line, col, rule, level, message, expected, got}`). Localized,
      minimal fix-context; raw stdout stays in `evidence` only as a truncated
      fallback.

  **The score never moves the convergence gate.** `:converged` still requires the
  whole vector `:pass` (ADR-0002 / T0.8). The score delta is a SIGNAL for progress
  classification only — a score that improves but has not crossed the threshold is
  "progressing," not "done."
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
  Which way the score improves: `:higher_better` (mutation score, coverage) or
  `:lower_better` (lint-finding count, p95 latency). `nil` for a boolean result.
  """
  @type direction :: :higher_better | :lower_better | nil

  @type t :: %__MODULE__{
          status: status(),
          evidence: evidence(),
          score: float() | nil,
          direction: direction(),
          prior_score: float() | nil,
          diagnostics: [Kazi.Evidence.t()]
        }

  @enforce_keys [:status]
  defstruct status: nil,
            evidence: %{},
            # ADR-0041 envelope v2 — all optional; these defaults make a boolean
            # predicate byte-identical to the pre-v2 struct.
            score: nil,
            direction: nil,
            prior_score: nil,
            diagnostics: []

  @valid_statuses [:pass, :fail, :error, :unknown]
  @valid_directions [:higher_better, :lower_better]

  @doc "The list of valid statuses, in convergence-relevance order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @valid_statuses

  @doc """
  Builds a result with the given `status`, optional `evidence`, and optional
  envelope-v2 `opts` (ADR-0041).

  `status` must be one of #{inspect(@valid_statuses)}; any other value raises
  `FunctionClauseError` (the guard rejects it).

  `opts` may carry `:score` (a float or nil), `:direction`
  (`:higher_better | :lower_better`), `:prior_score` (a float or nil), and
  `:diagnostics` (a list of `Kazi.Evidence` items). Omitted, every field defaults
  to its boolean value — so `new/2` is byte-identical to the pre-v2 constructor.

  ## Examples

      iex> Kazi.PredicateResult.new(:pass, %{exit: 0}).status
      :pass

      iex> Kazi.PredicateResult.new(:fail).evidence
      %{}

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 3.0, direction: :lower_better)
      iex> {r.score, r.direction}
      {3.0, :lower_better}
  """
  @spec new(status(), evidence(), keyword()) :: t()
  def new(status, evidence \\ %{}, opts \\ [])
      when status in @valid_statuses and is_map(evidence) and is_list(opts) do
    %__MODULE__{
      status: status,
      evidence: evidence,
      score: validate_score(Keyword.get(opts, :score)),
      direction: validate_direction(Keyword.get(opts, :direction)),
      prior_score: validate_score(Keyword.get(opts, :prior_score)),
      diagnostics: Keyword.get(opts, :diagnostics, [])
    }
  end

  defp validate_score(nil), do: nil
  defp validate_score(score) when is_float(score), do: score
  defp validate_score(score) when is_integer(score), do: score * 1.0

  defp validate_direction(nil), do: nil
  defp validate_direction(direction) when direction in @valid_directions, do: direction

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
  Returns true iff the result carries a graded `score` (envelope v2). A boolean
  result (`score == nil`) is false, so callers can branch the gradient path
  without touching the boolean one.

  ## Examples

      iex> Kazi.PredicateResult.scored?(Kazi.PredicateResult.new(:fail, %{}, score: 1.0))
      true

      iex> Kazi.PredicateResult.scored?(Kazi.PredicateResult.fail())
      false
  """
  @spec scored?(t()) :: boolean()
  def scored?(%__MODULE__{score: score}), do: is_number(score)

  @doc """
  Sets `prior_score` — the previous iteration's score for the same predicate —
  returning the updated result. `Kazi.Loop` calls this each observation to thread
  the prior score forward; the provider never does. A `nil` prior (no prior
  iteration, or a boolean predicate) leaves the result a boolean shape.

  ## Examples

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better)
      iex> Kazi.PredicateResult.with_prior_score(r, 8.0).prior_score
      8.0
  """
  @spec with_prior_score(t(), float() | nil) :: t()
  def with_prior_score(%__MODULE__{} = result, prior_score) do
    %{result | prior_score: validate_score(prior_score)}
  end

  @doc """
  The raw `score - prior_score` delta, or `nil` when either is absent. This is the
  un-interpreted delta; `progress/1` reads it through `direction`. A positive raw
  delta is NOT necessarily progress — for a `:lower_better` metric, going down (a
  negative raw delta) is the improvement.

  ## Examples

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better, prior_score: 8.0)
      iex> Kazi.PredicateResult.delta(r)
      -3.0
  """
  @spec delta(t()) :: float() | nil
  def delta(%__MODULE__{score: score, prior_score: prior})
      when is_number(score) and is_number(prior),
      do: score - prior

  def delta(%__MODULE__{}), do: nil

  @doc """
  Classifies the score movement THROUGH `direction` — the signal the progress
  classifier and stuck-detector (T1.5) consume (ADR-0041 decision 2):

    * `:progressed` — the score moved the improving way (up for `:higher_better`,
      down for `:lower_better`);
    * `:regressed`  — it moved the worsening way;
    * `:unchanged`  — the score held;
    * `:unknown`    — no score, no prior score, or no direction to interpret it.

  This NEVER moves the convergence gate; it is purely the gradient. A
  `:lower_better` count improving (going DOWN) registers as `:progressed`.

  ## Examples

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 5.0, direction: :lower_better, prior_score: 8.0)
      iex> Kazi.PredicateResult.progress(r)
      :progressed

      iex> r = Kazi.PredicateResult.new(:fail, %{}, score: 0.7, direction: :higher_better, prior_score: 0.9)
      iex> Kazi.PredicateResult.progress(r)
      :regressed

      iex> Kazi.PredicateResult.progress(Kazi.PredicateResult.fail())
      :unknown
  """
  @spec progress(t()) :: :progressed | :regressed | :unchanged | :unknown
  def progress(%__MODULE__{direction: direction} = result)
      when direction in @valid_directions do
    interpret(direction, delta(result))
  end

  def progress(%__MODULE__{}), do: :unknown

  defp interpret(_direction, nil), do: :unknown
  defp interpret(_direction, d) when d == 0, do: :unchanged
  defp interpret(:higher_better, d) when d > 0, do: :progressed
  defp interpret(:higher_better, _d), do: :regressed
  defp interpret(:lower_better, d) when d < 0, do: :progressed
  defp interpret(:lower_better, _d), do: :regressed
end
