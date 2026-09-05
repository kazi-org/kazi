defmodule Kazi.CLILaneContractTest do
  @moduledoc """
  TKE.1 (ADR-0086/ADR-0087, docs/plans/E-KAZI-ENTRYPOINT.md): `--lane-contract
  <path>` (or `KAZI_LANE_CONTRACT`) -- the governed-lane task_sha match check.

  Mirrors `T73.5`'s CLI-flag-or-env pattern and its refusal style
  (`test/kazi/cli_single_node_test.exs`'s `refuse_single_node_fleet/2`
  precedent). Five contracts, each driven through the REAL CLI exec core
  (`Kazi.CLI.run/2`), output captured with `ExUnit.CaptureIO`:

    1. A workspace whose checked-out HEAD differs from the contract's
       `task_sha` refuses BEFORE any harness dispatch (a never-called stub
       proves it), exit 1, `--json` carries `reason:
       "lane_contract_violation"`, `kind: "wrong_task_sha"`, naming both
       shas; human output mirrors it on stderr, `error:`-prefixed.
    2. A workspace whose HEAD MATCHES `task_sha` proceeds exactly as today
       (converges, dispatches the harness, still carries `single_node: true`).
    3. `--lane-contract` absent is byte-identical to today (no
       lane-contract-shaped key ever appears).
    4. A LONE `--lane-contract` with NO `--single-node` is itself a refusal
       -- before the goal or the contract file is even opened -- `reason:
       "lane_contract_requires_single_node"`.
    5. `--single-node` WITHOUT `--in-place` is a documented no-op: the flag
       is accepted but the check is never performed (no worktree-free edit
       site exists yet to compare a HEAD against), even against a
       deliberately wrong `task_sha`.

  Plus: an unreadable/unparsable/`task_sha`-less contract fails CLOSED
  (`kind: "invalid_contract"`), never open (fail-open would defeat the whole
  point of a governed-lane gate).

  HERMETIC: a real (throwaway) git repo per test -- `git rev-parse HEAD`
  needs one -- but no network, no real harness beyond a tiny shell stub, and
  the read-model runs through the Ecto sandbox.
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
  # 1/5 -- wrong task_sha refuses before any harness dispatch
  # ===========================================================================

  describe "a workspace whose HEAD differs from task_sha" do
    test "refuses before dispatch: exit 1, JSON reason+kind+both shas, no harness call",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      actual_sha = head_sha(work)
      wrong_sha = String.duplicate("a", 40)
      goal_file = write_goal_file(tmp_dir, work)
      contract = write_contract_file(tmp_dir, wrong_sha)

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
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "wrong_task_sha"
      assert payload["task_sha"] == wrong_sha
      assert payload["actual_sha"] == actual_sha

      refute File.exists?(harness_called_marker(tmp_dir)),
             "the lane-contract guard must fire BEFORE any dispatch"
    end

    test "human output mirrors the refusal on stderr, error:-prefixed, naming both shas",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      actual_sha = head_sha(work)
      wrong_sha = String.duplicate("b", 40)
      goal_file = write_goal_file(tmp_dir, work)
      contract = write_contract_file(tmp_dir, wrong_sha)

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--lane-contract",
                     contract
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert out =~ "error:"
      assert out =~ wrong_sha
      assert out =~ actual_sha
      refute File.exists?(harness_called_marker(tmp_dir))
    end

    test "KAZI_LANE_CONTRACT is the flag's equivalent", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      wrong_sha = String.duplicate("c", 40)
      goal_file = write_goal_file(tmp_dir, work)
      contract = write_contract_file(tmp_dir, wrong_sha)
      System.put_env("KAZI_LANE_CONTRACT", contract)

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
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "wrong_task_sha"
      refute File.exists?(harness_called_marker(tmp_dir))
    after
      System.delete_env("KAZI_LANE_CONTRACT")
    end

    test "the --lane-contract flag wins over KAZI_LANE_CONTRACT when both are set",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work)
      correct_contract = write_contract_file(tmp_dir, sha)
      env_contract = write_contract_file(tmp_dir, String.duplicate("d", 40))
      System.put_env("KAZI_LANE_CONTRACT", env_contract)

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
                     "--lane-contract",
                     correct_contract,
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
    after
      System.delete_env("KAZI_LANE_CONTRACT")
    end
  end

  # ===========================================================================
  # 2/5 -- a matching task_sha proceeds exactly as today
  # ===========================================================================

  describe "a workspace whose HEAD matches task_sha" do
    test "converges, dispatches the harness, and still carries single_node: true",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work)
      contract = write_contract_file(tmp_dir, sha)

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
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["single_node"] == true
      assert payload["reason"] == nil
      refute Map.has_key?(payload, "kind")
      assert File.exists?(Path.join(work, "fixed.txt")), "the harness DID run"
    end
  end

  # ===========================================================================
  # 3/5 -- --lane-contract absent is byte-identical to today
  # ===========================================================================

  describe "--lane-contract absent" do
    test "single_node --in-place on a real git workspace runs unaffected, no lane-contract key",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)

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
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["single_node"] == true
      assert payload["reason"] == nil
      refute Map.has_key?(payload, "kind")
      refute Map.has_key?(payload, "task_sha")
      refute Map.has_key?(payload, "actual_sha")
    end
  end

  # ===========================================================================
  # 4/5 -- a lone --lane-contract with no --single-node is itself a refusal
  # ===========================================================================

  describe "a lone --lane-contract with no --single-node" do
    test "refuses before the goal or the contract is ever opened: exit 1, JSON reason",
         %{tmp_dir: tmp_dir} do
      goal_file = Path.join(tmp_dir, "does-not-exist.goal.toml")
      contract = Path.join(tmp_dir, "does-not-exist-contract.json")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--lane-contract", contract, "--json"],
                   []
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_requires_single_node"
      assert payload["error"] =~ "--single-node"
      # Proves the contract was never opened AND the (nonexistent) goal was
      # never loaded -- neither a "could not load" nor an "invalid" complaint
      # about either path appears anywhere in the refusal.
      refute payload["error"] =~ "invalid"
      refute payload["error"] =~ "could not"
    end

    test "human output mirrors the refusal on stderr, error:-prefixed", %{tmp_dir: tmp_dir} do
      goal_file = Path.join(tmp_dir, "does-not-exist.goal.toml")
      contract = Path.join(tmp_dir, "does-not-exist-contract.json")

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--lane-contract", contract], []) == 1
        end)

      assert out =~ "error:"
      assert out =~ "--single-node"
    end
  end

  # ===========================================================================
  # 5/5 -- --single-node without --in-place: accepted but INERT
  # ===========================================================================

  describe "--single-node without --in-place" do
    test "a deliberately wrong task_sha does NOT refuse -- documented no-op, not silently ignored",
         %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "plain")
      File.mkdir_p!(work)
      goal_file = write_goal_file(tmp_dir, work)
      contract = write_contract_file(tmp_dir, String.duplicate("f", 40))

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["single_node"] == true
      assert payload["reason"] == nil
      refute Map.has_key?(payload, "kind")
    end
  end

  # ===========================================================================
  # An unparsable/incomplete contract fails CLOSED
  # ===========================================================================

  describe "an unparsable/incomplete lane contract" do
    test "missing task_sha refuses with kind invalid_contract, no dispatch", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      contract = Path.join(tmp_dir, "no-task-sha.json")
      File.write!(contract, Jason.encode!(%{schema_version: 1, run_id: "r1"}))

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
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "invalid_contract"
      refute File.exists?(harness_called_marker(tmp_dir))
    end

    test "a nonexistent contract path refuses with kind invalid_contract, no dispatch",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      contract = Path.join(tmp_dir, "does-not-exist.json")

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
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "invalid_contract"
      refute File.exists?(harness_called_marker(tmp_dir))
    end

    test "invalid JSON refuses with kind invalid_contract, no dispatch", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      contract = Path.join(tmp_dir, "not-json.json")
      File.write!(contract, "{not valid json")

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
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "invalid_contract"
      refute File.exists?(harness_called_marker(tmp_dir))
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  # A throwaway real git repo with one commit -- `git rev-parse HEAD` needs a
  # real repo; mirrors `cli_workspace_guard_test.exs`'s `primary_repo/1`.
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

  # A predicate that FAILS at t0 (no fixed.txt) so the goal is non-vacuous,
  # satisfied by a stub harness writing the file into the workspace cwd --
  # mirrors `cli_single_node_test.exs`'s `write_serial_goal_file/1`.
  defp write_goal_file(tmp_dir, workspace) do
    path =
      Path.join(tmp_dir, "lane-contract-fixture-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-lane-contract-fixture"
    name = "CLI lane-contract fixture"

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

  # A contract.json-shaped fixture mirroring hq's `lane.sh` `contract_meta`
  # shape (schema_version, run_id, task, task_sha, goal, predicates, budget,
  # ...) -- kazi's parsing is permissive about every field except `task_sha`,
  # so the rest is present only for fixture realism.
  defp write_contract_file(tmp_dir, task_sha) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        schema_version: 1,
        run_id: "run-#{System.unique_integer([:positive])}",
        task: "TKE.1 fixture",
        task_sha: task_sha,
        goal: "cli-lane-contract-fixture",
        predicates: ["code"]
      })
    )

    path
  end

  # A stub harness that records it was invoked (the refusal tests assert the
  # marker is ABSENT) -- mirrors `cli_workspace_guard_test.exs`'s
  # `never_called_harness/1`.
  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", "touch #{harness_called_marker(tmp_dir)}\nexit 0")
  end

  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
