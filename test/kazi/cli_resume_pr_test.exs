defmodule Kazi.CLIResumePRTest do
  @moduledoc """
  TKE.5 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2): resume handle / run-lineage.

  A lane contract's `resume_pr` field (or `--resume-pr <ref>`/`KAZI_RESUME_PR`)
  names an already-open PR/branch a `kazi apply` invocation continues against.
  Kazi never calls `gh`/the GitHub API to verify it (no GitHub credential in
  kazi, ever, in lane mode) -- verification is LOCAL only: kazi's own run
  registry (a prior run must have recorded LANDING that PR via the TKE.3
  `--integration-command` hook) plus a local git ancestry check.

  HERMETIC: a real (throwaway) git repo per test, the same stub-hook pattern
  `cli_lane_integration_hook_test.exs` uses -- no network, no real `gh`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # the acceptance scenario: invocation 1 opens PR #N, invocation 2 resumes it
  # and is recorded under the SAME lineage
  # ===========================================================================

  describe "invocation 1 lands PR #N, invocation 2 names --resume-pr N" do
    test "invocation 2 is recorded under invocation 1's lineage, not a fresh one",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      hook = succeeding_hook(tmp_dir, ~s({"landed": true, "refs": {"pr": 42}}))

      # Invocation 1: fresh contract, no resume_pr -- converges and opens PR 42.
      out1 =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--integration-command",
                     hook,
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload1} = Jason.decode(String.trim(out1))
      assert payload1["integration"]["refs"]["pr"] == 42

      run1 = RunRegistry.find_by_pr_ref("42")
      assert run1, "invocation 1 must have recorded landing PR 42"
      # A fresh run with no resume_pr is the root of its own lineage.
      assert run1.lineage_id == run1.run_id

      # Invocation 2: a fresh container fixture (a NEW task_sha at the tip of
      # PR #42's branch -- here the same in-place workspace, now one commit
      # further ahead) naming resume_pr: 42. `--single-node --in-place` +
      # `--lane-contract` mirrors TKE.1's fixture shape; resume_pr is read off
      # the SAME contract file.
      task_sha2 = head_sha(work)
      contract = write_lane_contract(tmp_dir, task_sha2, 42)
      # A NEW round of work against the same base -- a review comment asked
      # for more, say -- so the goal isn't vacuous (invocation 1's fix already
      # exists on disk); this is what makes invocation 2 a genuine "later
      # round" of the same task rather than a no-op re-run.
      round2_goal_file = write_round2_goal_file(tmp_dir, work, base_sha)

      out2 =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     round2_goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--lane-contract",
                     contract,
                     "--integration-command",
                     hook,
                     "--json"
                   ],
                   adapter_opts: [command: committing_round2_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload2} = Jason.decode(String.trim(out2))
      assert payload2["status"] == "converged"

      run2 = RunRegistry.find_by_pr_ref("42")
      assert run2.run_id != run1.run_id, "invocation 2 must be its OWN run row"
      # The provable bit: invocation 2's lineage_id is invocation 1's run_id --
      # the read-model records "same logical task, later round", not a fresh,
      # disconnected run.
      assert run2.lineage_id == run1.run_id
    end
  end

  # ===========================================================================
  # refusal: resume_pr names a PR kazi's own registry has never seen
  # ===========================================================================

  describe "--resume-pr names a PR kazi's own run registry has no record of" do
    test "refuses before any predicate observation or harness dispatch", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      dispatch_marker = Path.join(tmp_dir, "dispatched.marker")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--resume-pr",
                     "9999",
                     "--json"
                   ],
                   adapter_opts: [command: marking_harness(tmp_dir, dispatch_marker)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "resume_pr_invalid"
      assert payload["kind"] == "resume_pr_not_found"
      assert payload["resume_pr"] == "9999"
      refute File.exists?(dispatch_marker), "no harness dispatch on a refused resume_pr"
    end

    test "a leading # is normalized away before the registry lookup", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--resume-pr",
                     "#9999",
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["resume_pr"] == "9999"
    end
  end

  # ===========================================================================
  # refusal: resume_pr's branch already looks merged onto the base
  # ===========================================================================

  describe "--resume-pr names a PR whose branch already looks merged onto the base" do
    test "refuses: kind resume_pr_already_landed", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      hook = succeeding_hook(tmp_dir, ~s({"landed": true, "refs": {"pr": 7}}))

      # Land PR 7 for real first, so the registry has a record of it.
      out1 =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--integration-command",
                     hook,
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _} = Jason.decode(String.trim(out1))
      assert RunRegistry.find_by_pr_ref("7")

      # Now the goal's declared base is advanced to the current HEAD (the
      # workspace's checked-out HEAD is now an ancestor of/equal to base) --
      # the local-git signal `already_landed_on_base?/2` treats as "this
      # branch already looks merged", regardless of what the registry knows.
      merged_base_sha = head_sha(work)
      merged_goal_file = write_goal_file(tmp_dir, work, merged_base_sha)

      out2 =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     merged_goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--resume-pr",
                     "7",
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload2} = Jason.decode(String.trim(out2))
      assert payload2["reason"] == "resume_pr_invalid"
      assert payload2["kind"] == "resume_pr_already_landed"
    end
  end

  # ===========================================================================
  # unset: byte-identical to today (fresh lineage per run)
  # ===========================================================================

  describe "no resume_pr resolves (neither flag, env, nor contract field)" do
    test "each run is the root of its own lineage_id", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_no_integration_goal_file(tmp_dir, work)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _} = Jason.decode(String.trim(out))

      [run | _] = RunRegistry.list()
      assert run.lineage_id == run.run_id
      assert run.pr_ref == nil
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp git_repo_fixture(tmp_dir) do
    work = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
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

  defp head_sha(work) do
    {out, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"])
    String.trim(out)
  end

  defp write_goal_file(tmp_dir, workspace, base_sha) do
    path =
      Path.join(tmp_dir, "resume-pr-fixture-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-resume-pr-fixture"
    name = "CLI resume-pr fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [integration]
    mode = "pr"
    base = #{inspect(base_sha)}

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # A second, later-round predicate against the SAME base -- what a resumed
  # invocation actually converges (invocation 1's own fix already exists on
  # disk by the time invocation 2 runs, so re-checking it would be vacuous).
  defp write_round2_goal_file(tmp_dir, workspace, base_sha) do
    path =
      Path.join(tmp_dir, "resume-pr-round2-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-resume-pr-fixture"
    name = "CLI resume-pr fixture, round 2"

    [scope]
    workspace = #{inspect(workspace)}

    [integration]
    mode = "pr"
    base = #{inspect(base_sha)}

    [[predicate]]
    id = "code2"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed2.txt"]
    """)

    path
  end

  defp committing_round2_harness(tmp_dir) do
    write_stub(tmp_dir, "committing-round2", """
    echo "the round-2 fix" > fixed2.txt
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -m "fix round 2" --quiet
    exit 0
    """)
  end

  defp write_no_integration_goal_file(tmp_dir, workspace) do
    path =
      Path.join(
        tmp_dir,
        "resume-pr-no-integration-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-resume-pr-no-integration-fixture"
    name = "CLI resume-pr fixture, no integration"

    [scope]
    workspace = #{inspect(workspace)}

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_lane_contract(tmp_dir, task_sha, resume_pr) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{"task_sha" => task_sha, "resume_pr" => resume_pr})
    )

    path
  end

  # A harness that both satisfies the predicate AND commits, so the fix lands
  # on a real commit ahead of the pinned base.
  defp committing_harness(tmp_dir) do
    write_stub(tmp_dir, "committing", """
    echo "the converged fix" > fixed.txt
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -m "fix" --quiet
    exit 0
    """)
  end

  # Never actually satisfies the predicate -- only used to prove it was never
  # invoked at all (a refused run must dispatch nothing).
  defp marking_harness(tmp_dir, marker_path) do
    write_stub(tmp_dir, "marking", "touch #{marker_path}\nexit 1")
  end

  defp succeeding_hook(tmp_dir, result_json) do
    write_stub(tmp_dir, "succeeding-hook", "echo '#{result_json}'\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
