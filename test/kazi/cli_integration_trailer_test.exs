defmodule Kazi.CLIIntegrationTrailerTest do
  @moduledoc """
  TKE.4 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2): trailer VALUE computation
  for TKE.3's structured "integration action". kazi computes the value only
  -- stamping it onto an actual commit is the hook's git-level mechanics
  (decided design, 3.2), never kazi's.

  Default: reuse the literal `Plan-row: <id>` key sire's own Intake gate
  already checks for, using the lane contract's sire-style task id (the
  contract's `"task"` field, TKE.1) when present; fall back to `Kazi-Goal:
  <goal-id>` when the contract carries no such id (or no `--lane-contract`
  was given at all).

  HERMETIC: a real (throwaway) git repo per test, a tiny shell stub standing
  in for the `--integration-command` hook -- no network, no real `gh`/GitHub
  credential anywhere.
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
  # a sire-style task id in the contract -> "Plan-row: <id>"
  # ===========================================================================

  describe "the lane contract names a sire-style task id" do
    test "the hook receives trailer \"Plan-row: <id>\"", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      contract = write_contract_file(tmp_dir, base_sha, task: "TKE.4 fixture row")
      stdin_capture = Path.join(tmp_dir, "hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {"pr": 7}}))

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
                     "--lane-contract",
                     contract,
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
      assert payload["integration"]["landed"] == true

      assert File.exists?(stdin_capture), "the hook must have been invoked"
      assert {:ok, action} = Jason.decode(File.read!(stdin_capture))
      assert action["trailer"] == "Plan-row: TKE.4 fixture row"
      assert action["pr_body"] =~ "Plan-row: TKE.4 fixture row"
    end
  end

  # ===========================================================================
  # no task id (goal id only) -> "Kazi-Goal: <goal-id>"
  # ===========================================================================

  describe "the lane contract carries no sire-style task id" do
    test "the hook receives trailer \"Kazi-Goal: <goal-id>\"", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      contract = write_contract_file(tmp_dir, base_sha, task: nil)
      stdin_capture = Path.join(tmp_dir, "hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {"pr": 8}}))

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
                     "--lane-contract",
                     contract,
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
      assert payload["integration"]["landed"] == true

      assert File.exists?(stdin_capture)
      assert {:ok, action} = Jason.decode(File.read!(stdin_capture))
      assert action["trailer"] == "Kazi-Goal: cli-integration-trailer-fixture"
    end
  end

  describe "no --lane-contract at all" do
    test "the hook receives the generic \"Kazi-Goal: <goal-id>\" trailer, unchanged",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
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
                   adapter_opts: [command: committing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["integration"]["landed"] == true
      assert {:ok, action} = Jason.decode(File.read!(stdin_capture))
      assert action["trailer"] == "Kazi-Goal: cli-integration-trailer-fixture"
    end
  end

  # ===========================================================================
  # subprocess spy: kazi itself never calls `git commit`/`git config` in lane
  # mode -- computing the trailer value and stamping it are different steps,
  # and only the first is kazi's (decided design, 3.2).
  # ===========================================================================

  describe "kazi's own subprocess calls in lane mode" do
    test "no git commit/git config call originates from kazi itself, only rev-parse",
         %{tmp_dir: tmp_dir} do
      real_git = System.find_executable("git") || raise "git not found on PATH"
      work = git_repo_fixture(tmp_dir)
      base_sha = head_sha(work)
      goal_file = write_goal_file(tmp_dir, work, base_sha)
      contract = write_contract_file(tmp_dir, base_sha, task: "TKE.4 spy fixture")
      stdin_capture = Path.join(tmp_dir, "hook-stdin.json")
      hook = succeeding_hook(tmp_dir, stdin_capture, ~s({"landed": true, "refs": {"pr": 1}}))

      spy_log = Path.join(tmp_dir, "git-spy.log")
      spy_dir = Path.join(tmp_dir, "spybin")
      File.mkdir_p!(spy_dir)

      spy_git = Path.join(spy_dir, "git")

      File.write!(spy_git, """
      #!/bin/sh
      echo "$@" >> #{inspect(spy_log)}
      exec #{inspect(real_git)} "$@"
      """)

      File.chmod!(spy_git, 0o755)

      # The harness (fixture stand-in for the coding agent) uses the REAL git
      # binary directly, bypassing the spy -- only kazi's own bare `git`
      # invocations (resolved via PATH) are captured, isolating kazi's own
      # subprocess calls from the harness's/fixture's.
      harness = real_git_committing_harness(tmp_dir, real_git)

      original_path = System.get_env("PATH")
      System.put_env("PATH", spy_dir <> ":" <> original_path)

      out =
        try do
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
                       "--lane-contract",
                       contract,
                       "--integration-command",
                       hook,
                       "--json"
                     ],
                     adapter_opts: [command: harness],
                     reobserve_interval_ms: 5,
                     await_timeout: 15_000
                   ) == 0
          end)
        after
          System.put_env("PATH", original_path)
        end

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["integration"]["landed"] == true

      spy_lines =
        if File.exists?(spy_log) do
          spy_log |> File.read!() |> String.split("\n", trim: true)
        else
          []
        end

      # Extract the actual git SUBCOMMAND per invocation (skipping a leading
      # `-C <path>`, since the tmp_dir path itself can incidentally contain
      # substrings like "commit" from the test's own name -- matching on the
      # whole line would produce a false positive there).
      subcommands =
        Enum.map(spy_lines, fn line ->
          case String.split(line, " ") do
            ["-C", _path | rest] -> List.first(rest)
            [cmd | _] -> cmd
          end
        end)

      refute "commit" in subcommands,
             "kazi itself must never call `git commit` in lane mode: #{inspect(spy_lines)}"

      refute "config" in subcommands,
             "kazi itself must never call `git config` in lane mode: #{inspect(spy_lines)}"

      refute "push" in subcommands,
             "kazi itself must never call `git push` in lane mode: #{inspect(spy_lines)}"

      assert "rev-parse" in subcommands,
             "expected kazi's own rev-parse calls (current_branch/workspace_head_sha) to " <>
               "show up in the spy log: #{inspect(spy_lines)}"
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
      Path.join(
        tmp_dir,
        "integration-trailer-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-integration-trailer-fixture"
    name = "CLI integration-trailer fixture"

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

  # A contract.json-shaped fixture mirroring hq's `lane.sh` `contract_meta`
  # shape. `task: nil` omits the field entirely (mirroring a dispatcher that
  # has no sire-style task id to give -- the generic hq session-container
  # case), matching TKE.1's/TKE.4's "absent means fall back" contract.
  defp write_contract_file(tmp_dir, task_sha, task: task) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    base_fields = %{
      schema_version: 1,
      run_id: "run-#{System.unique_integer([:positive])}",
      task_sha: task_sha,
      goal: "cli-integration-trailer-fixture",
      predicates: ["code"]
    }

    fields = if task, do: Map.put(base_fields, :task, task), else: base_fields

    File.write!(path, Jason.encode!(fields))
    path
  end

  defp committing_harness(tmp_dir) do
    write_stub(tmp_dir, "committing", """
    echo "the converged fix" > fixed.txt
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -m "fix" --quiet
    exit 0
    """)
  end

  # Same as `committing_harness/1` but calls the REAL git binary by absolute
  # path, so the PATH-installed spy `git` (which only intercepts bare `git`
  # invocations, i.e. kazi's own) never sees the harness's own commit.
  defp real_git_committing_harness(tmp_dir, real_git) do
    write_stub(tmp_dir, "real-git-committing", """
    echo "the converged fix" > fixed.txt
    #{real_git} add -A
    #{real_git} -c user.email=t@example.com -c user.name=t commit -m "fix" --quiet
    exit 0
    """)
  end

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
