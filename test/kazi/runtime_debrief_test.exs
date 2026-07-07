defmodule Kazi.Runtime.DebriefTest do
  @moduledoc """
  Tier 2 — the T48.11 (ADR-0058 §3) end-to-end Runtime wiring: `debrief: true`
  threaded through `Kazi.Runtime.run/2` all the way to persisted hypothesis
  rows, driving a REAL harness subprocess (not a `Kazi.Loop` test double) so the
  parse happens against an actual dispatch result, the same seam production
  runs use. Mirrors `Kazi.RuntimeTest`'s real-component style, scoped down to a
  single code predicate (no live probe / integrate / deploy needed — a goal
  whose whole vector is satisfied converges immediately, T0.8).
  """
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, ReadModel, Repo, Runtime}

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "debrief: true persists the harness's capped hypothesis answer as read-model rows",
       %{tmp_dir: tmp_dir} do
    harness_stub = write_debrief_harness_stub(tmp_dir)
    goal_ref = "runtime-debrief-#{System.unique_integer([:positive])}"

    goal =
      Goal.new(goal_ref,
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
        ]
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: tmp_dir,
               adapter_opts: [command: harness_stub],
               debrief: true,
               run_id: "runtime-debrief-run-id",
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    assert result.outcome == :converged

    hypotheses = ReadModel.list_debrief_hypotheses(goal_ref)
    assert Enum.map(hypotheses, & &1.item) == ["config lives in fixed.txt", "retry convention"]
    assert Enum.all?(hypotheses, &(&1.run_id == "runtime-debrief-run-id"))
    assert Enum.all?(hypotheses, &(&1.goal_ref == goal_ref))
  end

  test "debrief disabled (default) persists no hypothesis rows even with a fenced reply",
       %{tmp_dir: tmp_dir} do
    harness_stub = write_debrief_harness_stub(tmp_dir)
    goal_ref = "runtime-debrief-off-#{System.unique_integer([:positive])}"

    goal =
      Goal.new(goal_ref,
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
        ]
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: tmp_dir,
               adapter_opts: [command: harness_stub],
               run_id: "runtime-debrief-off-run-id",
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    assert result.outcome == :converged
    assert ReadModel.list_debrief_hypotheses(goal_ref) == []
  end

  # A real executable the ClaudeAdapter shells out to: "fixes" the code (writes
  # the marker the test predicate checks) and replies with a fenced debrief
  # JSON block among its plain-text output — exactly the shape a real `claude`
  # reply's tail would carry when the goal opted in.
  defp write_debrief_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_debrief_harness.sh")

    File.write!(path, ~S"""
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    cat <<'DEBRIEF_EOF'
    Fixed the failing predicate.

    ```json
    {"debrief": {"needed_but_discovered": ["config lives in fixed.txt", "retry convention"]}}
    ```
    DEBRIEF_EOF
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
