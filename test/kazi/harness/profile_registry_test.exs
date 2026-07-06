defmodule Kazi.Harness.ProfileRegistryTest do
  # T8.1 (UC-027, ADR-0016): the harness-profile struct + built-in registry.
  #
  # The load-bearing guarantee is that the `:claude` profile reproduces the REAL
  # `Kazi.Harness.ClaudeAdapter` byte-for-byte, so generalizing the adapter (T8.2)
  # cannot silently regress the Claude path. We prove that NOT by re-stating the
  # expected argv as a hand-written literal, but by driving the actual adapter
  # against the same stub binaries the adapter's own tests use and comparing:
  #
  #   * argv: `stub_claude_args.sh` echoes every arg it received as `arg: <v>`, so
  #     the adapter's real argv is recovered and compared to the profile's.
  #   * parse: `stub_claude_json.sh` emits a representative envelope; the adapter's
  #     parsed result and the profile's parser must agree on the same output.
  #
  # Not async: the stub binaries read STUB_* OS env (process-global); other harness
  # tests mutate it, so per-test isolation is via unique tmp workspaces + serial run.
  use ExUnit.Case, async: false

  alias Kazi.Harness.{ClaudeAdapter, Profile, Registry}

  @args_stub Path.expand("../../support/stub_claude_args.sh", __DIR__)
  @json_stub Path.expand("../../support/stub_claude_json.sh", __DIR__)

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-profile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  describe "Registry lookup" do
    test "fetch(:claude) returns the claude profile" do
      assert {:ok, %Profile{id: :claude, command: "claude"} = profile} = Registry.fetch(:claude)
      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # Claude-only hygiene flags are declared so resolution never forwards them
      # to a different harness.
      assert :max_budget_usd in profile.supported_opts
      assert :permission_mode in profile.supported_opts
    end

    test "fetch/1 of an unknown id is a clear tagged error, not a crash" do
      assert Registry.fetch(:opencode_typo) == {:error, {:unknown_harness, :opencode_typo}}
    end

    test "fetch!/1 raises on an unknown id and returns the profile for a known one" do
      assert %Profile{id: :claude} = Registry.fetch!(:claude)
      assert_raise ArgumentError, ~r/unknown harness/, fn -> Registry.fetch!(:nope) end
    end

    test "ids/0 lists the built-in harnesses" do
      assert :claude in Registry.ids()
    end
  end

  describe "Profile API" do
    test "build_args/3 and parse/2 delegate to the profile's functions" do
      profile = Registry.fetch!(:claude)

      assert Profile.build_args(profile, "do it", []) ==
               ["-p", "do it", "--output-format", "json"]

      # A valid envelope with no usage object reports :none fidelity (T34.2,
      # ADR-0046) — never zero-filled token fields.
      assert Profile.parse(profile, ~s({"result":"ok"})) == %{result: "ok", usage_fidelity: :none}
      # A non-object envelope degrades to %{} (additive, never crashes).
      assert Profile.parse(profile, "not json") == %{}
    end
  end

  describe ":claude profile argv == ClaudeAdapter argv (golden, via stub)" do
    # Each case: the opts threaded to BOTH the real adapter and the profile. The
    # adapter consumes :command as the binary; build_args ignores it. The stub
    # echoes the remaining argv, which must equal the profile's rendered argv.
    @prompt "Make the suite green"

    cases = [
      {"no hygiene opts", []},
      {"per-dispatch budget ceiling", [max_budget_usd: 0.5]},
      {"least-privilege tool set", [allowed_tools: ["Read", "Edit"]]},
      {"least-privilege permission mode", [permission_mode: :acceptEdits]},
      {"all hygiene flags together",
       [max_budget_usd: 1.25, allowed_tools: ["Read", "Bash"], permission_mode: "plan"]}
    ]

    for {label, opts} <- cases do
      @opts opts
      test "argv matches for: #{label}", %{workspace: workspace} do
        profile = Registry.fetch!(:claude)
        run_opts = [command: @args_stub] ++ @opts

        assert {:ok, %{output: output, exit: 0}} =
                 ClaudeAdapter.run(@prompt, workspace, run_opts)

        captured =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn
            "arg: " <> value -> [value]
            _ -> []
          end)

        assert captured == Profile.build_args(profile, @prompt, @opts),
               "profile argv drifted from the real ClaudeAdapter argv (opts=#{inspect(@opts)})"
      end
    end
  end

  describe ":claude profile parse == ClaudeAdapter parse (golden, via JSON stub)" do
    test "the profile parser agrees with the adapter on the same envelope", %{
      workspace: workspace
    } do
      profile = Registry.fetch!(:claude)

      assert {:ok, result} = ClaudeAdapter.run("fix it", workspace, command: @json_stub)

      # The structured subset the adapter merged over its base map... `:harness_pid`
      # (issue #857) is dropped too: it is dispatch-identity metadata the adapter
      # adds AFTER parsing (the OS pid of the actual subprocess), not something
      # `Profile.parse/2` (a pure function of stdout) could ever produce.
      adapter_structured = Map.drop(result, [:output, :exit, :command, :workspace, :harness_pid])
      # ...must equal what the profile parser extracts from the same raw stdout.
      assert Profile.parse(profile, result.output) == adapter_structured

      # And the extracted values are the expected ones (input+output+cache reads
      # summed; cost, result text, touched set carried through).
      assert adapter_structured.result == "Made the failing unit test pass."
      assert adapter_structured.tokens == 100 + 250 + 5000 + 0
      assert adapter_structured.cost == %{tokens: 5350}
      assert adapter_structured.cost_usd == 0.0123
      assert "lib/app/widget.ex" in adapter_structured.touched
    end
  end
end
