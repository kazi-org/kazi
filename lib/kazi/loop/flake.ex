defmodule Kazi.Loop.Flake do
  @moduledoc """
  Flake handling for the convergence loop (T1.3, UC-008, concept §5).

  A flaky predicate is one whose objective check is *nondeterministic*: it fails
  on one evaluation and passes on another without the code changing under it. If
  the controller treated such a fail as real work it would poison the loop into
  infinite "fix" dispatches against a problem that isn't there (concept §5:
  "A flaky test would poison the loop into infinite 'work.'"). This module is the
  controller's defence: a *re-run policy* that distinguishes a real failure from a
  flake, plus *quarantine* bookkeeping so a known-flaky predicate is taken out of
  the convergence/work calculus instead of driving the loop.

  Everything here is **pure** — no provider calls, no process state. The loop
  (`Kazi.Loop`) owns the side-effecting re-invocation of the provider; this module
  decides, given the *sequence of results* a re-run produced, what the predicate
  is, and keeps the quarantine set. That split keeps the policy independently
  testable (you script a sequence and assert the classification) and the loop
  change minimal (it only routes failing-predicate evaluation through here).

  ## Re-run policy

  When a predicate first evaluates to `:pass`, it is taken at face value — a flake
  that *passes* is not work and re-running a passing check only burns time. When
  it first evaluates to `:fail` or `:error`, the loop re-runs it up to
  `max_retries/0` more times (default #{2}, i.e. up to 3 total evaluations) and
  hands the full ordered sequence to `classify/1`:

    * **any `:pass` in the sequence** → `:flaky`. The check flipped between fail
      and pass with no code change: nondeterministic, not real work.
    * **every result is non-pass** (all `:fail`/`:error`) → `:fail`. A
      consistently-failing predicate is genuine work; it is NOT quarantined.

  `:error` (provider could not run) is grouped with `:fail` for the purpose of
  "did this flip?": an `error` then `pass` is still a flake (the check is
  nondeterministic), and an all-`error` sequence is a consistent non-pass that the
  loop surfaces unchanged (the existing `:error` handling — infra problem, not
  agent work — is untouched).

  ## Quarantine semantics (the exact choice, per the task)

  A predicate classified `:flaky` is **quarantined**: its id is recorded in the
  loop's quarantine set and surfaced via `Kazi.Loop.snapshot/1`. A quarantined
  predicate is **excluded from the convergence calculus** for the rest of the
  run:

    * it is **not** treated as outstanding work — it never appears in the failing
      work-list, so the loop never dispatches an agent to "fix" it; and
    * it does **not by itself block convergence** — `satisfied?` is evaluated over
      the *non-quarantined* predicates only, so a quarantined-flaky predicate
      neither counts toward nor against convergence.

  This is the faithful reading of concept §5 ("re-run / quarantine so a
  nondeterministic fail is not treated as real work"): a flake is neither real
  failing work nor a real failing requirement, so it is set aside rather than
  allowed to drive or block the loop. Quarantine is *sticky*: once a predicate has
  proven nondeterministic it stays quarantined for the remainder of the run, even
  if a later observation happens to pass it — re-admitting it would just risk the
  poison loop the policy exists to prevent.
  """

  alias Kazi.PredicateResult

  # Default number of EXTRA evaluations after the first failing one. Two retries
  # → up to three total evaluations of a failing predicate before the result is
  # taken as real. Injectable via the loop's `:flake_max_retries` option.
  @default_max_retries 2

  @typedoc """
  The verdict the re-run policy reaches for a predicate from its result sequence.

    * `:pass`  — holds (a `:pass` was the authoritative first result).
    * `:fail`  — consistently non-pass across all (re-)runs: genuine work.
    * `:flaky` — flipped between non-pass and `:pass`: nondeterministic, quarantine.
  """
  @type verdict :: :pass | :fail | :flaky

  @doc "Default number of re-runs (extra evaluations) for a failing predicate."
  @spec max_retries() :: non_neg_integer()
  def max_retries, do: @default_max_retries

  @doc """
  True iff the predicate's *first* result warrants re-running it under the policy
  — i.e. it did not pass. A `:pass` is taken at face value (no re-run); a
  `:fail`/`:error` is re-run to tell a real failure from a flake.

  ## Examples

      iex> Kazi.Loop.Flake.needs_rerun?(Kazi.PredicateResult.pass())
      false

      iex> Kazi.Loop.Flake.needs_rerun?(Kazi.PredicateResult.fail())
      true

      iex> Kazi.Loop.Flake.needs_rerun?(Kazi.PredicateResult.error())
      true
  """
  @spec needs_rerun?(PredicateResult.t()) :: boolean()
  def needs_rerun?(%PredicateResult{} = result), do: not PredicateResult.passed?(result)

  @doc """
  Classifies a non-empty ordered sequence of re-run results into a `t:verdict/0`.

    * any `:pass` present → `:flaky` (the check flipped: nondeterministic);
    * otherwise (all non-pass) → `:fail` (consistent failure: genuine work).

  A single-element `[pass]` is `:pass`; a single-element `[fail]`/`[error]` is
  `:fail` (it never got a chance to flip, but with no re-run there is no evidence
  of nondeterminism, so it is treated as a real failure — the policy only
  re-runs when configured to, and a zero-retry config deliberately disables flake
  detection).

  ## Examples

      iex> r = fn s -> Kazi.PredicateResult.new(s) end
      iex> Kazi.Loop.Flake.classify([r.(:pass)])
      :pass

      iex> r = fn s -> Kazi.PredicateResult.new(s) end
      iex> Kazi.Loop.Flake.classify([r.(:fail), r.(:fail), r.(:fail)])
      :fail

      iex> r = fn s -> Kazi.PredicateResult.new(s) end
      iex> Kazi.Loop.Flake.classify([r.(:fail), r.(:pass)])
      :flaky

      iex> r = fn s -> Kazi.PredicateResult.new(s) end
      iex> Kazi.Loop.Flake.classify([r.(:error), r.(:error)])
      :fail
  """
  @spec classify([PredicateResult.t(), ...]) :: verdict()
  def classify([_ | _] = results) do
    passed? = Enum.any?(results, &PredicateResult.passed?/1)
    all_pass? = Enum.all?(results, &PredicateResult.passed?/1)

    cond do
      all_pass? -> :pass
      passed? -> :flaky
      true -> :fail
    end
  end

  @doc """
  Folds a re-run verdict for predicate `id` into the running quarantine set.

  Only a `:flaky` verdict mutates the set (the id is added). `:pass`/`:fail`
  leave it unchanged, and the set is sticky (an already-quarantined id stays
  quarantined regardless of later verdicts). Returns the updated set.

  ## Examples

      iex> q = Kazi.Loop.Flake.quarantine(MapSet.new(), :a, :flaky)
      iex> Kazi.Loop.Flake.quarantined?(q, :a)
      true

      iex> q = Kazi.Loop.Flake.quarantine(MapSet.new(), :a, :fail)
      iex> Kazi.Loop.Flake.quarantined?(q, :a)
      false
  """
  @spec quarantine(MapSet.t(), Kazi.Predicate.id(), verdict()) :: MapSet.t()
  def quarantine(%MapSet{} = set, id, :flaky), do: MapSet.put(set, id)
  def quarantine(%MapSet{} = set, _id, _verdict), do: set

  @doc "True iff predicate `id` is in the quarantine set."
  @spec quarantined?(MapSet.t(), Kazi.Predicate.id()) :: boolean()
  def quarantined?(%MapSet{} = set, id), do: MapSet.member?(set, id)

  @doc """
  The result a quarantined-flaky predicate is recorded as in the vector:
  `:unknown` (it carries no convergence claim — `Kazi.PredicateResult`), with the
  flake's evidence preserved for observability. `:unknown` keeps the predicate out
  of `PredicateVector.failing/1` (so it never becomes work), and convergence is
  separately evaluated ignoring quarantined ids (see `Kazi.Loop`).

  `last` is the most recent (re-run) result, whose evidence is folded in so an
  operator inspecting the vector can see why the predicate was quarantined.
  """
  @spec quarantined_result(PredicateResult.t()) :: PredicateResult.t()
  def quarantined_result(%PredicateResult{evidence: evidence}) do
    PredicateResult.unknown(Map.put(evidence, :quarantined, :flaky))
  end
end
