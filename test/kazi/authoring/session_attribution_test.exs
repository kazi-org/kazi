defmodule Kazi.Authoring.SessionAttributionTest do
  @moduledoc """
  Session provenance part 2: proposals carry `session_name`, and a run started
  from an approved proposal records the `proposal_ref` (and, absent its own
  session identity, the proposal's `session_name`) on its `runs` row.

  The plan -> approve -> apply lifecycle is designed to be cross-session (a
  DIFFERENT session may approve or apply what another planned, T39.2,
  ADR-0049) -- this closes the loop that traceability afterward instead of
  just being inferred.

  HERMETIC, mirroring `Kazi.CLIApplyProposalRefTest`: the inner harness is a
  local stub script, the workspace a non-git tmp dir -- no real claude, no
  network, no git.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.{ProposedGoal, Run}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    work =
      Path.join(System.tmp_dir!(), "kazi-session-attr-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    {:ok, work: work}
  end

  # The orchestrator's step 1: `plan --json` in caller-drafts mode, naming the
  # goal via the payload's goal_id (T39.1). Returns the minted proposal_ref.
  defp plan_proposal(goal_id, extra_args \\ []) do
    payload =
      ~s({"goal_id":"#{goal_id}","idea":"converge the #{goal_id} fixture",) <>
        ~s("predicates":[{"id":"code","provider":"test_runner",) <>
        ~s("config":{"cmd":"sh","args":["-c","test -f fixed.txt"]}}]})

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["plan", "--json", "--predicates", payload | extra_args]) == 0
      end)

    assert {:ok, draft} = Jason.decode(String.trim(out))
    draft["proposal_ref"]
  end

  defp approve(ref) do
    capture_io(fn -> assert Kazi.CLI.run(["approve", ref, "--json"]) == 0 end)
    ref
  end

  # A harness stub that fixes the goal: creates the marker file the code
  # predicate checks (cwd = the workspace, via the adapter's System.cmd cd:).
  defp write_fixing_harness(work) do
    path = Path.join(work, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp run_opts(work) do
    [
      adapter_opts: [command: write_fixing_harness(work)],
      reobserve_interval_ms: 5,
      await_timeout: 15_000
    ]
  end

  describe "plan --session-name persists session_name on the proposed_goals row" do
    test "an explicit --session-name is persisted on the proposal" do
      ref = plan_proposal("session-attr-explicit", ["--session-name", "plan-session-a"])

      assert %ProposedGoal{session_name: "plan-session-a"} =
               Repo.get_by!(ProposedGoal, proposal_ref: ref)
    end

    test "absent the flag, CLAUDE_CODE_SESSION_ID is auto-detected and persisted" do
      System.put_env("CLAUDE_CODE_SESSION_ID", "claude-env-session")
      on_exit(fn -> System.delete_env("CLAUDE_CODE_SESSION_ID") end)

      ref = plan_proposal("session-attr-env-fallback")

      assert %ProposedGoal{session_name: "claude-env-session"} =
               Repo.get_by!(ProposedGoal, proposal_ref: ref)
    end
  end

  describe "apply <proposal-ref> records the proposal's provenance on the runs row" do
    test "records the proposal_ref, and falls back to the proposal's session_name",
         %{work: work} do
      ref =
        "session-attr-apply-ref"
        |> plan_proposal(["--session-name", "planner-session"])
        |> approve()

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"], run_opts(work))
        end)

      assert code == 0

      run = Repo.get_by!(Run, goal_ref: "session-attr-apply-ref")
      assert run.proposal_ref == ref
      assert run.session_name == "planner-session"
    end

    test "an applying session's own --session-name wins over the proposal's", %{work: work} do
      ref =
        "session-attr-apply-ref-own-name"
        |> plan_proposal(["--session-name", "planner-session"])
        |> approve()

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", ref, "--workspace", work, "--session-name", "applier-session", "--json"],
            run_opts(work)
          )
        end)

      assert code == 0

      run = Repo.get_by!(Run, goal_ref: "session-attr-apply-ref-own-name")
      assert run.proposal_ref == ref
      assert run.session_name == "applier-session"
    end
  end

  describe "apply <goal-file> leaves runs.proposal_ref nil (unchanged behavior)" do
    test "a plain goal-file path never carries a proposal_ref", %{work: work} do
      goal_file = Path.join(work, "session-attr-path.goal.toml")

      File.write!(goal_file, """
      id = "session-attr-path-fixture"
      name = "path fixture"

      [scope]
      workspace = "#{work}"

      [[predicate]]
      id = "code"
      provider = "custom_script"
      verdict = "exit_zero"
      cmd = "sh"
      args = ["-c", "test -f fixed.txt"]
      """)

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"], run_opts(work))
        end)

      assert code == 0

      run = Repo.get_by!(Run, goal_ref: "session-attr-path-fixture")
      assert run.proposal_ref == nil
    end
  end
end
