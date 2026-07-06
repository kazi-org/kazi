defmodule Kazi.Loop.QuarantineExitTest do
  @moduledoc """
  Loop-level enforcement of the #820 fix: quarantine rehabilitation + an honest
  terminal instead of a burned budget.

  The live occurrence (kazi 1.74.0): `suite_green` flapped once, got quarantined
  (`:unknown`, per #795 correctly blocking `:converged`), then passed every
  subsequent evaluation while the loop had nothing left to dispatch — it ticked
  ~1/s to `max_iterations` (40) and stopped `:over_budget`, even though the code
  was demonstrably green. Three regressions are pinned here:

    (a) a quarantined predicate that then passes `Kazi.Loop.Flake.rehab_streak/0`
        consecutive REAL evaluations is rehabilitated and an otherwise-green
        vector converges (no separate rehab path — it converges the same tick its
        real pass makes the vector satisfied);
    (b) when the ONLY thing blocking the vector is quarantined-`:unknown` ids and
        there is no dispatchable work, the loop stops honestly `:stuck` (naming
        the quarantined ids) after a bounded number of no-work ticks — it does
        NOT burn `max_iterations` at full tick rate;
    (c) the no-work reobserve path backs off instead of spinning sub-second
        forever, even when the blockage is a legitimately-pending live predicate
        (not quarantine) that never resolves.

  The pure rehabilitation/blockage rules are doctested on
  `Kazi.Loop.Flake.record_pass_streak/3` and `Kazi.Loop.Flake.quarantine_blocks_only?/2`
  (see `Kazi.Loop.FlakeTest`); this module proves the LOOP enforces them.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles
  # ===========================================================================

  # Scripts a per-predicate-id sequence of statuses: call N of predicate `id`
  # returns `Enum.at(script, N)`, or the script's LAST entry once exhausted (so a
  # short script can express "then stays this way forever"). Calls are counted in
  # an `Agent` (the loop drives the provider from its own gen_statem process, so
  # a plain module attribute / process dictionary would not be shared).
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, %{goal: %{metadata: %{calls: calls, scripts: scripts}}}) do
      n =
        Agent.get_and_update(calls, fn counts ->
          current = Map.get(counts, id, 0)
          {current, Map.put(counts, id, current + 1)}
        end)

      script = Map.fetch!(scripts, id)
      status = Enum.at(script, n) || List.last(script)
      PredicateResult.new(status, %{id: id, call: n})
    end
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp scripted_goal(id, scripts, extra_opts \\ []) do
    {:ok, calls} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    predicates =
      for pred_id <- Map.keys(scripts) do
        kind = Keyword.get(extra_opts, :kind_for, fn _id -> :tests end).(pred_id)
        Predicate.new(pred_id, kind)
      end

    goal_opts =
      [
        predicates: predicates,
        metadata: %{calls: calls, scripts: scripts}
      ] ++ Keyword.drop(extra_opts, [:kind_for])

    Goal.new(id, goal_opts)
  end

  defp start_loop(goal, opts \\ []) do
    base = [
      goal: goal,
      providers: %{tests: ScriptedProvider, http_probe: ScriptedProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      reobserve_interval_ms: 5,
      flake_max_retries: 1
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # ===========================================================================
  # (a) rehabilitation: sustained real passes un-quarantine and converge
  # ===========================================================================

  describe "rehabilitation" do
    test "a quarantined predicate that then passes rehab_streak/0 times in a row converges" do
      # flappy: fails, then one rerun passes -> classified :flaky -> quarantined
      # at the first observation. Every observation after that is a REAL
      # provider call (the rehab check) — three passes in a row (indices 2,3,4)
      # crosses `Kazi.Loop.Flake.rehab_streak/0` (3) and un-quarantines it on the
      # tick that produces the third.
      scripts = %{
        flappy: [:fail, :pass, :pass, :pass, :pass],
        other: [:pass]
      }

      {:ok, loop} = start_loop(scripted_goal("rehab-test", scripts))

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

      assert result.outcome == :converged
      # Rehabilitated: no id remains quarantined on the terminal vector.
      assert result.quarantine == []
    end
  end

  # ===========================================================================
  # (b) honest :stuck when the ONLY blockage is quarantine, bounded ticks
  # ===========================================================================

  describe "honest termination on quarantine-only blockage" do
    test "stops :stuck naming the quarantined id instead of burning max_iterations" do
      # flappy: quarantined at observation 0, then fails every rehab check
      # forever (never rehabilitates) -- an otherwise fully-green vector with
      # NOTHING left to dispatch. The live #820 bug burned all 40 iterations at
      # ~1 tick/s; the fix must stop well short of that, honestly.
      scripts = %{
        flappy: [:fail, :pass, :fail],
        other: [:pass]
      }

      goal = scripted_goal("quarantine-stuck-test", scripts, budget: [max_iterations: 40])

      {:ok, loop} = start_loop(goal)

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

      assert result.outcome == :stopped
      assert result.reason == :stuck
      # Well under the 40-iteration budget the live bug burned in full.
      assert result.iterations < 10
      # Still quarantined (never rehabilitated) -- the honest reason.
      assert result.quarantine == [:flappy]

      snap = Kazi.Loop.snapshot(loop)
      assert snap.stuck_failing == [:flappy]

      # The stuck bundle (T35.6) names the quarantined id as the blocking cause.
      failing_ids = Enum.map(result.stuck_bundle["failing_predicates"], & &1["id"])
      assert "flappy" in failing_ids
    end

    test "quarantine_only_stuck_ticks/0 bounds how many no-work ticks are tolerated" do
      scripts = %{flappy: [:fail, :pass, :fail], other: [:pass]}
      goal = scripted_goal("quarantine-stuck-bound-test", scripts)

      {:ok, loop} = start_loop(goal)

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :stopped
      assert result.reason == :stuck

      # 2 setup ticks (integrate, deploy) land before the vector is ever
      # evaluated as quarantine-only, then the bounded no-work window fires.
      assert result.iterations <=
               2 + Kazi.Loop.Flake.quarantine_only_stuck_ticks()
    end
  end

  # ===========================================================================
  # (c) no-work reobserve backs off instead of spinning sub-second forever
  # ===========================================================================

  describe "no-work backoff" do
    test "a persistently-pending live predicate (not quarantine) backs off the poll rate" do
      # A live-kind predicate that never passes is legitimate ongoing work (a
      # probe not yet green) -- NOT a quarantine-only blockage (the id is never
      # quarantined, so `Kazi.Loop.Flake.quarantine_blocks_only?/2` is false) --
      # so the loop must keep polling rather than stopping. With NO backoff every
      # no-work tick would arrive at the SAME fixed interval forever; the #820
      # fix backs the interval off (roughly doubling) on each consecutive
      # no-work tick.
      #
      # Measured via `on_iteration` arrival timestamps rather than "how many
      # ticks fit in a fixed sleep" -- a wall-clock tick COUNT is sensitive to
      # system load (CI can be much slower/faster than a dev machine), but the
      # RATIO between an early gap and a later gap is not: a regression to a
      # fixed-interval poll collapses that ratio to ~1 regardless of machine
      # speed, while backoff keeps growing it.
      test_pid = self()

      goal = scripted_goal("backoff-test", %{probe: [:fail]}, kind_for: fn _ -> :http_probe end)

      {:ok, loop} =
        start_loop(goal,
          reobserve_interval_ms: 20,
          on_iteration: fn _payload ->
            send(test_pid, {:tick, System.monotonic_time(:millisecond)})
          end
        )

      # The first 3 ticks (initial observe, post-integrate, post-deploy) are all
      # near-zero-delay setup ticks, not yet in the no-work backoff path -- drain
      # them before timing gaps.
      for _ <- 1..3, do: assert_receive({:tick, _}, 2_000)

      gaps =
        for _ <- 1..5 do
          assert_receive({:tick, t}, 5_000)
          t
        end
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      :ok = Kazi.Loop.stop(loop)

      # 4 consecutive no-work ticks at a doubling backoff: the last gap should be
      # meaningfully larger than the first (nominally ~8x: 20/40/80/160ms) --
      # generous margin over 1x so ordinary scheduling jitter cannot mask a
      # regression to a fixed interval.
      assert List.last(gaps) > List.first(gaps) * 2
    end
  end
end
