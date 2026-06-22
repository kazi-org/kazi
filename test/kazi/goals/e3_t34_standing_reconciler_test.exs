defmodule Kazi.Goals.E3T34StandingReconcilerTest do
  @moduledoc """
  Guards the FIRST SELF-HOSTED kazi goal-file (T2.6 cutover, kazi-builds-kazi):
  `priv/goals/e3-t3.4-standing-reconciler.toml`, which specifies E3 item T3.4
  (standing/continuous reconciler mode, UC-016) as failing acceptance predicates
  over kazi's OWN `mix test` suite (docs/self-hosting.md).

  This test asserts the goal-file is a VALID, NON-VACUOUS create-mode goal:

    1. It LOADS through `Kazi.Goal.Loader.load/1` into the expected create-mode
       `Kazi.Goal`, with the acceptance predicate and the regression guard parsed
       as designed (a typo in the goal-file fails here, not silently at run time).
    2. Its acceptance predicate genuinely FAILS at t0 — the behavior is absent —
       so the goal is not vacuous (the T2.3 vacuous-goal guard would otherwise
       reject it). We prove this WITHOUT running the real `claude` harness and
       without invoking kazi's whole suite: the acceptance criterion targets a
       test file that does not exist, and the t0 failure is exactly that absence.

  Hermetic: no `claude`, no GitHub, no network. The non-vacuity check is a pure
  filesystem assertion on the goal-file's own target path — it does not shell out.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  @goal_path Path.join([File.cwd!(), "priv", "goals", "e3-t3.4-standing-reconciler.toml"])

  describe "the first self-hosted goal loads into the expected create-mode Goal" do
    test "parses priv/goals/e3-t3.4-standing-reconciler.toml" do
      assert {:ok, %Goal{} = goal} = Loader.load(@goal_path)

      assert goal.id == "e3-t3.4-standing-reconciler"
      assert goal.name =~ "standing"
      assert goal.mode == :create
      assert Goal.create?(goal)

      # Self-describing metadata: which E3 item / use case this self-hosted goal
      # targets, so the goal-file is traceable back to docs/plan.md E3.
      assert goal.metadata["backlog_item"] == "T3.4"
      assert goal.metadata["use_case"] == "UC-016"
      assert goal.metadata["self_hosted"] == "true"
    end

    test "the acceptance predicate is a test_runner over kazi's own mix test for a NEW test" do
      assert {:ok, goal} = Loader.load(@goal_path)

      # Exactly one acceptance criterion — the one that DEFINES the feature.
      assert [%Predicate{} = acc] = Goal.acceptance_predicates(goal)
      assert acc.id == "standing-reconciler-acceptance"
      assert acc.kind == :tests
      assert acc.acceptance?
      refute acc.guard?

      # The criterion runs kazi's OWN suite against the not-yet-existing acceptance
      # test file — the create-mode pattern (fails at t0, passes once kazi builds it).
      assert acc.config[:cmd] == "mix"
      assert acc.config[:args] == ["test", "test/kazi/standing_reconciler_test.exs"]
    end

    test "the regression guard is sorted into guards, not predicates" do
      assert {:ok, goal} = Loader.load(@goal_path)

      assert [%Predicate{} = guard] = goal.guards
      assert guard.id == "suite-stays-green"
      assert guard.kind == :tests
      assert guard.guard?
      refute guard.acceptance?
      assert guard.config[:args] == ["test"]

      # The acceptance predicate is the only ordinary (non-guard) predicate.
      assert Enum.map(goal.predicates, & &1.id) == ["standing-reconciler-acceptance"]
    end
  end

  describe "the goal is non-vacuous at t0 — the feature is absent" do
    test "the acceptance test file does not exist yet, so the criterion fails at t0" do
      assert {:ok, goal} = Loader.load(@goal_path)
      [acc] = Goal.acceptance_predicates(goal)

      # The acceptance criterion runs `mix test <path>`; that path is the behavior
      # the goal exists to CREATE. At t0 it must be absent — if this file ever
      # exists in the kazi repo, the goal has been satisfied (T3.4 built) and this
      # self-hosted goal-file is no longer a non-vacuous work-list and should be
      # retired. Asserting absence here keeps the goal honest without running mix.
      ["test", target_test] = acc.config[:args]
      target_path = Path.join(File.cwd!(), target_test)

      refute File.exists?(target_path),
             "#{target_test} exists — the standing-reconciler feature appears built, " <>
               "so this self-hosted goal is no longer non-vacuous and should be retired"
    end
  end
end
