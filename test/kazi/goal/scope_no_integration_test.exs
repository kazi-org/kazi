defmodule Kazi.Goal.ScopeNoIntegrationTest do
  @moduledoc """
  ADR-0085 (kazi-org/kazi#1704): `[scope].no_integration` — a declared
  negative-action contract that reuses the existing `[integration]` `none`-mode
  DATA shape as its enforcement primitive, PLUS a direct structural refusal in
  `Kazi.Actions.Integrate` (never a `Kazi.Goal.new/2`-only override, so it
  holds even for a goal struct assembled without going through `new/2`).

  Reproduces #1704: an orchestrating session's prose "do not open a PR"
  instruction never reaches the dispatched grind model (`kazi/AUTHORING.md`:
  the dispatch prompt is the only channel it reads). `no_integration = true`
  makes that a DECLARED goal-file contract kazi itself enforces: even when the
  dispatched model attempts its own `gh pr create` (represented here, per this
  suite's existing convention, by the injectable `:integrator` seam every
  other Integrate test uses in place of a real `gh` process — see
  `Kazi.Actions.Integrate.GhIntegrator`), kazi's OWN landing action never
  proceeds far enough to invoke it.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Action, Goal, Scope}
  alias Kazi.Goal.Loader
  alias Kazi.Actions.Integrate

  @moduletag :tmp_dir

  # ===========================================================================
  # 1. the loader parses [scope].no_integration
  # ===========================================================================

  describe "Kazi.Goal.Loader parses [scope].no_integration" do
    test "parses into Kazi.Scope" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"no_integration" => true},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.no_integration == true
    end

    test "absent no_integration defaults to false (byte-identical to before)" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.no_integration == false
    end

    test "a non-boolean no_integration is a validation error" do
      assert {:error, msg} =
               Loader.from_map(%{"id" => "g", "scope" => %{"no_integration" => "yes"}})

      assert msg =~ "no_integration"
    end
  end

  # ===========================================================================
  # 2. Kazi.Goal.new/2 forces [integration] to mode :none
  # ===========================================================================

  describe "Kazi.Goal.new/2" do
    test "no_integration: true forces integration.mode to :none regardless of [integration]" do
      goal =
        Goal.new("g",
          scope: [no_integration: true],
          integration: %{
            mode: :pr,
            branch: nil,
            branch_prefix: nil,
            base: "main",
            commit_style: nil
          }
        )

      assert goal.integration == Goal.default_integration()
    end

    test "no_integration: false (default) leaves a declared [integration] block untouched" do
      integration = %{mode: :pr, branch: nil, branch_prefix: nil, base: "main", commit_style: nil}
      goal = Goal.new("g", integration: integration)

      assert goal.integration == integration
    end
  end

  # ===========================================================================
  # 3. Kazi.Actions.Integrate — the STRUCTURAL refusal (real git, Tier 2)
  #
  # This is the acceptance-pinned reproduction of #1704: "never lands a PR
  # even when the dispatched model attempts gh pr create".
  # ===========================================================================

  describe "no_integration: true never lands a PR" do
    test "Integrate.execute/2 short-circuits before touching git at all, integrator never called",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A converged change sitting uncommitted, exactly the legacy bulk-commit
      # shape — if no_integration did NOT refuse, this would commit/push/PR.
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      test_pid = self()

      # Stands in for the dispatched model's own `gh pr create` attempt
      # (#1704): if kazi's landing ever reached this seam, the PR would open.
      integrator = fn request, _opts ->
        send(test_pid, {:integrator_called, request})
        {:ok, %{pr: 999, merge_commit: "deadbeef"}}
      end

      goal = Goal.new("issue-1704", scope: Scope.new(no_integration: true))
      action = Action.new(:integrate, params: %{branch: "kazi/no-integration"})
      ctx = %{workspace: work, integrator: integrator, goal: goal}

      assert {:ok, %{skipped: :no_integration}} = Integrate.execute(action, ctx)

      # Nothing was committed, pushed, or landed.
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
      assert status =~ "fix.txt"

      {branches, _} = System.cmd("git", ["branch", "--list"], cd: bare, stderr_to_stdout: true)
      refute branches =~ "kazi/no-integration"

      refute_received {:integrator_called, _}
    end

    test "still refuses even for a goal declaring [integration] pr mode (the override holds end to end)",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      # The inner agent already committed its own work on a non-base branch —
      # the [integration] verify-then-ship shape — AND attempted its own PR.
      {_, 0} = System.cmd("git", ["checkout", "-b", "task/x"], cd: work, stderr_to_stdout: true)
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")
      {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
      {_, 0} = System.cmd("git", ["commit", "-m", "agent: fix"], cd: work)

      test_pid = self()
      integrator = fn request, _opts -> send(test_pid, {:integrator_called, request}) end

      # Declares [integration] mode "pr" — Kazi.Goal.new/2 already forces this
      # to :none, but this goal is asserted for the raw scope check too, since
      # Integrate reads `scope.no_integration` directly (defense in depth for
      # a goal struct built without going through new/2, see moduledoc).
      goal =
        Goal.new("issue-1704-pr-mode",
          integration: %{mode: :pr, base: "main"},
          scope: Scope.new(no_integration: true)
        )

      assert goal.integration.mode == :none

      action = Action.new(:integrate, params: %{base: "main"})
      ctx = %{workspace: work, goal: goal, integrator: integrator}

      assert {:ok, %{skipped: :no_integration}} = Integrate.execute(action, ctx)
      refute_received {:integrator_called, _}
    end

    test "a raw %Goal{} struct (not built via new/2) is still refused — the scope check is direct",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      test_pid = self()
      integrator = fn request, _opts -> send(test_pid, {:integrator_called, request}) end

      # A struct literal bypasses Goal.new/2's mode-:none override entirely —
      # this goal's `integration.mode` stays whatever the struct default is
      # (:none), and Integrate must still refuse off `scope.no_integration`
      # alone, not off the (possibly-stale) integration mode.
      goal = %Goal{id: "raw-goal", scope: %Scope{workspace: work, no_integration: true}}

      action = Action.new(:integrate, params: %{branch: "kazi/raw"})
      ctx = %{workspace: work, goal: goal, integrator: integrator}

      assert {:ok, %{skipped: :no_integration}} = Integrate.execute(action, ctx)
      refute_received {:integrator_called, _}
    end
  end

  # ===========================================================================
  # Fixtures
  # ===========================================================================

  defp setup_repo(tmp_dir) do
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
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
end
