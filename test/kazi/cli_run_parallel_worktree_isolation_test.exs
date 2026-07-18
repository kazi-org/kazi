defmodule Kazi.CLIRunParallelWorktreeIsolationTest do
  @moduledoc """
  T59.9 (#937 Gap F): `kazi apply --parallel` on a `[[group]]`-only goal
  MATERIALIZES one linked git worktree PER PARTITION on the production path —
  none of them the passed `--workspace` root.

  #937 comment 3 (v1.127.0) observed 9-10 agents sharing ONE cwd for a
  `[[group]]`-only goal: the worktree-per-partition machinery
  (`Kazi.Scheduler.Worktree.wrap/2`, T21.4/T54.1) existed, but the CLI parallel
  path composed the scheduler opts WITHOUT a `:worktree` key, so
  `compose_reconciler/3` skipped the isolation layer and handed every group the
  same workspace root. `run_goal_parallel/4` now injects a default worktree
  (`repo: workspace`) whenever the caller injected no `:reconciler`/`:worktree`
  seam and the workspace is a git work-tree — exactly the production path.

  This is a Tier-2 boundary test: it drives the REAL CLI exec core
  (`Kazi.CLI.run/2`) — NO injected reconciler, NO injected worktree — against a
  FIXTURE git repo and a two-group goal. A capturing predicate provider records
  the `context[:workspace]` (the cwd) each group's predicate evaluates in, WHICH
  IS the per-partition worktree the scheduler created. The two groups therefore
  report two DISTINCT worktree paths, both under the managed base dir, neither
  the `--workspace` root — the direct refutation of the shared-cwd symptom.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Repo

  # A hermetic graph source (no repo-map/filesystem scan): each group's fallback
  # term maps to a fixed file list. A single-group sub-goal is one partition
  # regardless, so this only keeps partitioning off the real repo-map.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, _opts) do
      files = terms |> Enum.map(&to_string/1) |> Enum.map(&FileRef.new/1)
      Survey.new(:graph, files: files)
    end
  end

  # A `:custom_script` provider that records the workspace (cwd) it evaluates in
  # to the test (via app env, since each partition reconciles in a spawned
  # process) before delegating to the real provider. Evaluation runs INSIDE the
  # partition's worktree wrapper, so the recorded path is the partition's worktree.
  defmodule WorkspaceProbeProvider do
    @moduledoc false
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(predicate, context) do
      case Application.get_env(:kazi, :worktree_probe_test_pid) do
        pid when is_pid(pid) -> send(pid, {:probe_workspace, context[:workspace]})
        _ -> :ok
      end

      Kazi.Providers.CustomScript.evaluate(predicate, context)
    end
  end

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  setup :checkout_sandbox

  @tag :tmp_dir
  test "a two-group --parallel run materializes two distinct worktrees, none the workspace root",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:kazi, :worktree_probe_test_pid, self())
    on_exit(fn -> Application.delete_env(:kazi, :worktree_probe_test_pid) end)

    repo = init_repo(tmp_dir)
    goal_file = write_two_group_goal_file(repo)
    harness_stub = write_harness_stub(repo)

    # NO :reconciler and NO :worktree injected — exactly the production path. Only
    # a hermetic graph source + the per-goal run opts (stub harness, capturing
    # provider) are seams, and neither suppresses the default worktree the CLI now
    # injects for a git workspace.
    inject_opts = [
      graph_source: {TermSource, []},
      reconcile_timeout: 30_000,
      run_opts: [
        persist?: false,
        adapter_opts: [command: harness_stub],
        providers: %{custom_script: WorkspaceProbeProvider},
        reobserve_interval_ms: 5,
        await_timeout: 20_000
      ]
    ]

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 [
                   "apply",
                   goal_file,
                   "--workspace",
                   repo,
                   "--parallel",
                   "--allow-primary-workspace",
                   "--no-preflight"
                 ],
                 inject_opts
               ) == 0
      end)

    assert out =~ "COLLECTIVE CONVERGED"

    # The discriminating assertion: the two groups evaluated in TWO DISTINCT
    # worktrees, each a git-managed checkout under the base dir, NEITHER the
    # workspace root (the shared-cwd symptom #937 comment 3 reported).
    worktrees = drain_workspaces([]) |> Enum.uniq()
    base_dir = Kazi.Scheduler.Worktree.default_base_dir()
    repo_abs = Path.expand(repo)

    isolated =
      Enum.filter(worktrees, fn ws ->
        is_binary(ws) and String.starts_with?(Path.expand(ws), Path.expand(base_dir))
      end)

    assert length(isolated) == 2,
           "expected two distinct per-partition worktrees under #{base_dir}, got: #{inspect(worktrees)}"

    Enum.each(isolated, fn ws ->
      # Each partition's cwd is a managed worktree dir (its name is the scheduler's
      # per-partition `Worktree.slug_for/1` slug), NOT the shared workspace root —
      # the worktrees are torn down at partition terminal (#1053), so this asserts
      # the recorded path rather than re-`git`-ing a now-removed dir.
      refute Path.expand(ws) == repo_abs,
             "a partition ran in the workspace root #{repo_abs} instead of an isolated worktree"

      assert Path.basename(ws) =~ ~r/^p-/,
             "worktree dir #{ws} is not a per-partition managed worktree (Worktree.slug_for prefix)"
    end)
  end

  # Drain every {:probe_workspace, _} the capturing provider sent this run.
  defp drain_workspaces(acc) do
    receive do
      {:probe_workspace, ws} -> drain_workspaces([ws | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A minimal fixture git repo with one commit so `HEAD` exists for `worktree add`.
  defp init_repo(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@kazi"])
    git!(dir, ["config", "user.name", "kazi test"])
    File.write!(Path.join(dir, "README.md"), "fixture\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  defp git!(dir, args), do: {_o, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  # A two-group goal (no `needs` -> one fully-parallel frontier of two groups).
  # Each group's predicate fails at t0 (no fixed.txt) so the goal is non-vacuous
  # and reconciles; the stub harness writes the file in the group's OWN worktree
  # cwd so both converge independently.
  defp write_two_group_goal_file(repo) do
    path = Path.join(repo, "two_group_goal.toml")

    File.write!(path, """
    id = "cli-parallel-worktree-iso"
    name = "CLI --parallel isolates each group in its own worktree"

    [scope]
    workspace = "#{repo}"

    [[group]]
    id = "alpha"
    name = "Alpha"

    [[group]]
    id = "beta"
    name = "Beta"

    [[predicate]]
    id = "alpha-code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    group = "alpha"

    [[predicate]]
    id = "beta-code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    group = "beta"
    """)

    path
  end

  # A stub harness that makes the failing predicate pass (writes fixed.txt in the
  # worktree cwd), so each group's reconcile converges in one iteration.
  defp write_harness_stub(repo) do
    path = Path.join(repo, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
