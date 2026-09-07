defmodule Kazi.Audit.WorkspaceTest do
  use ExUnit.Case, async: false
  alias Kazi.{Audit, Goal, Predicate, Seal}
  @moduletag :tmp_dir
  setup %{tmp_dir: repo} do
    git(repo, ["init", "-q"])
    git(repo, ["config", "user.email", "test@example.test"])
    git(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "value"), "good\n")

    File.write!(
      Path.join(repo, "check.sh"),
      ~s|if test "$(cat value)" = good; then echo '{"failures":0}'; else echo '{"failures":1}'; fi\n|
    )

    git(repo, ["add", "."])
    git(repo, ["commit", "-qm", "baseline"])
    File.write!(Path.join(repo, "value"), "bad\n")
    patch = git(repo, ["diff"])
    File.write!(Path.join(repo, "value"), "good\n")

    goal =
      Goal.new("fault",
        predicates: [
          Predicate.new("behavior", :custom_script,
            acceptance?: true,
            config: %{
              cmd: "sh",
              args: ["check.sh"],
              verdict: "json",
              path: "$.failures",
              pass_when: "== 0"
            }
          )
        ],
        seal: Seal.new(sealed_inputs: ["check.sh"])
      )

    {:ok, repo: repo, goal: goal, patch: patch}
  end

  test "real provider detects fault and preserves caller and worktree list", c do
    before = git(c.repo, ["worktree", "list", "--porcelain"])

    assert {:ok, %{detected: 1, eligible: 1, inconclusive: 0}} =
             Audit.run_fault(c.repo, "HEAD", c.goal, ["behavior"], c.patch)

    assert git(c.repo, ["worktree", "list", "--porcelain"]) == before
    assert File.read!(Path.join(c.repo, "value")) == "good\n"
    assert git(c.repo, ["status", "--porcelain"]) == ""
  end

  test "invalid patch, missing baseline and checker error are inconclusive", c do
    assert {:inconclusive, _} = Audit.run_fault(c.repo, "HEAD", c.goal, ["behavior"], "invalid")
    assert {:inconclusive, _} = Audit.run_fault(c.repo, "HEAD", c.goal, ["missing"], c.patch)
    p = hd(c.goal.predicates)

    goal = %{
      c.goal
      | predicates: [%{p | config: %{cmd: "missing-checker", verdict: "exit_zero"}}]
    }

    assert {:inconclusive, _} = Audit.run_fault(c.repo, "HEAD", goal, ["behavior"], c.patch)
  end

  test "timeout cleans disposable worktree", c do
    p = hd(c.goal.predicates)

    goal = %{
      c.goal
      | predicates: [%{p | config: %{cmd: "sh", args: ["-c", "sleep 1"], verdict: "exit_zero"}}]
    }

    before = git(c.repo, ["worktree", "list", "--porcelain"])

    assert {:inconclusive, _} =
             Audit.run_fault(c.repo, "HEAD", goal, ["behavior"], c.patch, timeout_ms: 100)

    assert git(c.repo, ["worktree", "list", "--porcelain"]) == before
  end

  test "unprotected and sabotaged verifiers are inconclusive", c do
    assert {:inconclusive, _} =
             Audit.run_fault(c.repo, "HEAD", %{c.goal | seal: nil}, ["behavior"], c.patch)

    File.write!(Path.join(c.repo, "check.sh"), "exit 1\n")
    sabotage = git(c.repo, ["diff"])
    git(c.repo, ["restore", "check.sh"])
    assert {:inconclusive, _} = Audit.run_fault(c.repo, "HEAD", c.goal, ["behavior"], sabotage)

    for constant <- ["exit 0", "exit 1"] do
      File.write!(Path.join(c.repo, "check.sh"), constant <> "\n")
      git(c.repo, ["add", "check.sh"])
      git(c.repo, ["commit", "-qm", "invalid checker"])
      assert {:inconclusive, _} = Audit.run_fault(c.repo, "HEAD", c.goal, ["behavior"], c.patch)
    end
  end

  defp git(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    output
  end
end
