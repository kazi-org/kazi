defmodule Kazi.Apply.PreflightTest do
  # Tier-2: exercises the preflight's gh/git command boundary via an INJECTED
  # runner (opts[:command_runner]) and the stale-run lookup via
  # opts[:stale_run_lookup], so the check logic — mode gating, refusal naming,
  # short-circuit order — is covered WITHOUT a live network call or a database.
  use ExUnit.Case, async: true

  alias Kazi.Apply.Preflight
  alias Kazi.{Goal, Predicate}

  # A runner that always succeeds; records nothing.
  defp ok_runner, do: fn _cmd, _args, _opts -> {:ran, "", 0} end

  # A runner that flunks if invoked — proves a check was SKIPPED.
  defp never_runner, do: fn cmd, _args, _opts -> flunk("unexpected command run: #{cmd}") end

  defp goal(mode, opts \\ []) do
    integration = %{
      mode: mode,
      branch: opts[:branch],
      branch_prefix: nil,
      base: nil,
      commit_style: nil
    }

    Goal.new("g-#{mode}",
      predicates: Keyword.get(opts, :predicates, []),
      scope: Kazi.Scope.new(workspace: "/tmp/ws"),
      integration: integration
    )
  end

  defp base_opts(extra) do
    Keyword.merge([command_runner: ok_runner()], extra)
  end

  describe "gh auth" do
    test "a failing gh auth check refuses dispatch, naming gh auth" do
      runner = fn "gh", ["auth", "status"], _ ->
        {:ran, "You are not logged into any GitHub hosts", 1}
      end

      assert {:refuse, %{check: :gh_auth, message: message}} =
               Preflight.check(goal(:pr), base_opts(command_runner: runner))

      assert message =~ "gh auth"
      assert message =~ "--no-preflight"
    end

    test "a gh binary that cannot run refuses, naming gh auth" do
      runner = fn "gh", _args, _ -> {:raised, "no such file or directory"} end

      assert {:refuse, %{check: :gh_auth, message: message}} =
               Preflight.check(goal(:merge), base_opts(command_runner: runner))

      assert message =~ "gh auth"
    end

    test "mode :none skips the gh auth check entirely" do
      # never_runner flunks if gh/git is invoked -> proves both GitHub checks skip.
      assert :ok = Preflight.check(goal(:none), base_opts(command_runner: never_runner()))
    end

    test "mode :commit skips gh auth (commit does not touch GitHub)" do
      # :commit does not push either, so no command should run.
      assert :ok = Preflight.check(goal(:commit), base_opts(command_runner: never_runner()))
    end
  end

  describe "push dry-run" do
    test "a failing push dry-run refuses, naming the push path/branch" do
      runner = fn "git", ["-C", "/tmp/ws", "push", "--dry-run"], _ ->
        {:ran, "fatal: No configured push destination", 128}
      end

      assert {:refuse, %{check: :push, message: message}} =
               Preflight.check(
                 goal(:branch, branch: "release/x"),
                 base_opts(command_runner: runner)
               )

      assert message =~ "/tmp/ws"
      assert message =~ "release/x"
      assert message =~ "git push --dry-run"
    end

    test "mode :pr runs BOTH gh auth and push; push failure refuses" do
      runner = fn
        "gh", ["auth", "status"], _ -> {:ran, "", 0}
        "git", ["-C", "/tmp/ws", "push", "--dry-run"], _ -> {:ran, "fatal", 1}
      end

      assert {:refuse, %{check: :push}} =
               Preflight.check(goal(:pr), base_opts(command_runner: runner))
    end
  end

  describe "smoke (command-backed predicates' tools)" do
    test "a custom_script predicate whose cmd is missing refuses, naming the command" do
      pred =
        Predicate.new(:grader, :custom_script,
          config: %{cmd: "kazi_definitely_missing_binary_xyz"}
        )

      assert {:refuse, %{check: :smoke, message: message}} =
               Preflight.check(
                 goal(:none, predicates: [pred]),
                 base_opts(command_runner: never_runner())
               )

      assert message =~ "kazi_definitely_missing_binary_xyz"
    end

    test "a custom_script predicate whose cmd resolves passes smoke" do
      pred = Predicate.new(:grader, :custom_script, config: %{cmd: "sh"})

      assert :ok =
               Preflight.check(
                 goal(:none, predicates: [pred]),
                 base_opts(command_runner: never_runner())
               )
    end

    test "smoke runs even for mode :none (still checked when GitHub checks are skipped)" do
      bad =
        Predicate.new(:grader, :custom_script,
          config: %{cmd: "kazi_definitely_missing_binary_xyz"}
        )

      assert {:refuse, %{check: :smoke}} =
               Preflight.check(
                 goal(:none, predicates: [bad]),
                 base_opts(command_runner: never_runner())
               )
    end
  end

  describe "all green" do
    test "every check green proceeds (:ok) for a pushing GitHub mode" do
      runner = fn
        "gh", ["auth", "status"], _ -> {:ran, "Logged in", 0}
        "git", ["-C", "/tmp/ws", "push", "--dry-run"], _ -> {:ran, "Everything up-to-date", 0}
      end

      pred = Predicate.new(:grader, :custom_script, config: %{cmd: "sh"})

      assert :ok =
               Preflight.check(
                 goal(:pr, predicates: [pred]),
                 base_opts(command_runner: runner)
               )
    end
  end
end
