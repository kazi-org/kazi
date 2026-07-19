defmodule Kazi.Scheduler.SerialLandingTest do
  @moduledoc """
  issue #1550: the serial-landing path must thread the goal (and the converged
  predicate vector) into the integrator's `integrate_context`, so the landing
  commit/PR the real `Kazi.Actions.Integrate` action writes names the REAL goal
  id + change summary + converged predicates instead of
  `integrate(unknown-goal): converged change [(none recorded)]`.
  """
  use ExUnit.Case, async: false

  alias Kazi.Scheduler.SerialLanding

  @moduletag :tmp_dir

  test "land/5 threads the goal + vector into the integrator's integrate_context",
       %{tmp_dir: tmp_dir} do
    %{base: base, worktree: worktree, owned_branch: owned_branch} =
      landable_fixture(tmp_dir, "adopt-widgets")

    goal = %Kazi.Goal{id: "adopt-widgets", name: "Spec-coverage discovery goal for widgets"}

    vector =
      Kazi.PredicateVector.new(%{spec_coverage: Kazi.PredicateResult.pass(%{ratio: 1.0})})

    test_pid = self()

    stub_integrator = fn _request, opts ->
      send(test_pid, {:integrator_opts, opts})
      {:ok, %{stub: true, branch: owned_branch}}
    end

    runtime_opts = [integrate: [integrator: stub_integrator]]

    assert {:landed, info} =
             SerialLanding.land(goal, runtime_opts, base, worktree, vector: vector)

    assert info.landed == true
    assert info.task_branch == owned_branch

    assert_received {:integrator_opts, opts}

    assert Keyword.get(opts, :integrate_context) == [goal: goal, vector: vector],
           "the goal + converged vector must reach the integrator so the commit metadata resolves"

    assert Keyword.get(opts, :base_repo) == base
  end

  test "land/5 threads the goal even when no vector is supplied (goal id still resolves)",
       %{tmp_dir: tmp_dir} do
    %{base: base, worktree: worktree} = landable_fixture(tmp_dir, "adopt-novec")

    goal = %Kazi.Goal{id: "adopt-novec", name: "no-vector goal"}
    test_pid = self()

    stub_integrator = fn _request, opts ->
      send(test_pid, {:integrator_opts, opts})
      {:ok, %{stub: true}}
    end

    assert {:landed, _info} =
             SerialLanding.land(goal, [integrate: [integrator: stub_integrator]], base, worktree)

    assert_received {:integrator_opts, opts}
    assert Keyword.get(opts, :integrate_context) == [goal: goal]
  end

  # A base repo on `main` with a seed commit, plus a linked worktree checked out
  # on the goal's owned branch carrying one commit ahead of the base tip — the
  # exact precondition `SerialLanding.land/5` lands (committed work on the
  # kazi-owned task branch, base on a real branch).
  defp landable_fixture(tmp_dir, goal_id) do
    base = Path.join(tmp_dir, "base-#{goal_id}")
    File.mkdir_p!(base)
    git!(base, ["init", "--initial-branch=main"])
    config(base)
    File.write!(Path.join(base, "README.md"), "seed\n")
    git!(base, ["add", "-A"])
    git!(base, ["commit", "-m", "seed"])

    owned_branch = "task/" <> goal_id
    worktree = Path.join(tmp_dir, "wt-#{goal_id}")
    git!(base, ["worktree", "add", "-b", owned_branch, worktree])
    config(worktree)
    File.write!(Path.join(worktree, "feature.txt"), "converged work\n")
    git!(worktree, ["add", "-A"])
    git!(worktree, ["commit", "-m", "task commit: converged work"])

    %{base: base, worktree: worktree, owned_branch: owned_branch}
  end

  defp config(repo) do
    git!(repo, ["config", "user.email", "kazi-test@example.com"])
    git!(repo, ["config", "user.name", "kazi test"])
    git!(repo, ["config", "commit.gpgsign", "false"])
  end

  defp git!(repo, args) do
    {out, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end
end
