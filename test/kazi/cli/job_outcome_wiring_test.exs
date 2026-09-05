defmodule Kazi.CLI.JobOutcomeWiringTest do
  @moduledoc """
  TKE.7 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.3) CLI-side wiring: `apply
  --json`'s additive `job_outcome` field is present ONLY on a lane-mode run
  and threads the REAL `status` / `integration.landed` / commits-ahead-of-base
  fields into `Kazi.CLI.JobOutcome.classify/1` (pinned exhaustively over
  synthetic inputs by `Kazi.CLI.JobOutcomeTest`). This file drives the REAL
  `Kazi.CLI.run/2` entrypoint to prove the gating and the real-field threading
  -- mirrors `Kazi.CLISingleNodeTest`'s boundary style.

  "Lane mode" here is the INTERIM gate this task builds ahead of TKE.1
  (unbuilt as of this task): `single_node` ON for this run AND `--in-place`.
  TKE.1 will extend it to also require a parsed `--lane-contract` once that
  flag exists.

  NOT exercised here: `status: converged` + `integration.landed: false` ->
  `checkpointed`. Today's in-place path never populates an `integration`
  object at all -- `land_converged_serial/6` short-circuits to the bare
  result whenever `base_workspace == workspace`, which an in-place run always
  is -- so this combination is structurally unreachable through the real CLI
  until TKE.3 lands (the plan's own Wave-KE-A footnote names this gap
  explicitly). `Kazi.CLI.JobOutcomeTest` already pins that mapping over a
  synthetic `integration_landed: false` input.

  HERMETIC: a real (throwaway) git repo + a local shell stub harness -- no
  real `claude`, no network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Presence gate: job_outcome appears ONLY under single_node + in_place
  # ===========================================================================

  describe "presence gate -- lane mode only" do
    test "single_node + in_place + converged carries job_outcome: done", %{tmp_dir: tmp_dir} do
      payload = run_serial_converge(tmp_dir, ["--single-node", "--in-place"])

      assert payload["status"] == "converged"
      assert payload["job_outcome"] == "done"
    end

    test "single_node alone (no --in-place) omits job_outcome", %{tmp_dir: tmp_dir} do
      payload = run_serial_converge(tmp_dir, ["--single-node"])

      assert payload["status"] == "converged"
      refute Map.has_key?(payload, "job_outcome")
    end

    test "--in-place alone (no --single-node) omits job_outcome", %{tmp_dir: tmp_dir} do
      payload = run_serial_converge(tmp_dir, ["--in-place"])

      assert payload["status"] == "converged"
      refute Map.has_key?(payload, "job_outcome")
    end

    test "neither flag omits job_outcome", %{tmp_dir: tmp_dir} do
      payload = run_serial_converge(tmp_dir, [])

      assert payload["status"] == "converged"
      refute Map.has_key?(payload, "job_outcome")
    end
  end

  # ===========================================================================
  # status: stuck under lane mode -- the blocked/checkpointed split
  # ===========================================================================

  describe "status: stuck under lane mode" do
    test "no committed progress -> blocked", %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)
      goal_file = write_unfixable_goal_file(tmp_dir, work)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   lane_argv(goal_file, work),
                   adapter_opts: [command: write_noop_harness(tmp_dir)],
                   stuck_iterations: 2,
                   flake_max_retries: 0,
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "stuck"
      assert payload["job_outcome"] == "blocked"
    end

    test "committed progress survives -> checkpointed", %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)
      goal_file = write_unfixable_goal_file(tmp_dir, work)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   lane_argv(goal_file, work),
                   adapter_opts: [command: write_committing_noop_harness(tmp_dir)],
                   stuck_iterations: 2,
                   flake_max_retries: 0,
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "stuck"
      assert payload["job_outcome"] == "checkpointed"

      {rev_list, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: work)

      assert String.trim(rev_list) |> String.to_integer() > 1,
             "the committing harness must have actually advanced HEAD past the seed commit"
    end
  end

  # ===========================================================================
  # status: over_budget under lane mode -- same split, a distinct loop outcome
  # ===========================================================================

  describe "status: over_budget under lane mode" do
    test "no committed progress -> blocked", %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)
      goal_file = write_unfixable_goal_file(tmp_dir, work, max_iterations: 1)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   lane_argv(goal_file, work),
                   adapter_opts: [command: write_noop_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "over_budget"
      assert payload["job_outcome"] == "blocked"
    end

    test "committed progress survives -> checkpointed", %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)
      goal_file = write_unfixable_goal_file(tmp_dir, work, max_iterations: 1)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   lane_argv(goal_file, work),
                   adapter_opts: [command: write_committing_noop_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "over_budget"
      assert payload["job_outcome"] == "checkpointed"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp lane_argv(goal_file, work) do
    [
      "apply",
      goal_file,
      "--workspace",
      work,
      "--single-node",
      "--in-place",
      "--allow-primary-workspace",
      "--json"
    ]
  end

  # Drives a plain converged serial run over the given extra flags (the
  # presence-gate describe block only varies the flag combination), returning
  # the decoded JSON payload.
  defp run_serial_converge(tmp_dir, extra_flags) do
    goal_file = write_serial_goal_file(tmp_dir)
    harness_stub = write_fixing_harness(tmp_dir)

    runtime_opts = [
      adapter_opts: [command: harness_stub],
      reobserve_interval_ms: 5,
      await_timeout: 15_000,
      persist?: false
    ]

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal_file, "--workspace", tmp_dir, "--json"] ++ extra_flags,
                 runtime_opts
               ) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    payload
  end

  # A plain (non-git) workspace, plain (no `[[group]]`) goal -- the predicate
  # fails at t0 so the goal is non-vacuous, mirroring
  # `Kazi.CLISingleNodeTest`'s serial fixture. Non-git so every flag
  # combination in the presence-gate block (including neither flag, and
  # `--in-place` alone) runs without needing `--allow-primary-workspace`.
  defp write_serial_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "job-outcome-serial-#{System.unique_integer([:positive])}.toml")

    File.write!(path, """
    id = "cli-job-outcome-serial"
    name = "CLI job_outcome serial converge fixture"

    [scope]
    workspace = "#{tmp_dir}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_fixing_harness(tmp_dir) do
    write_stub(tmp_dir, "fixing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  # A REAL throwaway git repo (no remote) -- `Kazi.ScopeDiff.base_ref/1` falls
  # back to the repo's root commit when no `origin/main` exists, so the seed
  # commit below IS the base every commits-ahead count is measured against.
  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "primary-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  # A code predicate that NEVER passes (the fix file is never created) -- the
  # loop cannot converge, so a stuck/over_budget stop is what terminates it.
  defp write_unfixable_goal_file(tmp_dir, workspace, budget_opts \\ []) do
    path = Path.join(tmp_dir, "job-outcome-unfixable-#{System.unique_integer([:positive])}.toml")

    budget_section =
      case Keyword.get(budget_opts, :max_iterations) do
        nil -> ""
        n -> "\n[budget]\nmax_iterations = #{n}\n"
      end

    File.write!(path, """
    id = "cli-job-outcome-unfixable"
    name = "CLI job_outcome never-converges fixture"

    [scope]
    workspace = #{inspect(workspace)}
    #{budget_section}
    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # Runs but never satisfies the predicate and never commits -- HEAD stays at
  # the seed commit, so commits-ahead-of-base is 0.
  defp write_noop_harness(tmp_dir) do
    write_stub(tmp_dir, "noop", "exit 0")
  end

  # Never satisfies the predicate, but DOES leave committed progress each
  # iteration -- HEAD advances past the seed commit, so commits-ahead-of-base
  # is > 0. Unique content per invocation so each iteration's commit is real
  # (an identical-content re-commit would be a no-op `git commit` exit
  # failure); `|| true` keeps that possibility from ever failing the harness.
  defp write_committing_noop_harness(tmp_dir) do
    write_stub(
      tmp_dir,
      "committing-noop",
      "date +%s%N > wip.txt\n" <>
        "git add -A\n" <>
        "git commit -m \"wip progress\" --quiet || true\n" <>
        "exit 0"
    )
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
