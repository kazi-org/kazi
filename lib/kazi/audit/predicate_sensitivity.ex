defmodule Kazi.Audit.PredicateSensitivity do
  @moduledoc """
  The **sampled predicate mutation audit** (T68.9, issue #1501):
  verification-of-verification for a CONVERGED goal.

  The red-at-t0 rule prevents *vacuous* predicates (a predicate that was never
  red proves nothing) but not *gamed* ones — a predicate driven green by
  stubbing the value, hard-coding a fixture, or deleting the failing path. Such a
  predicate stays green even when the behavior it claims to test is sabotaged.

  This audit measures exactly that. After a goal converges (every predicate
  `:pass`), it re-evaluates the SAME predicate set against a deliberately
  MUTATED workspace (revert the key hunk, inject a fault) and asks: how many of
  the converged predicates went red again? A predicate that flips is genuinely
  CONSTRAINING the implementation; one that stays green under sabotage is not
  testing the behavior it claims.

    * `constrained` (the "killed" count) — converged predicates that flipped to
      non-`:pass` under the mutation. Higher is better.
    * `survived` — converged predicates that stayed `:pass` despite the sabotage.
      These are the actionable evidence: a survivor is a weak or gamed predicate.
    * `sensitivity` = `constrained / tested`, a 0.0–1.0 estimate of how much the
      predicate set actually constrains the workspace.

  This is DISTINCT from the `:mutation` predicate provider
  (`Kazi.Providers.Mutation`), which mutates the SYSTEM UNDER TEST to score a
  test SUITE's strength. Here the target is the PREDICATE SET's sensitivity, run
  as a post-convergence audit — the mutation is applied to the workspace and the
  predicates (not a test suite) are the thing being graded.

  ## Sampling

  The audit is expensive (a full re-evaluation), so it is meant to run at a
  SAMPLE rate, not every convergence. `should_sample?/2` is a deterministic gate
  (no clock, no RNG state) keyed on a stable string — the same key + rate always
  decides the same way, so a periodic caller passing e.g. the goal-ref plus a
  run counter samples a reproducible ~`rate` fraction of convergences.

  ## Seam

  `audit/2` is pure over an injected re-evaluation function, so the whole audit
  is testable without git, a harness, or the network: the caller supplies the
  converged (baseline) vector and a `reevaluate` function that mutates the
  workspace and returns the re-evaluated vector.
  """

  alias Kazi.PredicateVector

  @typedoc """
  A sensitivity summary. `tested` is the number of converged (baseline-passing)
  predicates the audit could sabotage; `sensitivity` is `constrained / tested`
  (nil when `tested == 0` — nothing converged to audit). `survivors` lists the
  ids that stayed green under the mutation (the weak/gamed predicates).
  """
  @type t :: %{
          tested: non_neg_integer(),
          constrained: non_neg_integer(),
          survived: non_neg_integer(),
          sensitivity: float() | nil,
          survivors: [Kazi.Predicate.id()]
        }

  @doc """
  Scores predicate sensitivity from a baseline (converged) vector and the vector
  re-evaluated against the mutated workspace.

  Only predicates that were `:pass` in `baseline` are audited — a predicate that
  was not green at convergence is not part of the "did convergence actually
  constrain anything" question. Of those, the ones that are no longer `:pass` in
  `mutated` are CONSTRAINED (the sabotage was caught); the ones still `:pass` are
  SURVIVORS.

  ## Examples

      iex> pass = Kazi.PredicateResult.pass()
      iex> fail = Kazi.PredicateResult.fail()
      iex> baseline = Kazi.PredicateVector.new(%{a: pass, b: pass, c: pass})
      iex> mutated = Kazi.PredicateVector.new(%{a: fail, b: pass, c: fail})
      iex> Kazi.Audit.PredicateSensitivity.score(baseline, mutated)
      %{tested: 3, constrained: 2, survived: 1, sensitivity: 2 / 3, survivors: [:b]}
  """
  @spec score(PredicateVector.t(), PredicateVector.t()) :: t()
  def score(%PredicateVector{} = baseline, %PredicateVector{} = mutated) do
    converged = PredicateVector.passing(baseline)
    tested = length(converged)

    survivors =
      Enum.filter(converged, fn id ->
        case PredicateVector.get(mutated, id) do
          nil -> false
          result -> Kazi.PredicateResult.passed?(result)
        end
      end)

    survived = length(survivors)
    constrained = tested - survived

    %{
      tested: tested,
      constrained: constrained,
      survived: survived,
      sensitivity: sensitivity(constrained, tested),
      survivors: Enum.sort(survivors)
    }
  end

  @doc """
  Runs the audit: takes the converged `baseline` vector and a `reevaluate`
  function (0-arity) that mutates the workspace and returns the re-evaluated
  `Kazi.PredicateVector`. Returns the `score/2` summary.

  The `reevaluate` function owns the mutation and its cleanup — this module only
  scores the before/after. Kept as a seam so the audit is unit-testable without a
  real workspace, and so the mutation STRATEGY (git revert, fault injection, a
  supplied mutate command) is a caller concern, not baked in here.
  """
  @spec audit(PredicateVector.t(), (-> PredicateVector.t())) :: t()
  def audit(%PredicateVector{} = baseline, reevaluate) when is_function(reevaluate, 0) do
    score(baseline, reevaluate.())
  end

  @doc """
  Deterministic sampling gate: `true` for approximately `rate` (0.0–1.0) of
  distinct `key`s, decided purely from a stable hash of `key` — no clock, no RNG
  state. The same `{key, rate}` always decides the same way, so a periodic
  caller gets a reproducible sample and a test can pin exact keys.

  `rate <= 0.0` never samples; `rate >= 1.0` always samples.

  ## Examples

      iex> Kazi.Audit.PredicateSensitivity.should_sample?("anything", 1.0)
      true
      iex> Kazi.Audit.PredicateSensitivity.should_sample?("anything", 0.0)
      false
  """
  @spec should_sample?(String.t(), float()) :: boolean()
  def should_sample?(_key, rate) when is_number(rate) and rate <= 0, do: false
  def should_sample?(_key, rate) when is_number(rate) and rate >= 1, do: true

  def should_sample?(key, rate) when is_binary(key) and is_number(rate) do
    # phash2 spreads the key uniformly over 0..(2^32 - 1); the lowest `rate`
    # fraction of that space samples. Deterministic and clock-free.
    bucket = :erlang.phash2(key, 1_000_000)
    bucket < rate * 1_000_000
  end

  defp sensitivity(_constrained, 0), do: nil
  defp sensitivity(constrained, tested), do: constrained / tested
end
