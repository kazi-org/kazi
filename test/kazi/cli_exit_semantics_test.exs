defmodule Kazi.CLIExitSemanticsTest do
  @moduledoc """
  issue #1407: the CLI's exit code for a worktree-isolated SERIAL `apply` run is
  DECOUPLED from the landing verdict by default — a run that converged but whose
  work failed to land on the base still exits 0 (the failure stays visible via
  `integration.landed == false` + a stderr warning, never via a non-zero exit).
  `--strict-landing` opts back into the pre-#1407 coupling, for a caller (e.g. a
  CI gate) that wants a landing failure to fail the invocation outright.

  Fixture git repos in tmp, no network, no real harness (mirrors
  `Kazi.SerialIntegrationTest`, which exercises the surrounding landing
  contract). `Kazi.SerialIntegrationTest` no longer asserts a coupled exit code
  on its landing-failure fixtures — those cases moved here, tagged, so they can
  be run in isolation (`mix test --only exit_semantics`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  @moduletag :exit_semantics

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "a converged-but-unlanded run exits 0 by default", %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      run_apply(goal_file, work, committing_harness(tmp_dir), [],
        integrate: [integrator: fn _request, _opts -> {:error, :boom} end]
      )

    assert code == 0,
           "a converged-but-unlanded run must exit 0 by default (issue #1407)"

    assert %{"status" => "converged", "integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == false
  end

  test "--strict-landing downgrades a converged-but-unlanded run to exit 1", %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      run_apply(goal_file, work, committing_harness(tmp_dir), ["--strict-landing"],
        integrate: [integrator: fn _request, _opts -> {:error, :boom} end]
      )

    assert code == 1,
           "--strict-landing must couple the exit code back to a landing failure"

    assert %{"status" => "converged", "integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == false
  end

  test "--strict-landing has no effect when landing succeeds", %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      run_apply(goal_file, work, committing_harness(tmp_dir), ["--strict-landing"], [])

    assert code == 0
    assert %{"integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == true
  end

  # --- driving the CLI --------------------------------------------------------

  defp run_apply(goal_file, work, harness, extra_argv, runtime_opts) do
    with_io(fn ->
      Kazi.CLI.run(
        ["apply", goal_file, "--workspace", work, "--json"] ++ extra_argv,
        Keyword.merge(
          [
            adapter_opts: [command: harness],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          ],
          runtime_opts
        )
      )
    end)
    |> then(fn {code, out} -> {out, code} end)
  end

  # --- fixtures ---------------------------------------------------------------

  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "base-#{System.unique_integer([:positive])}")
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

  defp write_goal_file(tmp_dir, workspace) do
    path = Path.join(tmp_dir, "exit-semantics-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "exit-semantics-fixture"
    name = "exit semantics fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp committing_harness(tmp_dir) do
    path = Path.join(tmp_dir, "stub-committing-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    git add fixed.txt
    git commit -q -m "task commit: converged fix"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
