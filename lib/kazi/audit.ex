defmodule Kazi.Audit do
  @moduledoc """
  Orchestrates the **sampled predicate mutation audit** (T68.9, issue #1501):
  the post-convergence verification-of-verification pass that scores how much a
  goal's converged predicate set actually constrains the workspace, and records
  that score as a standing metric.

  `run/3` ties the three pieces together:

    1. the SAMPLING gate (`Kazi.Audit.PredicateSensitivity.should_sample?/2`) —
       the audit is expensive, so it fires on a deterministic ~`sample_rate`
       fraction of convergences (keyed on the goal ref, clock-free);
    2. the AUDIT (`Kazi.Audit.PredicateSensitivity.audit/2`) — re-evaluate the
       converged predicate set against a mutated workspace and score the
       flips vs survivors;
    3. the RECORD (`Kazi.ReadModel.record_predicate_audit/2`) — persist the score
       per goal (last-write-wins), so `kazi status <goal>` can surface it.

  The mutation-and-reevaluation is an injected function (`:reevaluate`), so the
  orchestration is testable without git or a harness, and the mutation STRATEGY
  (git revert of the converged hunk, fault injection, a supplied mutate command)
  stays a caller concern. A real driver supplies a `reevaluate` that mutates the
  workspace, evaluates the predicate vector via the provider path, and restores
  the workspace.
  """

  alias Kazi.Audit.PredicateSensitivity
  alias Kazi.PredicateVector

  @default_sample_rate 1.0

  @typedoc """
  The outcome of `run/3`: `{:sampled, summary}` when the audit ran (and was
  recorded), or `:skipped` when the sampling gate declined this convergence.
  """
  @type outcome :: {:sampled, PredicateSensitivity.t()} | :skipped

  @doc """
  Runs (or skips, per sampling) a predicate mutation audit for `goal_ref` and
  records the score.

  `baseline` is the converged predicate vector (the passing set to sabotage).
  `opts`:

    * `:reevaluate` — REQUIRED, a 0-arity function that mutates the workspace and
      returns the re-evaluated `Kazi.PredicateVector`. Owns its own cleanup.
    * `:sample_rate` — the 0.0–1.0 audit sample rate (default `#{@default_sample_rate}`,
      i.e. always audit when called directly; a periodic caller lowers it).
    * `:sample_key` — the deterministic sampling key (default `goal_ref`); pass a
      goal-ref + attempt counter to vary the sample across a goal's convergences.
    * `:record?` — persist the score to the read-model (default `true`).

  Returns `{:sampled, summary}` when the audit ran, or `:skipped` when sampling
  declined. Recording is best-effort (a degraded read-model never fails the
  audit); the returned summary is always the freshly computed one.
  """
  @spec run(Kazi.Goal.id(), PredicateVector.t(), keyword()) :: outcome()
  def run(goal_ref, %PredicateVector{} = baseline, opts) when is_list(opts) do
    reevaluate = Keyword.fetch!(opts, :reevaluate)
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)
    sample_key = Keyword.get(opts, :sample_key, to_string(goal_ref))

    if PredicateSensitivity.should_sample?(sample_key, sample_rate) do
      summary = PredicateSensitivity.audit(baseline, reevaluate)

      if Keyword.get(opts, :record?, true) do
        Kazi.ReadModel.record_predicate_audit(goal_ref, summary)
      end

      {:sampled, summary}
    else
      :skipped
    end
  end
end
