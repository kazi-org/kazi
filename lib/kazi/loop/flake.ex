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
  allowed to drive or block the loop. Quarantine bookkeeping (`quarantine/3`) is
  *sticky*: a single `:fail`/`:pass` re-run verdict never re-admits an id. The
  only way OUT of quarantine is deliberate rehabilitation (below), which demands
  much stronger evidence than one lucky re-run.

  ## Rehabilitation (#820)

  A quarantine with no way out has a failure mode of its own: once a predicate is
  quarantined its result is pinned `:unknown` forever, which (issue #795) can
  never satisfy `Kazi.PredicateVector.satisfied?/1` — an otherwise fully-green run
  can never reach `:converged`, only spin re-observing or eventually stop
  `:stuck`/`:over_budget`. If the flake was transient (the underlying flakiness
  resolved, or it was mis-classified from one bad re-run), that is a false
  negative the loop should be able to recover from.

  `record_pass_streak/3` is the rehabilitation counter: the loop keeps polling a
  quarantined predicate through the real provider (see `Kazi.Loop`) and feeds
  each fresh result here. `rehab_streak/0` (#{3}) consecutive **real** passes —
  observed one per tick, not a burst of re-runs — un-quarantines the id; a single
  non-pass resets the streak to zero (still no re-admission on a lucky blip, just
  a much higher bar than the original one-flip quarantine trigger). This is
  deliberately asymmetric: quarantine is easy to enter (one flip) and hard to
  leave (a sustained run of passes), so a genuinely-flaky check stays quarantined
  in practice while a resolved one is not stuck `:unknown` forever.

  ## Honest termination on quarantine-only blockage (#820)

  Rehabilitation only helps a predicate that actually starts passing again. If it
  does not, an otherwise-satisfied vector blocked SOLELY by quarantined-`:unknown`
  ids has no dispatchable work (the quarantined ids are not in the failing
  work-list either) — the loop cannot make progress by dispatching an agent, and
  should not silently poll it into the ground. `quarantine_blocks_only?/2`
  identifies exactly this condition (every non-passing id in the vector is
  quarantined); `Kazi.Loop` uses it to stop `:stuck` — naming the quarantined ids
  as the reason — after `quarantine_only_stuck_ticks/0` (#{3}) consecutive
  no-work observations, rather than idling at the reobserve interval until
  `max_iterations`/wall-clock forces an uninformative `:over_budget`.
  """

  alias Kazi.PredicateResult
  alias Kazi.PredicateVector

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

  # Number of consecutive REAL passing observations (one per tick, via the actual
  # provider) a quarantined predicate needs before it is rehabilitated. Small and
  # documented per #820: a single lucky re-run quarantines (the existing, cheap,
  # false-positive-tolerant trigger); leaving quarantine demands sustained
  # evidence, so a genuinely-flaky check is not casually re-admitted.
  @default_rehab_streak 3

  @doc "Consecutive real passes a quarantined predicate needs to be rehabilitated (#820)."
  @spec rehab_streak() :: pos_integer()
  def rehab_streak, do: @default_rehab_streak

  @doc """
  Folds one fresh (real provider) evaluation of an already-quarantined predicate
  into its rehabilitation streak.

    * a `:pass` bumps the streak; once it reaches `rehab_streak/0` the id is
      rehabilitated — callers should un-quarantine it and record THIS result
      (the genuine pass), not the `:unknown` quarantine placeholder.
    * anything else (`:fail`/`:error`) resets the streak to zero — still
      quarantined, no partial credit carried across a broken streak.

  `streaks` maps predicate id to its current consecutive-pass count; an id absent
  from the map has a streak of zero. Returns `{:rehabilitated, streaks}` (id
  removed from the map) or `{:still_quarantined, streaks}`.

  ## Examples

      iex> {:still_quarantined, s} = Kazi.Loop.Flake.record_pass_streak(%{}, :a, Kazi.PredicateResult.pass())
      iex> s
      %{a: 1}

      iex> s = %{a: 2}
      iex> Kazi.Loop.Flake.record_pass_streak(s, :a, Kazi.PredicateResult.pass())
      {:rehabilitated, %{}}

      iex> s = %{a: 2}
      iex> Kazi.Loop.Flake.record_pass_streak(s, :a, Kazi.PredicateResult.fail())
      {:still_quarantined, %{}}
  """
  @spec record_pass_streak(map(), Kazi.Predicate.id(), PredicateResult.t()) ::
          {:rehabilitated, map()} | {:still_quarantined, map()}
  def record_pass_streak(streaks, id, %PredicateResult{} = result) when is_map(streaks) do
    if PredicateResult.passed?(result) do
      count = Map.get(streaks, id, 0) + 1

      if count >= rehab_streak() do
        {:rehabilitated, Map.delete(streaks, id)}
      else
        {:still_quarantined, Map.put(streaks, id, count)}
      end
    else
      {:still_quarantined, Map.delete(streaks, id)}
    end
  end

  # Consecutive no-dispatchable-work observations (#820) the loop tolerates once
  # blocked ONLY by quarantined-unknown ids before it stops honestly `:stuck`
  # instead of idling at the reobserve interval to `max_iterations`/wall-clock.
  # Small and documented, matching the rehab streak's order of magnitude.
  @default_quarantine_only_stuck_ticks 3

  @doc "No-work ticks tolerated before a quarantine-only blockage stops :stuck (#820)."
  @spec quarantine_only_stuck_ticks() :: pos_integer()
  def quarantine_only_stuck_ticks, do: @default_quarantine_only_stuck_ticks

  @doc """
  True iff the vector is unsatisfied SOLELY because of quarantined ids: at least
  one non-passing result exists, and every non-passing id is in `quarantine`. A
  false result means either the vector is fully satisfied (nothing non-passing)
  or something OTHER than quarantine is blocking it (a real failure, or a live
  predicate legitimately still pending) — in either case the ordinary loop
  behaviour (dispatch or keep polling) applies unchanged.

  ## Examples

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.unknown()})
      iex> Kazi.Loop.Flake.quarantine_blocks_only?(v, MapSet.new([:b]))
      true

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.fail()})
      iex> Kazi.Loop.Flake.quarantine_blocks_only?(v, MapSet.new())
      false

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass()})
      iex> Kazi.Loop.Flake.quarantine_blocks_only?(v, MapSet.new())
      false
  """
  @spec quarantine_blocks_only?(PredicateVector.t(), MapSet.t()) :: boolean()
  def quarantine_blocks_only?(%PredicateVector{results: results}, %MapSet{} = quarantine) do
    non_passing = for {id, result} <- results, not PredicateResult.passed?(result), do: id
    non_passing != [] and Enum.all?(non_passing, &MapSet.member?(quarantine, &1))
  end
end
