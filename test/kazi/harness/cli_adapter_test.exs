defmodule Kazi.Harness.CliAdapterTest do
  # T8.2 (UC-027, ADR-0016): the generic profile-parameterized CLI adapter.
  #
  # The load-bearing guarantee is that CliAdapter with the `:claude` profile is a
  # faithful drop-in for the legacy `Kazi.Harness.ClaudeAdapter`. We prove that NOT
  # by re-stating expected argv/result literals, but by driving BOTH adapters
  # against the same stub binaries the legacy adapter's own tests use and asserting
  # they agree:
  #
  #   * argv: `stub_claude_args.sh` echoes every arg it received as `arg: <v>`, so
  #     each adapter's real argv is recovered and the two compared.
  #   * parse: `stub_claude_json.sh` emits a representative envelope; the two
  #     adapters' result maps must agree on the same raw stdout.
  #
  # Not async: the stub binaries read STUB_* OS env (process-global) and other
  # harness tests mutate it; per-test isolation is via unique tmp workspaces.
  use ExUnit.Case, async: false

  alias Kazi.Harness.{ClaudeAdapter, CliAdapter, Registry}

  @args_stub Path.expand("../../support/stub_claude_args.sh", __DIR__)
  @json_stub Path.expand("../../support/stub_claude_json.sh", __DIR__)

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-cli-adapter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  # Recover the argv the stub echoed (one `arg: <v>` line per argument).
  defp captured_argv(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "arg: " <> value -> [value]
      _ -> []
    end)
  end

  describe "argv == legacy ClaudeAdapter (golden, via args stub)" do
    @prompt "Make the suite green"

    cases = [
      {"no hygiene opts", []},
      {"hygiene: acceptEdits permission mode", [permission_mode: :acceptEdits]}
    ]

    for {label, opts} <- cases do
      @opts opts
      test "CliAdapter argv matches the legacy adapter for: #{label}", %{workspace: workspace} do
        run_opts = [harness: :claude, command: @args_stub] ++ @opts

        assert {:ok, %{output: cli_output, exit: 0}} =
                 CliAdapter.run(@prompt, workspace, run_opts)

        assert {:ok, %{output: legacy_output, exit: 0}} =
                 ClaudeAdapter.run(@prompt, workspace, [command: @args_stub] ++ @opts)

        assert captured_argv(cli_output) == captured_argv(legacy_output),
               "CliAdapter argv drifted from the legacy ClaudeAdapter (opts=#{inspect(@opts)})"
      end
    end
  end

  describe "result map == legacy ClaudeAdapter (golden, via JSON stub)" do
    test "CliAdapter parses the same structured fields as the legacy adapter", %{
      workspace: workspace
    } do
      assert {:ok, cli_result} =
               CliAdapter.run("fix it", workspace, harness: :claude, command: @json_stub)

      assert {:ok, legacy_result} =
               ClaudeAdapter.run("fix it", workspace, command: @json_stub)

      # The structured subset both adapters merged over their base map must agree.
      drop = [:output, :exit, :command, :workspace]
      cli_structured = Map.drop(cli_result, drop)
      legacy_structured = Map.drop(legacy_result, drop)
      assert cli_structured == legacy_structured

      # And the extracted values are the expected ones.
      assert cli_result.result == "Made the failing unit test pass."
      assert cli_result.tokens == 5350
      assert cli_result.cost == %{tokens: 5350}
      assert cli_result.cost_usd == 0.0123
      assert "lib/app/widget.ex" in cli_result.touched

      # The base map carries the resolved command + workspace.
      assert cli_result.command == @json_stub
      assert cli_result.workspace == workspace
    end
  end

  describe "profile resolution" do
    test "an explicit profile: works the same as harness: :claude", %{workspace: workspace} do
      profile = Registry.fetch!(:claude)

      assert {:ok, via_profile} =
               CliAdapter.run("fix it", workspace, profile: profile, command: @json_stub)

      assert {:ok, via_harness} =
               CliAdapter.run("fix it", workspace, harness: :claude, command: @json_stub)

      assert via_profile == via_harness
    end

    test "no harness opt defaults to :claude", %{workspace: workspace} do
      assert {:ok, %{output: output, exit: 0}} =
               CliAdapter.run(@prompt, workspace, command: @args_stub)

      assert "-p" in captured_argv(output)
      assert "--output-format" in captured_argv(output)
    end
  end

  describe "error paths" do
    test "empty prompt returns {:error, :empty_prompt}", %{workspace: workspace} do
      assert CliAdapter.run("", workspace, harness: :claude) == {:error, :empty_prompt}
    end

    test "a missing binary returns {:error, {:command_not_found, command}}", %{
      workspace: workspace
    } do
      assert CliAdapter.run("do it", workspace, harness: :claude, command: "/no/such/bin") ==
               {:error, {:command_not_found, "/no/such/bin"}}
    end

    test "an unknown harness returns {:error, {:unknown_harness, id}}", %{workspace: workspace} do
      assert CliAdapter.run("do it", workspace, harness: :nope) ==
               {:error, {:unknown_harness, :nope}}
    end
  end
end
