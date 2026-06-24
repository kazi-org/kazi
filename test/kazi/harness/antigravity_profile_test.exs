defmodule Kazi.Harness.AntigravityProfileTest do
  # T14.3 (UC-032, ADR-0022): the built-in :antigravity harness profile — argv
  # assembly for the #76 non-TTY workaround (`run --prompt-file <tmp> --output
  # json --yes [--model …]`) and parsing of Antigravity's `--output json`
  # envelope.
  #
  # Antigravity is conformant WITH a workaround: the bare `-p`/`--prompt` flag
  # silently drops stdout under a non-TTY subprocess (bug
  # google-antigravity/antigravity-cli#76 — exactly kazi's mode), so the profile
  # declares `prompt_via: :file` and renders `--prompt-file` instead. These tests
  # drive the profile's pure functions directly: build_args via the Profile API
  # (supplying the temp path the CliAdapter would materialize), and the JSON parser
  # against literal sample envelopes. The golden-transcript case lives in
  # conformance_test.exs; this file covers the unit-level edges and the #76 guard.
  #
  # async: true — purely pure functions + checked-in data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.Harness.{Profile, Registry}

  @prompt_file "/tmp/kazi-prompt-test.txt"

  describe "Registry lookup" do
    test "fetch(:antigravity) returns the antigravity profile with prompt_via: :file" do
      assert {:ok, %Profile{id: :antigravity, command: "antigravity"} = profile} =
               Registry.fetch(:antigravity)

      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # prompt_via: :file is what tells the CliAdapter to materialize the temp file
      # (the #76 workaround). The other profiles default to :argv.
      assert profile.prompt_via == :file
      # :model is declared so resolution forwards it; Claude-only hygiene flags are
      # NOT in supported_opts, so they are never passed to antigravity.
      assert :model in profile.supported_opts
      assert :command in profile.supported_opts
      refute :max_budget_usd in profile.supported_opts
      refute :permission_mode in profile.supported_opts
    end

    test "fetch!/1 returns the profile and ids/0 lists :antigravity alongside the others" do
      assert %Profile{id: :antigravity} = Registry.fetch!(:antigravity)
      assert :antigravity in Registry.ids()
      assert :claude in Registry.ids()
      assert :opencode in Registry.ids()
      assert :codex in Registry.ids()
    end
  end

  describe ":antigravity argv (Profile.build_args/3) — the #76 workaround" do
    test "with a model: run --prompt-file <tmp> --output json --yes --model <m>" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.build_args(profile, "do X",
               prompt_file: @prompt_file,
               model: "gemini-2.5-pro"
             ) ==
               [
                 "run",
                 "--prompt-file",
                 @prompt_file,
                 "--output",
                 "json",
                 "--yes",
                 "--model",
                 "gemini-2.5-pro"
               ]
    end

    test "without a model: just run --prompt-file <tmp> --output json --yes" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.build_args(profile, "do X", prompt_file: @prompt_file) ==
               ["run", "--prompt-file", @prompt_file, "--output", "json", "--yes"]
    end

    test "an empty-string model is treated as no model (no --model flag)" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.build_args(profile, "do X", prompt_file: @prompt_file, model: "") ==
               ["run", "--prompt-file", @prompt_file, "--output", "json", "--yes"]
    end

    test "a non-string model is ignored (no --model flag)" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.build_args(profile, "do X", prompt_file: @prompt_file, model: nil) ==
               ["run", "--prompt-file", @prompt_file, "--output", "json", "--yes"]
    end

    test "the argv NEVER contains the bare -p/--prompt that drops stdout under a non-TTY" do
      profile = Registry.fetch!(:antigravity)
      argv = Profile.build_args(profile, "the prompt text", prompt_file: @prompt_file)

      refute "-p" in argv
      refute "--prompt" in argv
      # The prompt travels via the file, NOT the argv: its text must not appear.
      refute "the prompt text" in argv
    end

    test "the prompt argument is ignored (prompt travels via the file, not argv)" do
      profile = Registry.fetch!(:antigravity)

      a = Profile.build_args(profile, "prompt A", prompt_file: @prompt_file)

      b =
        Profile.build_args(profile, "a completely different prompt B", prompt_file: @prompt_file)

      assert a == b
    end

    test "a missing opts[:prompt_file] raises (the adapter always supplies it)" do
      profile = Registry.fetch!(:antigravity)

      assert_raise ArgumentError, ~r/requires opts\[:prompt_file\]/, fn ->
        Profile.build_args(profile, "do X", [])
      end
    end
  end

  describe ":antigravity JSON parse (Profile.parse/2)" do
    test "reads the result text and summed usage from the --output json envelope" do
      profile = Registry.fetch!(:antigravity)

      envelope =
        ~s({"type":"result","result":"Made the failing unit test pass.",) <>
          ~s("usage":{"input_tokens":1500,"output_tokens":400,"total_tokens":1900}})

      parsed = Profile.parse(profile, envelope)

      assert parsed.result == "Made the failing unit test pass."
      # input 1500 + output 400.
      assert parsed.tokens == 1900
      assert parsed.cost == %{tokens: 1900}
    end

    test "accepts the `response` alias for the assistant text" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.parse(profile, ~s({"response":"answer"})).result == "answer"
    end

    test "accepts a nested message.content for the assistant text" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.parse(profile, ~s({"message":{"content":"nested answer"}})).result ==
               "nested answer"
    end

    test "falls back to total_tokens when input/output components are absent" do
      profile = Registry.fetch!(:antigravity)

      envelope = ~s({"result":"done","usage":{"total_tokens":777}})
      parsed = Profile.parse(profile, envelope)

      assert parsed.tokens == 777
      assert parsed.cost == %{tokens: 777}
    end

    test "when no usage is reported, token keys are OMITTED (no fabrication)" do
      profile = Registry.fetch!(:antigravity)

      parsed = Profile.parse(profile, ~s({"result":"done, no usage"}))

      assert parsed.result == "done, no usage"
      refute Map.has_key?(parsed, :tokens)
      refute Map.has_key?(parsed, :cost)
    end

    test "EMPTY stdout (the #76 bug if the workaround regressed) degrades to %{}" do
      profile = Registry.fetch!(:antigravity)

      # This is precisely what bug #76 produces: exit 0, empty stdout. The parser
      # must NOT crash or fabricate — it yields %{} and the budget estimates.
      assert Profile.parse(profile, "") == %{}
      assert Profile.parse(profile, "   \n") == %{}
    end

    test "malformed/irrelevant output degrades to %{} (additive, never crashes)" do
      profile = Registry.fetch!(:antigravity)

      assert Profile.parse(profile, "not json at all") == %{}
      # A valid JSON object with no recognised field yields nothing extractable.
      assert Profile.parse(profile, ~s({"type":"status","status":"running"})) == %{}
      # A JSON array (not an object envelope) yields nothing.
      assert Profile.parse(profile, ~s([1,2,3])) == %{}
    end
  end
end
