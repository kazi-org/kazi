defmodule Kazi.Runtime.GoalDriftTest do
  @moduledoc """
  goal-drift-guard-1415: proves the goal-drift guard end to end.

  Tier 1 pins `Kazi.Runtime.GoalDrift`'s pure logic in isolation: `snapshot/1`
  fingerprints a goal's predicate bar, and `detect/2` reports whether a goal-file
  currently on disk still matches that snapshot.

  Tier 2 drives the REAL `Kazi.Runtime.run/2` against a goal-file loaded from a
  real temp file and a REAL harness subprocess that, instead of fixing the
  failing predicate it cannot satisfy, EDITS the goal-file on disk to delete
  that predicate -- exactly the move a gaming agent would make to fake
  convergence. The test proves two things at once:

    * the ORIGINAL bar wins -- the loop keeps requiring the deleted predicate to
      pass (it never re-reads the file), so the run does NOT falsely converge;
    * the drift is surfaced -- the terminal result carries `goal_drifted: true`
      and names exactly which predicate was removed, so an operator is told the
      file moved instead of unknowingly trusting a result that no longer
      matches what is on disk.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateVector, Runtime}
  alias Kazi.Runtime.GoalDrift

  @moduletag :tmp_dir

  # ===========================================================================
  # Tier 1 -- snapshot/1 + detect/2 in isolation
  # ===========================================================================

  describe "snapshot/1" do
    test "fingerprints every predicate by id, independent of description" do
      goal =
        Goal.new("g",
          predicates: [
            Predicate.new("code", :tests, config: %{cmd: "sh"}, description: "v1"),
            Predicate.new("live", :http_probe, config: %{url: "http://x"})
          ]
        )

      snapshot = GoalDrift.snapshot(goal)

      assert Map.keys(snapshot) |> Enum.sort() == ["code", "live"]
      assert is_binary(snapshot["code"])

      # Changing only the description (prose, not the bar) leaves the
      # fingerprint unchanged -- only kind/config/guard? define what "pass"
      # means.
      reworded =
        Goal.new("g",
          predicates: [
            Predicate.new("code", :tests, config: %{cmd: "sh"}, description: "v2"),
            Predicate.new("live", :http_probe, config: %{url: "http://x"})
          ]
        )

      assert GoalDrift.snapshot(reworded) == snapshot
    end

    test "a config change flips the fingerprint" do
      base = Goal.new("g", predicates: [Predicate.new("code", :tests, config: %{cmd: "sh"})])
      changed = Goal.new("g", predicates: [Predicate.new("code", :tests, config: %{cmd: "bash"})])

      refute GoalDrift.snapshot(base) == GoalDrift.snapshot(changed)
    end
  end

  describe "detect/2" do
    test "reports :unchanged when the on-disk goal-file still matches the ORIGINAL snapshot",
         %{tmp_dir: tmp_dir} do
      path = write_goal_file(tmp_dir, ["code"])
      {:ok, goal} = Kazi.Goal.Loader.load(path)

      assert GoalDrift.detect(GoalDrift.snapshot(goal), path) == :unchanged
    end

    test "reports {:drifted, diff} naming a removed predicate id", %{tmp_dir: tmp_dir} do
      path = write_goal_file(tmp_dir, ["code", "hard"])
      {:ok, goal} = Kazi.Goal.Loader.load(path)
      t0_snapshot = GoalDrift.snapshot(goal)

      # Simulate an agent (or a human) weakening the bar mid-run: rewrite the
      # SAME file with the hard predicate gone.
      File.write!(path, goal_toml(["code"]))

      assert {:drifted, diff} = GoalDrift.detect(t0_snapshot, path)
      assert diff.removed == ["hard"]
      assert diff.added == []
      assert diff.changed == []
    end

    test "reports {:drifted, diff} naming a changed predicate id (config weakened in place)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "goal.toml")

      File.write!(path, """
      id = "drift-changed"

      [[predicate]]
      id = "code"
      provider = "custom_script"
      cmd = "sh"
      args = ["-c", "test -f fixed.txt"]
      verdict = "exit_zero"
      """)

      {:ok, goal} = Kazi.Goal.Loader.load(path)
      t0_snapshot = GoalDrift.snapshot(goal)

      # Same predicate id, weaker command (always exits 0 -- an unconditional
      # pass instead of the real check).
      File.write!(path, """
      id = "drift-changed"

      [[predicate]]
      id = "code"
      provider = "custom_script"
      cmd = "sh"
      args = ["-c", "true"]
      verdict = "exit_zero"
      """)

      assert {:drifted, %{changed: ["code"], added: [], removed: []}} =
               GoalDrift.detect(t0_snapshot, path)
    end

    test "degrades to :unchanged for a source that is not a loadable goal-file (never raises)" do
      snapshot = GoalDrift.snapshot(Goal.new("g", predicates: [Predicate.new("p", :tests)]))

      assert GoalDrift.detect(snapshot, "prop-does-not-exist") == :unchanged
      assert GoalDrift.detect(snapshot, nil) == :unchanged
    end
  end

  # ===========================================================================
  # Tier 2 -- Kazi.Runtime.run/2 end to end
  # ===========================================================================

  test "the ORIGINAL bar wins and the drift is surfaced when the dispatched agent deletes a failing predicate from the goal-file",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_path = Path.join(tmp_dir, "goal.toml")

    File.write!(goal_path, """
    id = "goal-drift-fixture"

    [budget]
    max_iterations = 2

    [[predicate]]
    id = "code"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    verdict = "exit_zero"

    [[predicate]]
    id = "hard"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f hard.txt"]
    verdict = "exit_zero"
    """)

    {:ok, goal} = Kazi.Goal.Loader.load(goal_path)

    # The "gaming" harness stub: instead of making `hard.txt` exist (the real
    # fix), it fixes `code` and rewrites the GOAL-FILE ON DISK to drop the
    # `hard` predicate entirely -- the file now describes a goal that is
    # already met.
    stub = Path.join(tmp_dir, "gaming_harness.sh")

    File.write!(stub, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    cat > #{goal_path} <<'GOALEOF'
    id = "goal-drift-fixture"

    [budget]
    max_iterations = 2

    [[predicate]]
    id = "code"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    verdict = "exit_zero"
    GOALEOF
    exit 0
    """)

    File.chmod!(stub, 0o755)

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               persist?: false,
               goal_source: goal_path,
               adapter_opts: [command: stub],
               reobserve_interval_ms: 5,
               await_timeout: 20_000
             )

    # PRECEDENCE (ADR-0080 amendment, seal > drift on the OUTCOME): the goal-file
    # is implicitly sealed, so editing it mid-run VOIDS the run -- `:tampered`,
    # not the natural budget terminal. `:tampered` is the honest cause here;
    # `:over_budget` (the pre-ADR-0080 outcome) misattributed a tampered contract
    # as "the work was too hard".
    assert result.outcome == :tampered
    assert result.tampered_file.path == goal_path
    assert result.tampered_file.change == :modified

    # ORIGINAL bar wins -- UNCHANGED by the precedence. The loop never re-reads
    # the goal-file, so the DELETED predicate `hard` is still in the vector the
    # run is judged against, and the run can never falsely report `:converged`.
    # This guarantee is structural to the loop, not something either mechanism
    # confers.
    assert PredicateVector.get(result.vector, "hard").status == :fail
    refute result.outcome == :converged

    # The seal fires BEFORE the next observe, so the terminal vector is the last
    # PRE-tamper observation: `code` is still :fail here even though the harness
    # did create fixed.txt, because that work was never observed. Deliberate --
    # once the contract is void there is nothing trustworthy left to grade
    # against, so the run stops rather than scoring work under a changed bar.
    assert PredicateVector.get(result.vector, "code").status == :fail

    # Drift STILL surfaced -- the two mechanisms COMPOSE. Seal decides the
    # outcome; goal-drift remains the diagnostic that names exactly WHICH
    # predicates moved on disk (the seal alone only names the file).
    assert result.goal_drifted == true
    assert result.goal_drift.removed == ["hard"]
    assert result.goal_drift.added == []
    assert result.goal_drift.changed == []
  end

  test "with sealing OFF, goal-drift keeps its observational contract: the run reaches its NATURAL terminal and the drift is still surfaced",
       %{tmp_dir: tmp_dir} do
    # The coherence half of the precedence: goal-drift is SUBORDINATE to the seal,
    # not RETIRED by it. With `[seal] enabled = false` the goal-file is not sealed,
    # so nothing voids the run -- drift reverts to purely observational and the run
    # terminates on the ORIGINAL budget, exactly as it did pre-ADR-0080.
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_path = Path.join(tmp_dir, "goal.toml")

    File.write!(goal_path, """
    id = "goal-drift-unsealed"

    [budget]
    max_iterations = 2

    [seal]
    enabled = false

    [[predicate]]
    id = "code"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    verdict = "exit_zero"

    [[predicate]]
    id = "hard"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f hard.txt"]
    verdict = "exit_zero"
    """)

    {:ok, goal} = Kazi.Goal.Loader.load(goal_path)

    stub = Path.join(tmp_dir, "gaming_harness_unsealed.sh")

    File.write!(stub, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    cat > #{goal_path} <<'GOALEOF'
    id = "goal-drift-unsealed"

    [budget]
    max_iterations = 2

    [seal]
    enabled = false

    [[predicate]]
    id = "code"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    verdict = "exit_zero"
    GOALEOF
    exit 0
    """)

    File.chmod!(stub, 0o755)

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               persist?: false,
               goal_source: goal_path,
               adapter_opts: [command: stub],
               reobserve_interval_ms: 5,
               await_timeout: 20_000
             )

    # Nothing sealed => no tamper stop; the ORIGINAL bar still wins and the run
    # stalls on its own budget rather than falsely converging.
    assert result.outcome == :over_budget
    refute Map.has_key?(result, :tampered_file)
    assert PredicateVector.get(result.vector, "hard").status == :fail

    # ...and the observational drift report is intact.
    assert result.goal_drifted == true
    assert result.goal_drift.removed == ["hard"]
  end

  test "no drift ⇒ goal_drifted is absent from the result (additive field)", %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_path = write_goal_file(tmp_dir, ["code"])
    {:ok, goal} = Kazi.Goal.Loader.load(goal_path)

    stub = Path.join(tmp_dir, "honest_harness.sh")
    File.write!(stub, "#!/bin/sh\necho fixed > code.txt\nexit 0\n")
    File.chmod!(stub, 0o755)

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               persist?: false,
               goal_source: goal_path,
               adapter_opts: [command: stub],
               reobserve_interval_ms: 5,
               await_timeout: 20_000
             )

    assert result.outcome == :converged
    refute Map.has_key?(result, :goal_drifted)
    refute Map.has_key?(result, :goal_drift)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp write_goal_file(tmp_dir, predicate_ids) do
    path = Path.join(tmp_dir, "goal_#{System.unique_integer([:positive])}.toml")
    File.write!(path, goal_toml(predicate_ids))
    path
  end

  defp goal_toml(predicate_ids) do
    predicates =
      Enum.map_join(predicate_ids, "\n", fn id ->
        """
        [[predicate]]
        id = "#{id}"
        provider = "custom_script"
        cmd = "sh"
        args = ["-c", "test -f #{id}.txt"]
        verdict = "exit_zero"
        """
      end)

    """
    id = "goal-drift-unit"

    #{predicates}
    """
  end
end
