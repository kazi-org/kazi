defmodule Kazi.Harness.ClaudeAdapterTest do
  # Not async: the config-fallback and non-zero-exit tests mutate process-global
  # state (Application env, OS env). Per-test isolation otherwise via unique tmp
  # workspaces.
  use ExUnit.Case, async: false

  alias Kazi.Harness.ClaudeAdapter
  alias Kazi.PredicateResult

  @stub Path.expand("../../support/stub_claude.sh", __DIR__)

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-claude-adapter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  describe "build_prompt/2 (pure prompt construction)" do
    test "seeds the work item plus failing-predicate evidence" do
      failing = [
        {:unit, PredicateResult.fail(%{output: "1 test, 1 failure", exit: 1})},
        {:live, PredicateResult.fail(%{http_status: 500, url: "https://x/health"})}
      ]

      prompt = ClaudeAdapter.build_prompt("Make the suite green", failing)

      assert prompt =~ "Make the suite green"
      assert prompt =~ "Failing predicate: unit"
      assert prompt =~ "Failing predicate: live"
      assert prompt =~ "1 test, 1 failure"
      assert prompt =~ "http_status: 500"
      # Guards against the agent "passing" a predicate by deleting the check.
      assert prompt =~ "not the checks themselves"
    end

    test "handles a failing predicate with no evidence" do
      prompt = ClaudeAdapter.build_prompt("fix it", [{:unit, PredicateResult.fail()}])
      assert prompt =~ "(no evidence captured)"
    end

    test "renders just the work item when nothing is failing" do
      prompt = ClaudeAdapter.build_prompt("nothing failing", [])
      assert prompt =~ "nothing failing"
      refute prompt =~ "Failing predicate"
    end
  end

  describe "run/3 against a stub binary (real subprocess boundary)" do
    test "runs the harness in the target workspace so edits land in place", %{
      workspace: workspace
    } do
      prompt =
        ClaudeAdapter.build_prompt("fix unit", [
          {:unit, PredicateResult.fail(%{output: "assertion failed: expected 2, got 3"})}
        ])

      assert {:ok, result} = ClaudeAdapter.run(prompt, workspace, command: @stub)

      # The stub wrote a marker into its cwd — proving cd: workspace took effect.
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))
      assert File.read!(Path.join(workspace, "stub_edit.txt")) == "edited-by-stub\n"

      # Output is captured; the stub echoes the cwd and the prompt it received.
      assert result.output =~ "stub ran in:"
      assert result.output =~ workspace
      assert result.output =~ "assertion failed: expected 2, got 3"
      assert result.exit == 0
      assert result.command == @stub
      assert result.workspace == workspace
    end

    test "captures a non-zero exit from the harness", %{workspace: workspace} do
      System.put_env("STUB_EXIT", "7")
      on_exit(fn -> System.delete_env("STUB_EXIT") end)

      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, command: @stub)
      assert result.exit == 7
    end

    test "returns :empty_prompt without invoking the harness", %{workspace: workspace} do
      assert {:error, :empty_prompt} = ClaudeAdapter.run("", workspace, command: @stub)
      refute File.exists?(Path.join(workspace, "stub_edit.txt"))
    end

    test "reports a missing binary as an error, not failing work", %{workspace: workspace} do
      assert {:error, {:command_not_found, "kazi-no-such-binary"}} =
               ClaudeAdapter.run("do work", workspace, command: "kazi-no-such-binary")
    end

    test "falls back to app config for the command", %{workspace: workspace} do
      Application.put_env(:kazi, :harness_command, @stub)
      on_exit(fn -> Application.delete_env(:kazi, :harness_command) end)

      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, [])
      assert result.command == @stub
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))
    end
  end
end
