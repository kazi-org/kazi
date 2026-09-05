defmodule Kazi.Goal.ScopeForbiddenPathsTest do
  @moduledoc """
  ADR-0085 (kazi-org/kazi#1695): `[scope].forbidden_paths` — a list of path
  globs the grind loop's own commit/landing tooling refuses to touch, enforced
  TWICE:

    * an automatic `:scope_forbidden_paths` GUARD predicate (the same
      diff-based detection `[scope].deny` already uses, `Kazi.Providers.ScopeGuard`);
    * `Kazi.Actions.Integrate` structurally refuses to LAND a touched path —
      excluded from staging on the legacy commit path, the whole landing
      refused on the `[integration]` verify-then-ship path — not merely a
      detected-after-the-fact report.

  This reproduces the #1695 incident directly: a converged change that
  legitimately touches an in-scope file ALSO drags in an edit to
  `docs/plan.md` (the "grind loop committed a change to docs/plan.md despite a
  prose exclusion list" shape). Both halves of the enforcement are pinned here
  against real git.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Action, Goal, Predicate, PredicateVector, Runtime, Scope}
  alias Kazi.Goal.Loader
  alias Kazi.Actions.Integrate
  alias Kazi.Providers.{CustomScript, ScopeGuard}

  @moduletag :tmp_dir

  # ===========================================================================
  # 1. the loader parses [scope].forbidden_paths
  # ===========================================================================

  describe "Kazi.Goal.Loader parses [scope].forbidden_paths" do
    test "parses into Kazi.Scope" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"forbidden_paths" => ["docs/plan.md", "docs/roadmap.md"]},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.forbidden_paths == ["docs/plan.md", "docs/roadmap.md"]
    end

    test "absent forbidden_paths keeps today's behavior byte-identical" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.forbidden_paths == []
    end

    test "a non-list forbidden_paths is a validation error" do
      assert {:error, msg} =
               Loader.from_map(%{"id" => "g", "scope" => %{"forbidden_paths" => "not-a-list"}})

      assert msg =~ "scope"
    end
  end

  # ===========================================================================
  # 2. Kazi.Scope.guard_predicates/1 synthesis
  # ===========================================================================

  describe "Kazi.Scope.guard_predicates/1" do
    test "an empty forbidden_paths synthesizes no guard" do
      assert Scope.guard_predicates(Scope.new()) == []
    end

    test "a non-empty forbidden_paths synthesizes one :scope_forbidden_paths GUARD predicate" do
      assert [%Predicate{id: :scope_forbidden_paths, kind: :scope_guard, guard?: true} = guard] =
               Scope.guard_predicates(Scope.new(forbidden_paths: ["docs/plan.md"]))

      assert guard.config.forbidden_paths == ["docs/plan.md"]
      assert guard.description =~ "docs/plan.md"
    end

    test "declaring both deny and forbidden_paths synthesizes two distinct guards" do
      guards =
        Scope.guard_predicates(
          Scope.new(deny: ["ios/Auth.plist"], forbidden_paths: ["docs/plan.md"])
        )

      assert [%Predicate{id: :scope_deny_paths}, %Predicate{id: :scope_forbidden_paths}] = guards
    end
  end

  # ===========================================================================
  # 3. Kazi.Providers.ScopeGuard — the guard-predicate half
  # ===========================================================================

  describe "Kazi.Providers.ScopeGuard.evaluate/2 for forbidden_paths" do
    test "fails, naming the offending path, when a forbidden path changed" do
      dir = git_repo_with(%{"docs/plan.md" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "docs/plan.md"), "the grind loop edited the plan")

      predicate =
        Predicate.new(:scope_forbidden_paths, :scope_guard,
          config: %{forbidden_paths: ["docs/plan.md", "docs/roadmap.md"]}
        )

      result = ScopeGuard.evaluate(predicate, %{workspace: dir})

      assert result.status == :fail
      assert result.evidence.changed == ["docs/plan.md"]
      assert result.evidence.reason == :forbidden_path_violation
    end

    test "passes when nothing under a forbidden path changed" do
      dir = git_repo_with(%{"docs/plan.md" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "lib/app.ex"), "code v2")

      predicate =
        Predicate.new(:scope_forbidden_paths, :scope_guard,
          config: %{forbidden_paths: ["docs/plan.md"]}
        )

      assert ScopeGuard.evaluate(predicate, %{workspace: dir}).status == :pass
    end
  end

  describe "Kazi.Runtime.check/2 wires the forbidden_paths guard automatically" do
    test "a goal declaring [scope].forbidden_paths gets the guard folded in and reports it" do
      dir = git_repo_with(%{"docs/plan.md" => "original"})
      File.write!(Path.join(dir, "docs/plan.md"), "tampered by the grind loop")

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})],
          scope: Scope.new(forbidden_paths: ["docs/plan.md"])
        )

      assert {:ok, %{status: :fail, vector: vector}} =
               Runtime.check(goal,
                 workspace: dir,
                 providers: %{custom_script: CustomScript, scope_guard: ScopeGuard}
               )

      assert PredicateVector.get(vector, :scope_forbidden_paths).status == :fail
    end
  end

  # ===========================================================================
  # 4. Kazi.Actions.Integrate — the LANDING-TIME refusal half (real git, Tier 2)
  #
  # This is the acceptance-pinned reproduction of #1695: "a dispatched commit
  # touches" a forbidden path alongside a legitimate in-scope change, and
  # landing refuses to include the forbidden one.
  # ===========================================================================

  describe "legacy landing path (no [integration] block) excludes a forbidden path" do
    test "a converged fix plus a touched docs/plan.md: only the fix lands, docs/plan.md does not",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # The exact #1695 shape: a real, in-scope fix ...
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")
      # ... plus the grind loop's own commit tooling ALSO touching docs/plan.md,
      # despite (in the real incident) a prose exclusion list it never read.
      File.write!(Path.join(work, "docs/plan.md"), "the grind loop's own edit\n")

      integrator = fn request, _opts ->
        {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      goal =
        Goal.new("issue-1695",
          scope: Scope.new(forbidden_paths: ["docs/plan.md", "docs/roadmap.md"])
        )

      action = Action.new(:integrate, params: %{branch: "kazi/forbidden-paths"})
      ctx = %{workspace: work, integrator: integrator, goal: goal}

      assert {:ok, result} = Integrate.execute(action, ctx)

      # The real fix landed on the default branch ...
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"

      # ... but docs/plan.md's content on the landed branch is UNCHANGED (the
      # forbidden edit was excluded from the commit that actually landed).
      {landed_plan, 0} = System.cmd("git", ["show", "main:docs/plan.md"], cd: bare)
      assert landed_plan == "seed\n"
      refute landed_plan =~ "grind loop's own edit"

      # The forbidden edit is still sitting in the working tree, uncommitted —
      # excluded, never silently discarded.
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
      assert status =~ "docs/plan.md"

      assert result.branch == "kazi/forbidden-paths"
    end
  end

  describe "[integration] verify-then-ship path refuses the WHOLE landing" do
    test "a committed forbidden-path change is refused before any push, no PR opened",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # The inner agent owns its own commits under [integration] mode: it
      # commits BOTH the real fix and (the #1695 shape) docs/plan.md.
      {_, 0} = System.cmd("git", ["checkout", "-b", "task/x"], cd: work, stderr_to_stdout: true)
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")
      File.write!(Path.join(work, "docs/plan.md"), "the grind loop's own edit\n")
      {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
      {_, 0} = System.cmd("git", ["commit", "-m", "agent: fix + accidental plan edit"], cd: work)

      test_pid = self()
      integrator = fn request, _opts -> send(test_pid, {:integrator_called, request}) end

      goal =
        Goal.new("issue-1695-integration",
          integration: %{mode: :commit, base: "main"},
          scope: Scope.new(forbidden_paths: ["docs/plan.md", "docs/roadmap.md"])
        )

      action = Action.new(:integrate, params: %{base: "main"})
      ctx = %{workspace: work, goal: goal, integrator: integrator}

      assert {:error, {:forbidden_path_touched, paths}} = Integrate.execute(action, ctx)
      assert "docs/plan.md" in paths

      # Nothing was pushed, no PR was opened.
      {branches, _} = System.cmd("git", ["branch", "--list"], cd: bare, stderr_to_stdout: true)
      refute branches =~ "task/x"
      refute_received {:integrator_called, _}
    end
  end

  # ===========================================================================
  # Fixtures
  # ===========================================================================

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kazi-forbidden-paths-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git_repo_with(files) do
    dir = tmp_dir()
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", dir], stderr_to_stdout: true)
    config(dir)

    Enum.each(files, fn {rel, contents} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: dir, stderr_to_stdout: true)
    dir
  end

  defp setup_repo(tmp_dir) do
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    config(work)

    File.mkdir_p!(Path.join(work, "docs"))
    File.write!(Path.join(work, "README.md"), "seed\n")
    File.write!(Path.join(work, "docs/plan.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: work, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: bare)

    %{bare: bare, work: work}
  end

  defp config(dir) do
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp =
      Path.join(System.tmp_dir!(), "merge-#{System.pid()}-#{System.unique_integer([:positive])}")

    {_, 0} = System.cmd("git", ["clone", bare, tmp], stderr_to_stdout: true)
    config(tmp)

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
