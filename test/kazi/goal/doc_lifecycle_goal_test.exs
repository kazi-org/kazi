defmodule Kazi.Goal.DocLifecycleGoalTest do
  @moduledoc """
  T31.6 (ADR-0036) acceptance: the self-maintaining documentation lifecycle is a
  committed kazi STANDING goal-file that LOADS and whose predicates EVALUATE,
  built ENTIRELY on the E32 generic providers -- no bespoke predicate engine and
  no doc-specific code in kazi core.

  This test pins three things:

    1. The goal-file (`priv/examples/doc_lifecycle.goal.toml`) loads through the
       real `Kazi.Goal.Loader` and is a standing goal with the expected predicate
       composition: six `custom_script` freshness predicates (wrapping the T31.4
       checker scripts, ADR-0040) and two `ratchet` predicates (envelope-v2,
       ADR-0041) -- a doc-coverage gradient and a stale-task count.

    2. Every wrapper points at a REAL script/tool that exists on disk (zero-stub):
       each `custom_script` `cmd` and each `ratchet` `metric.cmd` resolves to a
       file in the repo. A goal-file that names a non-existent checker would be a
       silent gap; this fails loudly instead.

    3. A representative `custom_script` wrapper EVALUATES headlessly: invoking the
       provider against a real checker returns a genuine `:pass`/`:fail` verdict
       (never `:error`), proving the wrapper executes end-to-end. This is the
       headless-verifiable bar (load + predicate-eval); it does not drive a live
       multi-minute harness reconcile.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.CustomScript

  @goal_file Path.join([File.cwd!(), "priv", "examples", "doc_lifecycle.goal.toml"])

  setup_all do
    assert {:ok, goal} = Loader.load(@goal_file)
    {:ok, goal: goal}
  end

  test "the standing goal-file loads as a standing goal", %{goal: goal} do
    assert %Goal{standing: true, id: "doc-lifecycle"} = goal
    assert goal.metadata["use_case"] == "UC-046"
  end

  test "predicate composition: 6 custom_script freshness + 2 ratchet", %{goal: goal} do
    by_kind = Enum.group_by(goal.predicates, & &1.kind)

    custom_script = Map.get(by_kind, :custom_script, [])
    ratchet = Map.get(by_kind, :ratchet, [])

    assert length(custom_script) == 6,
           "expected 6 custom_script freshness predicates wrapping the T31.4 checkers"

    assert length(ratchet) == 2,
           "expected 2 ratchet predicates (doc-coverage gradient + stale-task count)"

    # No OTHER provider kinds -- the lifecycle reuses ONLY the generic providers
    # (ADR-0036 reject: no bespoke predicate engine, no doc-specific core code).
    assert Map.keys(by_kind) |> Enum.sort() == [:custom_script, :ratchet]

    # The expected ids are all present (the T31.4 set + the two ratchets).
    ids = goal.predicates |> Enum.map(& &1.id) |> Enum.sort()

    assert ids == [
             "adr-refs-exist",
             "commands-in-readme",
             "doc-coverage-ratchet",
             "no-dead-command-refs",
             "plan-trimmed",
             "readme-site-coherence",
             "skill-cli-coherence",
             "stale-tasks-ratchet"
           ]
  end

  test "every custom_script verdict is declared and exit_zero", %{goal: goal} do
    for %Predicate{kind: :custom_script, id: id, config: config} <- goal.predicates do
      assert config.verdict == "exit_zero",
             "custom_script #{inspect(id)} must declare verdict (ADR-0040, no naive exit-0)"
    end
  end

  test "every custom_script cmd is a single runnable executable (no relative cmd)", %{goal: goal} do
    # cmd is the EXECUTABLE (resolved against PATH, not the workspace); the script
    # rides in args so bash/node/mix resolve it against the run cwd. A bare relative
    # cmd would fail with :enoent at dispatch (System.cmd does not search cwd).
    for %Predicate{kind: :custom_script, id: id, config: config} <- goal.predicates do
      cmd = config.cmd

      assert cmd in ["bash", "node", "mix"],
             "custom_script #{inspect(id)} cmd #{inspect(cmd)} must be an executable on PATH"
    end
  end

  test "zero-stub: every custom_script's checker arg resolves to a real file", %{goal: goal} do
    for %Predicate{kind: :custom_script, id: id, config: config} <- goal.predicates do
      # The first arg that looks like a repo path is the checker script; it must
      # exist on disk (a stubbed/typo'd checker would be a silent gap).
      script = Enum.find(config[:args] || [], &String.contains?(&1, "/"))

      assert script != nil,
             "custom_script #{inspect(id)} must carry its checker path in args"

      assert File.exists?(Path.join(File.cwd!(), script)),
             "custom_script #{inspect(id)} checker #{inspect(script)} must be a real file"
    end
  end

  test "zero-stub: every ratchet metric points at a real script and declares a direction",
       %{goal: goal} do
    for %Predicate{kind: :ratchet, id: id, config: config} <- goal.predicates do
      assert config.direction in ["higher_better", "lower_better"],
             "ratchet #{inspect(id)} must declare a direction (ADR-0041)"

      assert Map.has_key?(config, :baseline), "ratchet #{inspect(id)} must declare a baseline"

      metric_args = config.metric["args"] || config.metric[:args] || []
      script = Enum.find(metric_args, &String.contains?(&1, "/"))

      assert script != nil and File.exists?(Path.join(File.cwd!(), script)),
             "ratchet #{inspect(id)} metric script must be a real file, got #{inspect(script)}"
    end
  end

  test "a freshness custom_script wrapper EVALUATES to a real verdict (not :error)", %{goal: goal} do
    # plan-trimmed (predicate (d)) runs purely off the repo tree, so it produces a
    # real verdict here without a network or an installed tool; evaluating it proves
    # the wrapper executes end-to-end and returns a genuine status, not an :error.
    pred = Enum.find(goal.predicates, &(&1.id == "plan-trimmed"))
    assert %Predicate{kind: :custom_script} = pred

    result = CustomScript.evaluate(pred, %{workspace: File.cwd!()})

    assert result.status in [:pass, :fail],
           "the wrapper must produce a real verdict, got #{inspect(result.status)}: " <>
             inspect(Map.get(result, :evidence))
  end
end
