defmodule Kazi.Harness.ClaudeEconomyFlagsTest do
  # Pure argv assembly — no subprocess, no shared state.
  use ExUnit.Case, async: true

  alias Kazi.Harness.Profiles.Claude
  alias Kazi.Harness.Registry

  # The always-present non-interactive + structured-envelope head (ADR-0008, T4.1).
  # Every economy flag is appended AFTER this, so the head never moves.
  @base ["-p", "do work", "--output-format", "json"]

  describe "economy flags — each opt appends its flag (T36.1, ADR-0047)" do
    test ":tools renders --tools with the normalized tool list" do
      args = Claude.build_args("do work", tools: ["Read", "Edit", "Bash"])
      assert args == @base ++ ["--tools", "Read", "Edit", "Bash"]
    end

    test ":tools accepts a comma/space-delimited string" do
      args = Claude.build_args("do work", tools: "Read, Edit Bash")
      assert args == @base ++ ["--tools", "Read", "Edit", "Bash"]
    end

    test ":disallowed_tools renders --disallowedTools (camelCase flag)" do
      args = Claude.build_args("do work", disallowed_tools: ["WebFetch", "Bash"])
      assert args == @base ++ ["--disallowedTools", "WebFetch", "Bash"]
    end

    test ":mcp_config renders --mcp-config with the config list" do
      args = Claude.build_args("do work", mcp_config: ["orientation.json", "graph.json"])
      assert args == @base ++ ["--mcp-config", "orientation.json", "graph.json"]
    end

    test ":strict_mcp_config renders the bare --strict-mcp-config switch when true" do
      args = Claude.build_args("do work", strict_mcp_config: true)
      assert args == @base ++ ["--strict-mcp-config"]
    end

    test ":max_turns renders --max-turns with the turn ceiling" do
      args = Claude.build_args("do work", max_turns: 6)
      assert args == @base ++ ["--max-turns", "6"]
    end

    test ":exclude_dynamic_system_prompt_sections renders the bare switch when true" do
      args = Claude.build_args("do work", exclude_dynamic_system_prompt_sections: true)
      assert args == @base ++ ["--exclude-dynamic-system-prompt-sections"]
    end

    test ":no_session_persistence renders the bare --no-session-persistence switch when true" do
      args = Claude.build_args("do work", no_session_persistence: true)
      assert args == @base ++ ["--no-session-persistence"]
    end

    test ":effort renders --effort with the reasoning-effort level (T36.6)" do
      args = Claude.build_args("do work", effort: "high")
      assert args == @base ++ ["--effort", "high"]
    end

    test ":effort sits AFTER the model arg, in order (T36.6)" do
      # The reasoning-effort lever is an economy flag, so it appends after the
      # hygiene + model prefix — never before --model.
      args = Claude.build_args("do work", model: "claude-haiku-4-5", effort: "low")
      assert args == @base ++ ["--model", "claude-haiku-4-5", "--effort", "low"]
    end

    test "all economy flags together render in a stable order, after the base head" do
      args =
        Claude.build_args("do work",
          tools: ["Read"],
          disallowed_tools: ["Bash"],
          mcp_config: ["cfg.json"],
          strict_mcp_config: true,
          max_turns: 4,
          exclude_dynamic_system_prompt_sections: true,
          no_session_persistence: true
        )

      assert args ==
               @base ++
                 [
                   "--tools",
                   "Read",
                   "--disallowedTools",
                   "Bash",
                   "--mcp-config",
                   "cfg.json",
                   "--strict-mcp-config",
                   "--max-turns",
                   "4",
                   "--exclude-dynamic-system-prompt-sections",
                   "--no-session-persistence"
                 ]
    end

    test "economy flags sit AFTER the existing hygiene + model args (purely additive)" do
      # The T4.8 hygiene + T19.6 model args must remain a contiguous prefix of the
      # economy args — the new flags only append, they never interleave.
      hygiene_and_model =
        Claude.build_args("do work", allowed_tools: ["Read"], model: "claude-haiku-4-5")

      with_economy =
        Claude.build_args("do work",
          allowed_tools: ["Read"],
          model: "claude-haiku-4-5",
          max_turns: 2
        )

      assert List.starts_with?(with_economy, hygiene_and_model)
      assert with_economy == hygiene_and_model ++ ["--max-turns", "2"]
    end
  end

  describe "byte-identical when no economy opt is supplied (golden guarantee)" do
    test "no economy opts at all == the pre-T36.1 base argv" do
      assert Claude.build_args("do work", []) == @base
    end

    test "the existing hygiene golden transcript is byte-for-byte unchanged" do
      # Mirrors the ClaudeAdapter golden: with hygiene flags but no economy opts the
      # argv is exactly the T4.8 shape.
      args =
        Claude.build_args("do work",
          max_budget_usd: 1.25,
          allowed_tools: ["Read"],
          permission_mode: "default"
        )

      assert args ==
               @base ++
                 [
                   "--max-budget-usd",
                   "1.25",
                   "--allowed-tools",
                   "Read",
                   "--permission-mode",
                   "default"
                 ]
    end

    test "empty / falsey economy values emit nothing (byte-identical to absent)" do
      args =
        Claude.build_args("do work",
          tools: [],
          disallowed_tools: "",
          mcp_config: nil,
          strict_mcp_config: false,
          max_turns: 0,
          exclude_dynamic_system_prompt_sections: false,
          no_session_persistence: nil,
          effort: ""
        )

      assert args == @base
    end

    test "a blank / nil :effort emits nothing (byte-identical to absent, T36.6)" do
      assert Claude.build_args("do work", effort: "") == @base
      assert Claude.build_args("do work", effort: nil) == @base
    end

    test "a cli_version alone (no economy opts) changes nothing" do
      assert Claude.build_args("do work", cli_version: "0.1.0") == @base
    end
  end

  describe "version-gated capability check (ADR-0047 risk note)" do
    test "an older CLI DROPS the version-sensitive flags rather than erroring" do
      # `--strict-mcp-config` / `--exclude-dynamic-system-prompt-sections` behavior
      # varies by Claude Code version; on a CLI older than their floor they are
      # dropped, while ungated flags still emit.
      args =
        Claude.build_args("do work",
          cli_version: "0.9.0",
          tools: ["Read"],
          strict_mcp_config: true,
          exclude_dynamic_system_prompt_sections: true,
          max_turns: 3
        )

      refute "--strict-mcp-config" in args
      refute "--exclude-dynamic-system-prompt-sections" in args
      # Ungated flags are unaffected by the gate.
      assert args == @base ++ ["--tools", "Read", "--max-turns", "3"]
    end

    test "a current CLI EMITS the version-sensitive flags" do
      args =
        Claude.build_args("do work",
          cli_version: "2.1.191",
          strict_mcp_config: true,
          exclude_dynamic_system_prompt_sections: true
        )

      assert args ==
               @base ++ ["--strict-mcp-config", "--exclude-dynamic-system-prompt-sections"]
    end

    test "an unknown cli_version is permissive — the flag is emitted, not withheld" do
      # kazi never withholds a flag just because it could not probe the binary.
      args = Claude.build_args("do work", strict_mcp_config: true)
      assert args == @base ++ ["--strict-mcp-config"]
    end

    test "an unparseable cli_version degrades to permissive (emit)" do
      args = Claude.build_args("do work", cli_version: "not-a-version", strict_mcp_config: true)
      assert args == @base ++ ["--strict-mcp-config"]
    end
  end

  describe "profile advertises the economy opts in supported_opts (ADR-0022 contract)" do
    test "the :claude profile declares each economy opt + :cli_version" do
      {:ok, profile} = Registry.fetch(:claude)

      for opt <- [
            :tools,
            :disallowed_tools,
            :mcp_config,
            :strict_mcp_config,
            :max_turns,
            :exclude_dynamic_system_prompt_sections,
            :no_session_persistence,
            :effort,
            :cli_version
          ] do
        assert opt in profile.supported_opts, "expected #{inspect(opt)} in supported_opts"
      end
    end

    test ":effort is Claude-only — advertised by :claude, NOT by :opencode (T36.6)" do
      # Parity-by-design: the reasoning-effort lever is a Claude flag, so only the
      # claude profile keeps it through `Kazi.Harness`'s supported_opts take; a
      # non-Claude harness never receives it.
      {:ok, claude} = Registry.fetch(:claude)
      {:ok, opencode} = Registry.fetch(:opencode)

      assert :effort in claude.supported_opts
      refute :effort in opencode.supported_opts
    end
  end
end
