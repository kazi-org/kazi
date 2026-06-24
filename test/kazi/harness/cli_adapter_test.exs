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
  @env_stub Path.expand("../../support/stub_env_echo.sh", __DIR__)
  @opencode_stub Path.expand("../../support/stub_opencode_json.sh", __DIR__)
  @argv_stub Path.expand("../../support/stub_harness_argv.sh", __DIR__)
  @antigravity_stub Path.expand("../../support/stub_antigravity_json.sh", __DIR__)

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

  # Recover the single `env: <value>` line the env-echo stub printed.
  defp captured_env(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "env: " <> value -> value
      _ -> false
    end)
  end

  describe "provider env forwarding (opts[:env], T8.8)" do
    test "opts[:env] reaches System.cmd so the harness sees it", %{workspace: workspace} do
      assert {:ok, %{output: output, exit: 0}} =
               CliAdapter.run("do X", workspace,
                 harness: :opencode,
                 model: "m",
                 env: [{"KAZI_TEST_ENV", "xyz"}],
                 command: @env_stub
               )

      assert captured_env(output) == "xyz"
    end

    test "an :env map is normalized to pairs and forwarded", %{workspace: workspace} do
      assert {:ok, %{output: output}} =
               CliAdapter.run("do X", workspace,
                 harness: :opencode,
                 env: %{"KAZI_TEST_ENV" => "from-map"},
                 command: @env_stub
               )

      assert captured_env(output) == "from-map"
    end

    test "malformed :env entries are dropped, not crashed", %{workspace: workspace} do
      assert {:ok, %{output: output, exit: 0}} =
               CliAdapter.run("do X", workspace,
                 harness: :opencode,
                 env: [{"KAZI_TEST_ENV", "kept"}, {:bad, 123}, "garbage"],
                 command: @env_stub
               )

      assert captured_env(output) == "kept"
    end

    test "no :env opt runs unchanged (the var is unset, run still succeeds)", %{
      workspace: workspace
    } do
      assert {:ok, %{output: output, exit: 0}} =
               CliAdapter.run("do X", workspace, harness: :opencode, command: @env_stub)

      # No :env forwarded -> the stub sees an unset var (empty line).
      assert captured_env(output) == ""
    end
  end

  # Recover the argv the argv-recording stub wrote to harness_argv.txt in the
  # workspace (one arg per line) — proves which profile assembled the dispatch.
  defp recorded_argv(workspace) do
    workspace |> Path.join("harness_argv.txt") |> File.read!() |> String.split("\n", trim: true)
  end

  describe "end-to-end: CliAdapter drives the :opencode profile (T8.9, UC-026/UC-027)" do
    # The assertion the T8.4 agent deferred because CliAdapter was not yet merged:
    # drive `CliAdapter.run(..., harness: :opencode, model: ..., command: <stub>)`
    # against the REAL opencode NDJSON stub and confirm (a) the parsed result map
    # carries the final :result text plus the summed tokens/cost from the event
    # stream, and (b) the dispatched argv is the opencode shape — not Claude's.

    test "parses the opencode NDJSON stream into :result/:tokens/:cost_usd", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               CliAdapter.run("make the failing test pass", workspace,
                 harness: :opencode,
                 model: "local-ollama/qwen3.6:35b-a3b-q8_0",
                 command: @opencode_stub
               )

      # The stub really ran in the workspace (its edit landed there via cd:).
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))

      # The final assistant TEXT part is the :result.
      assert result.result == "Made the failing unit test pass."
      # input 120 + output 340 + reasoning 40 + cache.read 900 + cache.write 0.
      assert result.tokens == 120 + 340 + 40 + 900 + 0
      assert result.cost == %{tokens: 1400}
      assert result.cost_usd == 0.0042

      # The base map still carries the resolved command + workspace.
      assert result.command == @opencode_stub
      assert result.workspace == workspace
    end

    test "with overridden usage env, the budget consumes the exact stub totals", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               CliAdapter.run("fix it", workspace,
                 harness: :opencode,
                 command: @opencode_stub,
                 env: [
                   {"STUB_INPUT_TOKENS", "11"},
                   {"STUB_OUTPUT_TOKENS", "22"},
                   {"STUB_REASONING_TOKENS", "0"},
                   {"STUB_CACHE_READ_TOKENS", "0"},
                   {"STUB_CACHE_WRITE_TOKENS", "0"},
                   {"STUB_COST_USD", "0.99"}
                 ]
               )

      assert result.tokens == 33
      assert result.cost == %{tokens: 33}
      assert result.cost_usd == 0.99
    end

    test "a no-usage opencode run degrades cleanly (no fabricated tokens)", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               CliAdapter.run("fix it", workspace,
                 harness: :opencode,
                 command: @opencode_stub,
                 env: [{"STUB_NO_USAGE", "1"}]
               )

      # The result text is still additive...
      assert result.result == "Made the failing unit test pass."
      # ...but with no usage event the budget's token dimension falls back to an
      # estimate (ADR-0008) rather than a fabricated count.
      refute Map.has_key?(result, :tokens)
      refute Map.has_key?(result, :cost)
      refute Map.has_key?(result, :cost_usd)
    end

    test "the dispatched argv is the opencode shape: run <prompt> --format json --model <m>",
         %{workspace: workspace} do
      assert {:ok, %{exit: 0}} =
               CliAdapter.run("do the thing", workspace,
                 harness: :opencode,
                 model: "local-ollama/qwen3.6:35b-a3b-q8_0",
                 command: @argv_stub
               )

      argv = recorded_argv(workspace)

      assert argv == [
               "run",
               "do the thing",
               "--format",
               "json",
               "--model",
               "local-ollama/qwen3.6:35b-a3b-q8_0"
             ]

      # Emphatically NOT the claude shape.
      refute "-p" in argv
      refute "--output-format" in argv
    end
  end

  describe "end-to-end: CliAdapter drives the :antigravity profile via prompt_via: :file (T14.3)" do
    # The #76 non-TTY workaround end to end: the adapter must WRITE the prompt to a
    # temp file in the workspace, thread its path to build_args as --prompt-file,
    # run the harness, parse the --output json envelope, and DELETE the temp file
    # afterwards. The stub asserts the prompt-file existed and records both the
    # argv and the prompt bytes it read.

    test "writes the prompt to a temp file, dispatches the workaround argv, parses JSON", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               CliAdapter.run("make the failing test pass", workspace,
                 harness: :antigravity,
                 model: "gemini-2.5-pro",
                 command: @antigravity_stub
               )

      # The stub recorded the argv it received: the workaround shape, NOT bare -p.
      argv = recorded_argv(workspace)
      assert "run" in argv
      assert "--prompt-file" in argv
      assert ["--output", "json"] -- argv == []
      assert "--yes" in argv
      assert ["--model", "gemini-2.5-pro"] -- argv == []
      refute "-p" in argv
      refute "--prompt" in argv

      # The adapter wrote the prompt to the file the stub then read back.
      seen_prompt = workspace |> Path.join("seen_prompt.txt") |> File.read!()
      assert seen_prompt == "make the failing test pass"

      # The --output json envelope parsed into the additive subset.
      assert result.result == "Made the failing unit test pass."
      assert result.tokens == 1500 + 400
      assert result.cost == %{tokens: 1900}

      # The base map still carries the resolved command + workspace.
      assert result.command == @antigravity_stub
      assert result.workspace == workspace
    end

    test "the temp prompt file is cleaned up after the run (no litter in the workspace)", %{
      workspace: workspace
    } do
      assert {:ok, %{exit: 0}} =
               CliAdapter.run("clean up after yourself", workspace,
                 harness: :antigravity,
                 command: @antigravity_stub
               )

      # The adapter deletes its `.kazi-prompt-*.txt` temp file after dispatch.
      leftover =
        workspace
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".kazi-prompt-"))

      assert leftover == [], "expected no leftover temp prompt files, found: #{inspect(leftover)}"
    end

    test "a no-usage antigravity run degrades cleanly (no fabricated tokens)", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               CliAdapter.run("fix it", workspace,
                 harness: :antigravity,
                 command: @antigravity_stub,
                 env: [{"STUB_NO_USAGE", "1"}]
               )

      assert result.result == "Made the failing unit test pass."
      refute Map.has_key?(result, :tokens)
      refute Map.has_key?(result, :cost)
    end

    test "the temp file is cleaned up even when the harness binary is missing", %{
      workspace: workspace
    } do
      # prompt_via: :file writes the temp file BEFORE dispatch; a missing binary
      # must still leave no litter (the cleanup runs in an `after`).
      assert {:error, {:command_not_found, "/no/such/antigravity"}} =
               CliAdapter.run("do it", workspace,
                 harness: :antigravity,
                 command: "/no/such/antigravity"
               )

      leftover =
        workspace
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".kazi-prompt-"))

      assert leftover == []
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
