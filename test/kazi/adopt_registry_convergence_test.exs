defmodule Kazi.AdoptRegistryConvergenceTest do
  @moduledoc """
  T7.4 — the CONVERGENCE proof for the registry adapter (ADR-0015): a
  registry-derived goal is not just LOADABLE, it is RUNNABLE.

  A tiny fixture catalog declares one capability whose `test` binding checks a
  marker file in a fixture workspace. The marker is absent at t0 (the binding
  FAILS), so the goal is non-vacuous; the stub harness "fixes" the code (creates
  the marker), the binding goes green, and the loop integrates + deploys and
  CONVERGES — driven through `Kazi.Runtime.run/2` with the SAME injectable stub
  seams `Kazi.RuntimeTest` uses (harness binary, local rebase-merge integrator,
  no-op deploy). No real agent, no network: hermetic.

  This closes the loop end-to-end: registry JSON -> Kazi.Adopt.Registry parse +
  to_goal_set -> Kazi.Goal.Loader.from_map -> Kazi.Runtime -> :converged.
  """
  # Real git + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.Adopt.Registry
  alias Kazi.{Goal, Runtime, Scope}
  alias Kazi.Goal.Loader

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "a registry-derived goal converges through Kazi.Runtime via the stub seams",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # The capability's test binding checks a marker file IN THE WORKSPACE. It is
    # absent at t0 (the binding fails), so the goal is non-vacuous and the loop
    # must act. `sh -c "test -f fixed.txt"` exits non-zero until the file exists.
    registry = write_registry(tmp_dir)

    # Parse the registry and map it to a goal SET, exactly as `kazi init` does.
    assert {:ok, [capability]} = Registry.parse(registry)
    assert capability.id == "marker.exists"
    [plan] = Registry.to_goal_set([capability])

    # The generated goal_map round-trips through the real loader.
    assert {:ok, %Goal{} = loaded} = Loader.from_map(plan.goal_map)
    # The declared binding became a real test_runner acceptance predicate.
    [acceptance] = loaded.predicates
    assert acceptance.kind == :tests
    assert acceptance.config[:cmd] == "sh"

    # Bind the loaded goal to the target workspace (init writes a [scope] in the
    # file; here we attach it directly for the run).
    goal = %{loaded | scope: Scope.new(workspace: work)}

    # The harness stub "fixes" the code by creating the marker file the binding
    # checks — red -> green across dispatch.
    harness_stub = write_harness_stub(tmp_dir)
    # A no-op deploy stub: no live predicate, so once code lands the loop deploys
    # and converges.
    deploy_stub = write_noop_deploy_stub(tmp_dir)

    integrator = fn request, _opts ->
      {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               adapter_opts: [command: harness_stub],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               deploy_params: %{service: "s", project: "p", region: "r", source: work},
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    # THE ACCEPTANCE BAR: the registry-derived goal reached :converged.
    assert result.outcome == :converged
    assert :dispatch_agent in result.actions
    assert result.iterations > 0
    # The harness really ran and created the marker the binding checks.
    assert File.exists?(Path.join(work, "fixed.txt"))
  end

  # --- fixtures (mirrors Kazi.RuntimeTest) -------------------------------------

  # A one-capability registry whose binding is a marker-file check the harness
  # stub satisfies — so a registry-derived goal can be driven to convergence
  # hermetically (no Go toolchain, no network).
  defp write_registry(tmp_dir) do
    path = Path.join(tmp_dir, "capabilities.json")

    File.write!(path, """
    {
      "version": 1,
      "capabilities": [
        {
          "id": "marker.exists",
          "name": "the marker file exists after the agent acts",
          "test": {"cmd": "sh", "args": ["-c", "test -f fixed.txt"]}
        }
      ]
    }
    """)

    path
  end

  defp setup_repo(tmp_dir) do
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: work, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: bare)

    %{bare: bare, work: work}
  end

  defp git_config(repo) do
    {_, 0} = System.cmd("git", ["config", "user.email", "kazi-test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "kazi test"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: repo)
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_noop_deploy_stub(tmp_dir) do
    path = Path.join(tmp_dir, "noop_deploy_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\necho deployed\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "reg-merge-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", bare, tmp], stderr_to_stdout: true)
    git_config(tmp)

    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["rebase", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["merge", "--ff-only", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["push", "origin", base], cd: tmp, stderr_to_stdout: true)

    {sha, 0} = System.cmd("git", ["rev-parse", base], cd: tmp)
    File.rm_rf!(tmp)
    String.trim(sha)
  end
end
