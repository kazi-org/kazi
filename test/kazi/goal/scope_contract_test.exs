defmodule Kazi.Goal.ScopeContractTest do
  @moduledoc """
  T73.6: `[scope].contract` — a single, optional path to a goal's
  human-authored acceptance contract.

  Pins, end to end:

    * the loader parses `[scope].contract` into `Kazi.Scope.contract`;
    * `Kazi.Scope.new/1` auto-folds `contract` into `forbidden_paths` (the
      same "auto-extend" pattern T72.6 established for the rendered node) —
      a commit touching the contract fails the `:scope_forbidden_paths` guard
      exactly like a hand-authored `forbidden_paths` entry would;
    * `Kazi.Scope.own_contract_conflict/1` — a goal's own write scope covering
      its own contract;
    * `Kazi.Scope.contract_conflicts/1` — the fleet-level version, one
      member's write scope covering ANOTHER member's contract.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Scope}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.ScopeGuard

  # ===========================================================================
  # 1. the loader parses [scope].contract
  # ===========================================================================

  describe "Kazi.Goal.Loader parses [scope].contract" do
    test "parses into Kazi.Scope.contract" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"contract" => "lib/foo/contract.ex"},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.contract == "lib/foo/contract.ex"
    end

    test "absent contract keeps today's behavior byte-identical" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.contract == nil
      assert scope.forbidden_paths == []
    end

    test "a non-string contract is a validation error" do
      assert {:error, msg} =
               Loader.from_map(%{"id" => "g", "scope" => %{"contract" => ["not", "a", "string"]}})

      assert msg =~ "scope"
    end
  end

  # ===========================================================================
  # 2. Kazi.Scope.new/1 auto-extends forbidden_paths with the contract
  # ===========================================================================

  describe "Kazi.Scope.new/1 auto-folds contract into forbidden_paths" do
    test "a declared contract is appended to forbidden_paths" do
      scope = Scope.new(contract: "docs/contracts/foo.md")
      assert scope.forbidden_paths == ["docs/contracts/foo.md"]
    end

    test "does not duplicate when the contract is already declared in forbidden_paths" do
      scope =
        Scope.new(forbidden_paths: ["docs/contracts/foo.md"], contract: "docs/contracts/foo.md")

      assert scope.forbidden_paths == ["docs/contracts/foo.md"]
    end

    test "an undeclared contract leaves forbidden_paths untouched" do
      assert Scope.new(forbidden_paths: ["docs/plan.md"]).forbidden_paths == ["docs/plan.md"]
    end
  end

  # ===========================================================================
  # 3. the auto-folded forbidden_paths guard actually fires on a touched contract
  # ===========================================================================

  describe "a commit touching the contract fails the :scope_forbidden_paths guard" do
    test "ScopeGuard.evaluate/2 fails, naming the contract path" do
      dir = git_repo_with(%{"docs/contracts/foo.md" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "docs/contracts/foo.md"), "the grind loop edited the contract")

      scope = Scope.new(contract: "docs/contracts/foo.md")
      [guard] = Scope.guard_predicates(scope)

      result = ScopeGuard.evaluate(guard, %{workspace: dir})

      assert result.status == :fail
      assert result.evidence.changed == ["docs/contracts/foo.md"]
      assert result.evidence.reason == :forbidden_path_violation
    end

    test "passes when nothing under the contract path changed" do
      dir = git_repo_with(%{"docs/contracts/foo.md" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "lib/app.ex"), "code v2")

      scope = Scope.new(contract: "docs/contracts/foo.md")
      [guard] = Scope.guard_predicates(scope)

      assert ScopeGuard.evaluate(guard, %{workspace: dir}).status == :pass
    end
  end

  # ===========================================================================
  # 4. Kazi.Scope.own_contract_conflict/1 — the single-goal self-check
  # ===========================================================================

  describe "Kazi.Scope.own_contract_conflict/1" do
    test "a goal writing lib/foo/** with contract lib/foo/contract.ex conflicts, naming both" do
      scope = Scope.new(write_paths: ["lib/foo/**"], contract: "lib/foo/contract.ex")
      assert Scope.own_contract_conflict(scope) == {"lib/foo/**", "lib/foo/contract.ex"}
    end

    test "a contract outside the goal's own write_paths does not conflict" do
      scope = Scope.new(write_paths: ["lib/foo/**"], contract: "lib/contracts/foo.ex")
      assert Scope.own_contract_conflict(scope) == nil
    end

    test "no declared contract never conflicts" do
      assert Scope.own_contract_conflict(Scope.new(write_paths: ["lib/foo/**"])) == nil
    end
  end

  # ===========================================================================
  # 5. Kazi.Scope.contract_conflicts/1 — the fleet-level check
  # ===========================================================================

  describe "Kazi.Scope.contract_conflicts/1" do
    test "B's write_paths covering A's contract conflicts, naming A, B, and the path" do
      entries = [
        {"goal-a", ["lib/foo/**"], "lib/foo/contract.ex"},
        {"goal-b", ["lib/foo/**"], nil}
      ]

      assert Scope.contract_conflicts(entries) == [
               %{owner: "goal-a", writer: "goal-b", path: "lib/foo/contract.ex"}
             ]
    end

    test "a goal's own write_paths covering its own contract is excluded (self-pairs only)" do
      entries = [{"goal-a", ["lib/foo/**"], "lib/foo/contract.ex"}]
      assert Scope.contract_conflicts(entries) == []
    end

    test "disjoint write scopes and contracts never conflict" do
      entries = [
        {"goal-a", ["lib/foo/**"], "lib/contracts/foo.ex"},
        {"goal-b", ["lib/bar/**"], "lib/contracts/bar.ex"}
      ]

      assert Scope.contract_conflicts(entries) == []
    end
  end

  # ===========================================================================
  # Fixtures
  # ===========================================================================

  defp git_repo_with(files) do
    dir =
      Path.join(System.tmp_dir!(), "kazi-contract-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", dir], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

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
