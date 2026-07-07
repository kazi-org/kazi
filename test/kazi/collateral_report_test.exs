defmodule Kazi.CollateralReportTest do
  @moduledoc """
  Issue #860 proposal 3: the out-of-intent diff report. `Kazi.CollateralReport`
  computes the list of files changed during a run that sit OUTSIDE the goal's
  intended write scope (`[scope].write_paths`, or — absent that — outside every
  predicate's own config references), net-deletion entries ranked first: the
  5-line review list a human reads instead of the full diff.

  `kazi apply --json`'s terminal result names this list under the additive
  `collateral` field (`Kazi.CLI`, `docs/schemas/run-result.md`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{CollateralReport, Goal, Predicate, Repo, Scope}

  # ===========================================================================
  # 1. Kazi.CollateralReport.collateral/2 — pure, git-fixture-backed
  # ===========================================================================

  describe "collateral/2 with a declared write_paths" do
    test "a change outside write_paths is reported; a change inside it is not" do
      dir =
        git_repo_with(%{
          "fixed.txt" => "",
          "ios/Auth.plist" => "line1\nline2\nline3\n"
        })

      # In-scope edit (write_paths covers it) — should NOT appear.
      File.write!(Path.join(dir, "fixed.txt"), "the converged fix")
      # Out-of-scope edit: a net-deletion (2 lines removed, 0 added).
      File.write!(Path.join(dir, "ios/Auth.plist"), "line1\n")

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})],
          scope: Scope.new(write_paths: ["fixed.txt"])
        )

      assert [entry] = CollateralReport.collateral(goal, dir)
      assert entry.path == "ios/Auth.plist"
      assert entry.net_deletion == true
      assert entry.deletions == 2
      assert entry.additions == 0
    end

    test "no changes outside write_paths yields an empty report" do
      dir = git_repo_with(%{"fixed.txt" => ""})
      File.write!(Path.join(dir, "fixed.txt"), "the converged fix")

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})],
          scope: Scope.new(write_paths: ["fixed.txt"])
        )

      assert CollateralReport.collateral(goal, dir) == []
    end

    test "net-deletion entries rank before pure-addition entries" do
      dir =
        git_repo_with(%{
          "fixed.txt" => "",
          "a_deleted.txt" => "one\ntwo\nthree\n",
          "b_added.txt" => "x\n"
        })

      # A→ net deletion (removes 2, adds 0); B → pure addition (adds 3, removes 0).
      File.write!(Path.join(dir, "a_deleted.txt"), "one\n")
      File.write!(Path.join(dir, "b_added.txt"), "x\ny\nz\nw\n")

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})],
          scope: Scope.new(write_paths: ["fixed.txt"])
        )

      assert [%{path: "a_deleted.txt"}, %{path: "b_added.txt"}] =
               CollateralReport.collateral(goal, dir)
    end
  end

  describe "collateral/2 with no write_paths declared (referenced-by-predicate fallback)" do
    test "a path a predicate's config references is treated as in-scope" do
      dir = git_repo_with(%{"lib/app.ex" => "old", "ios/Auth.plist" => "keep"})
      File.write!(Path.join(dir, "lib/app.ex"), "new code")
      File.write!(Path.join(dir, "ios/Auth.plist"), "tampered")

      goal =
        Goal.new("g",
          predicates: [
            Predicate.new(:code, :custom_script,
              config: %{cmd: "sh", args: ["-c", "test -f lib/app.ex"]}
            )
          ]
        )

      assert [%{path: "ios/Auth.plist"}] = CollateralReport.collateral(goal, dir)
    end

    test "with nothing referenced and no write_paths, every change is collateral" do
      dir = git_repo_with(%{"unrelated.txt" => "old"})
      File.write!(Path.join(dir, "unrelated.txt"), "new")

      goal =
        Goal.new("g", predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})])

      assert [%{path: "unrelated.txt"}] = CollateralReport.collateral(goal, dir)
    end
  end

  test "collateral/2 degrades to [] for a non-git workspace" do
    goal =
      Goal.new("g", predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})])

    assert CollateralReport.collateral(goal, "/nonexistent/path") == []
  end

  # ===========================================================================
  # 2. kazi apply --json names the field on the terminal result (Kazi.CLI)
  # ===========================================================================

  describe "kazi apply --json — the terminal result's collateral field" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    @describetag :tmp_dir

    test "names an out-of-write-scope edit under collateral on convergence", %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(work)
      git_init(work)

      File.write!(Path.join(work, "unrelated.txt"), "line1\nline2\nline3\n")
      {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
      {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)

      harness_stub = Path.join(tmp_dir, "stub_harness.sh")

      File.write!(harness_stub, """
      #!/bin/sh
      echo "the converged fix" > fixed.txt
      echo "line1" > unrelated.txt
      exit 0
      """)

      File.chmod!(harness_stub, 0o755)

      goal_file = Path.join(tmp_dir, "goal.toml")

      File.write!(goal_file, """
      id = "cli-collateral"
      name = "CLI --json collateral field"

      [scope]
      workspace = "#{work}"
      write_paths = ["fixed.txt"]

      [[predicate]]
      id = "code"
      provider = "custom_script"
      cmd = "sh"
      args = ["-c", "test -f fixed.txt"]
      """)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", work, "--json"],
                   adapter_opts: [command: harness_stub],
                   reobserve_interval_ms: 5,
                   await_timeout: 10_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"

      assert [%{"path" => "unrelated.txt", "net_deletion" => true}] = payload["collateral"]
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "kazi-collateral-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", dir], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)
  end

  # A real git repo seeded with the given {relative-path => contents} and one
  # commit, so a later edit is measurable as a diff against that commit (the
  # `Kazi.ScopeDiff.base_ref/1` fallback when there is no `origin/main`).
  defp git_repo_with(files) do
    dir = tmp_dir()
    git_init(dir)

    Enum.each(files, fn {rel, contents} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: dir, stderr_to_stdout: true)
    dir
  end
end
