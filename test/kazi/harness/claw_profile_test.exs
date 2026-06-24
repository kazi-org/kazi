defmodule Kazi.Harness.ClawProfileTest do
  # T14.4 (UC-032, ADR-0022): the built-in :claw harness profile — argv assembly
  # for `claw prompt <prompt>` and BEST-EFFORT raw-stdout parsing.
  #
  # claw-code is added BEST-EFFORT / DEMO-GRADE only: it emits NO documented JSON,
  # has no model flag, and is self-described as "an agent-managed museum exhibit
  # rather than a production tool" (ADR-0022). So unlike Codex/opencode (event
  # streams) and Antigravity (JSON envelope), `parse` does no decoding: it hands
  # the raw stdout back as :result with NO cost/token extraction. These tests drive
  # the profile's pure functions directly via the Profile API. The golden-transcript
  # case lives in conformance_test.exs; this file covers the unit-level edges.
  #
  # async: true — purely pure functions + checked-in data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.Harness.{Profile, Registry}

  describe "Registry lookup" do
    test "fetch(:claw) returns the claw profile" do
      assert {:ok, %Profile{id: :claw, command: "claw"} = profile} = Registry.fetch(:claw)

      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # claw has NO model flag and understands none of Claude's hygiene flags, so
      # supported_opts is just the per-run :command override (the test-stub seam).
      assert :command in profile.supported_opts
      refute :model in profile.supported_opts
      refute :max_budget_usd in profile.supported_opts
      refute :permission_mode in profile.supported_opts
      # claw is an argv-prompt harness (the default), NOT the antigravity file path.
      assert profile.prompt_via == :argv
    end

    test "fetch!/1 returns the profile and ids/0 lists :claw alongside the others" do
      assert %Profile{id: :claw} = Registry.fetch!(:claw)
      assert :claw in Registry.ids()
      assert :claude in Registry.ids()
      assert :opencode in Registry.ids()
      assert :codex in Registry.ids()
      assert :antigravity in Registry.ids()
    end
  end

  describe ":claw argv (Profile.build_args/3)" do
    test "renders the bare prompt subcommand: prompt <prompt>" do
      profile = Registry.fetch!(:claw)

      assert Profile.build_args(profile, "do X", []) == ["prompt", "do X"]
    end

    test "opts are IGNORED — claw has no model flag (a model opt adds nothing)" do
      profile = Registry.fetch!(:claw)

      # Even if a :model leaks through resolution, claw's argv never grows a flag.
      assert Profile.build_args(profile, "do X", model: "whatever") == ["prompt", "do X"]
    end

    test "the prompt text is passed through verbatim" do
      profile = Registry.fetch!(:claw)

      assert Profile.build_args(profile, "make the suite green", []) ==
               ["prompt", "make the suite green"]
    end
  end

  describe ":claw raw-stdout parse (Profile.parse/2) — BEST-EFFORT, no structure" do
    test "surfaces the raw stdout verbatim as :result" do
      profile = Registry.fetch!(:claw)

      raw = "Made the failing unit test pass.\nTouched lib/app/widget.ex."
      parsed = Profile.parse(profile, raw)

      assert parsed == %{result: raw}
    end

    test "invents NO cost or token fields (claw emits no structured output)" do
      profile = Registry.fetch!(:claw)

      parsed = Profile.parse(profile, "some answer text")

      assert parsed.result == "some answer text"
      refute Map.has_key?(parsed, :tokens)
      refute Map.has_key?(parsed, :cost)
      refute Map.has_key?(parsed, :cost_usd)
      refute Map.has_key?(parsed, :touched)
    end

    test "JSON-looking stdout is NOT decoded — it is still raw :result text" do
      profile = Registry.fetch!(:claw)

      # claw emits no JSON; even if a line happens to look like JSON, the profile
      # does not parse it — fidelity is degraded BY DESIGN (best-effort).
      raw = ~s({"result":"hi","usage":{"input_tokens":5}})
      parsed = Profile.parse(profile, raw)

      assert parsed == %{result: raw}
      refute Map.has_key?(parsed, :tokens)
    end

    test "empty / whitespace-only stdout degrades to %{} (additive, never crashes)" do
      profile = Registry.fetch!(:claw)

      assert Profile.parse(profile, "") == %{}
      assert Profile.parse(profile, "   \n\t ") == %{}
    end
  end
end
