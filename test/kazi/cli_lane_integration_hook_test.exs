defmodule Kazi.CLILaneIntegrationHookTest do
  @moduledoc """
  TKE.3 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2, decided design "mode (B)
  everywhere" -- chief-architect ruling 2026-09-05): in-place PR-opening via
  the injectable `--integration-command`/`KAZI_INTEGRATION_COMMAND` hook.

  A governed lane (`--single-node --in-place`) has no separate task worktree
  to land from -- the workspace IS the edit site. On convergence with commits
  ahead of the goal's declared `[integration] base` and `[integration]` mode
  `pr`/`merge`, kazi computes a structured "integration action" and hands it
  to the hook on stdin as JSON (never calling `git push`/`gh pr create`/
  `git commit` itself). See `docs/integration-hook.md` for the schema.

  HERMETIC: a real (throwaway) git repo per test, a tiny shell stub standing
  in for the hook (records its stdin, prints a canned JSON result) -- no
  network, no real `gh`/GitHub credential anywhere.
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
  # hook invoked with correct stdin; success maps into the terminal result
  # ===========================================================================

  describe "convergence with commits ahead of base, [integration] mode pr, hook configured" do
    test "invokes the hook once with the computed action on stdin; success lands",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      stdin_capture = Path.join(tmp_dir, "hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {"pr": 42}}))

      out =
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

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["integration"]["landed"] == true
      assert payload["integration"]["base"] == base_sha
      assert payload["integration"]["task_branch"] == "main"
      assert payload["integration"]["refs"]["pr"] == 42
      refute Map.has_key?(payload["integration"], "reason")

      assert File.exists?(stdin_capture), "the hook must have been invoked"
      assert {:ok, action} = Jason.decode(File.read!(stdin_capture))
      assert action["goal_id"] == "cli-lane-integration-fixture"
      assert action["mode"] == "pr"
      assert action["base"] == base_sha
      assert action["task_branch"] == "main"
      assert action["trailer"] == "Kazi-Goal: cli-lane-integration-fixture"
      assert is_binary(action["pr_title"])
      assert is_binary(action["pr_body"])
      assert action["schema_version"] == 1
    end
  end

  # ===========================================================================
  # hook failure is handled: landed: false, reason surfaces, task branch kept
  # ===========================================================================

  describe "the hook reports failure" do
    test "integration.landed is false, reason surfaces, exit 1, task branch still reported",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)

      hook =
        write_stub(
          tmp_dir,
          "failing-hook",
          ~s(echo '{"landed": false, "reason": "push rejected: non-fast-forward"}')
        )

      out =
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
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      # The predicate itself converged; the exit code is downgraded by the
      # unlanded integration, mirroring `integration.landed == false`'s
      # existing worktree-landing convention (ADR-0065).
      assert payload["status"] == "converged"
      assert payload["integration"]["landed"] == false
      assert payload["integration"]["reason"] == "push rejected: non-fast-forward"
      assert payload["integration"]["task_branch"] == "main"
      assert payload["integration"]["base"] == base_sha
    end

    test "a hook that exits non-zero with no JSON is also a reported failure, never a crash",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      hook = write_stub(tmp_dir, "crashing-hook", "echo 'boom' 1>&2\nexit 7")

      out =
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
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["integration"]["landed"] == false
      assert payload["integration"]["reason"] =~ "integration_hook_failed"
      assert payload["integration"]["reason"] =~ "boom"
    end
  end

  # ===========================================================================
  # missing-hook refusal
  # ===========================================================================

  describe "[integration] wants pr/merge under lane mode but no hook is configured" do
    test "refuses: reason lane_integration_hook_missing, exit 1, task branch still named",
         %{tmp_dir: tmp_dir} do
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
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["integration"]["landed"] == false
      assert payload["integration"]["reason"] == "lane_integration_hook_missing"
      assert payload["integration"]["task_branch"] == "main"
      assert payload["integration"]["base"] == base_sha
    end
  end

  # ===========================================================================
  # nothing ahead of base: no hook invoked, no integration object
  # ===========================================================================

  describe "no commits ahead of the declared base" do
    test "the hook is never invoked and no integration object appears", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      # The predicate converges from an UNCOMMITTED working-tree change -- the
      # fix is real, but there is no new commit ahead of the base to land.
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      stdin_capture = Path.join(tmp_dir, "hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {}}))

      out =
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
                   adapter_opts: [command: passing_uncommitted_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      refute Map.has_key?(payload, "integration")
      refute File.exists?(stdin_capture), "the hook must NEVER be invoked with nothing to land"
    end
  end

  # ===========================================================================
  # flag wins over env
  # ===========================================================================

  describe "--integration-command flag vs KAZI_INTEGRATION_COMMAND" do
    test "the flag wins over the env var when both are set", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)

      env_hook = write_stub(tmp_dir, "env-hook", "exit 9")
      flag_stdin = Path.join(tmp_dir, "flag-hook-stdin.json")
      flag_hook = succeeding_hook(tmp_dir, flag_stdin, ~s({"landed": true, "refs": {}}))
      System.put_env("KAZI_INTEGRATION_COMMAND", env_hook)

      out =
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
                     flag_hook,
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["integration"]["landed"] == true
      assert File.exists?(flag_stdin), "the FLAG's hook must be the one invoked"
    after
      System.delete_env("KAZI_INTEGRATION_COMMAND")
    end

    test "KAZI_INTEGRATION_COMMAND alone is the equivalent of the flag", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      stdin_capture = Path.join(tmp_dir, "env-hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {}}))
      System.put_env("KAZI_INTEGRATION_COMMAND", hook)

      out =
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
                     "--json"
                   ],
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["integration"]["landed"] == true
      assert File.exists?(stdin_capture)
    after
      System.delete_env("KAZI_INTEGRATION_COMMAND")
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

  # `[integration] base = <sha>` pins the pre-fix commit as the base, so the
  # harness's fix commit is unambiguously "ahead of base" regardless of what
  # branch name either resolves to.
  defp write_goal_file(tmp_dir, workspace, base_sha) do
    path =
      Path.join(
        tmp_dir,
        "lane-integration-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-lane-integration-fixture"
    name = "CLI lane-integration-hook fixture"

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

  # A harness that both satisfies the predicate AND commits, so the fix lands
  # on a real commit ahead of the pinned base -- unlike the plain
  # `passing_harness` fixture in `cli_lane_contract_test.exs`, which never
  # commits (that test never exercises landing).
  defp committing_harness(tmp_dir) do
    write_stub(tmp_dir, "committing", """
    echo "the converged fix" > fixed.txt
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -m "fix" --quiet
    exit 0
    """)
  end

  # Satisfies the predicate WITHOUT committing -- the fix is real (a genuine
  # working-tree change) but leaves nothing ahead of the base to land, unlike
  # `committing_harness/1`.
  defp passing_uncommitted_harness(tmp_dir) do
    write_stub(tmp_dir, "passing-uncommitted", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  # A stub `--integration-command` hook: captures its stdin verbatim to
  # `capture_path` and echoes `result_json` on stdout, exit 0.
  defp succeeding_hook(tmp_dir, capture_path, result_json) do
    write_stub(tmp_dir, "succeeding-hook", """
    cat > "#{capture_path}"
    echo '#{result_json}'
    exit 0
    """)
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
