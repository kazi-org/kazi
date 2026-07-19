defmodule Kazi.Harness.GeminiCliProfileTest do
  # T37.1 (UC-032, ADR-0022): the built-in :gemini_cli harness profile — argv
  # assembly for `gemini -p <prompt> -o json --approval-mode yolo [-m …]` and
  # parsing of Gemini's `-o json` envelope (`response` + nested `stats` token
  # counts, or an `error` object).
  #
  # Gemini is a fully-conformant addition (native `-o json`, like Codex); its
  # parser MIRRORS the Antigravity single-envelope path. There is no checked-in
  # stub binary, so these tests drive the profile's pure functions directly:
  # build_args via the Profile API, and the JSON parser against literal sample
  # envelopes (the same bytes the generic CliAdapter would hand it). The
  # golden-transcript fixture case lives in conformance_test.exs; this file covers
  # the unit-level edges.
  #
  # async: true — purely pure functions + checked-in data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.Harness.{Profile, Registry}

  describe "Registry lookup" do
    test "fetch(:gemini_cli) returns the gemini_cli profile" do
      assert {:ok, %Profile{id: :gemini_cli, command: "gemini"} = profile} =
               Registry.fetch(:gemini_cli)

      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # :model is declared so resolution forwards it; Claude-only hygiene flags are
      # NOT in supported_opts, so they are never passed to gemini.
      assert :model in profile.supported_opts
      assert :command in profile.supported_opts
      refute :max_budget_usd in profile.supported_opts
      refute :permission_mode in profile.supported_opts
      # gemini is fully conformant — no #76-style non-TTY workaround, so the prompt
      # travels via the argv (the default :argv), NOT a temp file.
      assert profile.prompt_via == :argv
    end

    test "fetch!/1 returns the profile and ids/0 lists :gemini_cli alongside the others" do
      assert %Profile{id: :gemini_cli} = Registry.fetch!(:gemini_cli)
      assert :gemini_cli in Registry.ids()
      assert :claude in Registry.ids()
      assert :codex in Registry.ids()
      assert :antigravity in Registry.ids()
    end
  end

  describe ":gemini_cli argv (Profile.build_args/3)" do
    test "with a model: -p <prompt> -o json --approval-mode yolo -m <m>" do
      profile = Registry.fetch!(:gemini_cli)

      assert Profile.build_args(profile, "do X", model: "gemini-2.5-pro") ==
               ["-p", "do X", "-o", "json", "--approval-mode", "yolo", "-m", "gemini-2.5-pro"]
    end

    test "without a model: -p <prompt> -o json --approval-mode yolo" do
      profile = Registry.fetch!(:gemini_cli)

      assert Profile.build_args(profile, "do X", []) ==
               ["-p", "do X", "-o", "json", "--approval-mode", "yolo"]
    end

    test "an empty-string model is treated as no model (no -m flag)" do
      profile = Registry.fetch!(:gemini_cli)

      assert Profile.build_args(profile, "do X", model: "") ==
               ["-p", "do X", "-o", "json", "--approval-mode", "yolo"]
    end

    test "a non-string model is ignored (no -m flag)" do
      profile = Registry.fetch!(:gemini_cli)

      assert Profile.build_args(profile, "do X", model: nil) ==
               ["-p", "do X", "-o", "json", "--approval-mode", "yolo"]
    end

    test "--approval-mode yolo is ALWAYS present (kazi drives non-interactively)" do
      profile = Registry.fetch!(:gemini_cli)
      argv = Profile.build_args(profile, "do X", [])

      assert ["--approval-mode", "yolo"] -- argv == []
    end
  end

  describe ":gemini_cli JSON parse (Profile.parse/2)" do
    test "reads the response text and summed stats tokens from the -o json envelope" do
      profile = Registry.fetch!(:gemini_cli)

      envelope =
        ~s({"session_id":"sess_a","response":"Made the failing unit test pass.",) <>
          ~s("stats":{"models":{"gemini-2.5-pro":{"tokens":) <>
          ~s({"promptTokenCount":1500,"candidatesTokenCount":400,"totalTokenCount":1900}}}}})

      parsed = Profile.parse(profile, envelope)

      assert parsed.result == "Made the failing unit test pass."
      assert parsed.tokens == 1900
      assert parsed.cost == %{tokens: 1900}
      refute Map.has_key?(parsed, :error)
    end

    test "falls back to prompt + candidates when totalTokenCount is absent" do
      profile = Registry.fetch!(:gemini_cli)

      envelope =
        ~s({"response":"done","stats":{"models":{"gemini-2.5-flash":{"tokens":) <>
          ~s({"promptTokenCount":120,"candidatesTokenCount":80}}}}})

      parsed = Profile.parse(profile, envelope)

      assert parsed.tokens == 200
      assert parsed.cost == %{tokens: 200}
    end

    test "sums token totals across multiple reported models" do
      profile = Registry.fetch!(:gemini_cli)

      envelope =
        ~s({"response":"done","stats":{"models":{) <>
          ~s("gemini-2.5-pro":{"tokens":{"totalTokenCount":1000}},) <>
          ~s("gemini-2.5-flash":{"tokens":{"totalTokenCount":250}}}}})

      assert Profile.parse(profile, envelope).tokens == 1250
    end

    test "when stats carry no usable count, token keys are OMITTED (no fabrication)" do
      profile = Registry.fetch!(:gemini_cli)

      parsed = Profile.parse(profile, ~s({"response":"done, no usage"}))

      assert parsed.result == "done, no usage"
      refute Map.has_key?(parsed, :tokens)
      refute Map.has_key?(parsed, :cost)
    end

    test "an error envelope with no response surfaces :error and leaves :result absent" do
      profile = Registry.fetch!(:gemini_cli)

      envelope =
        ~s({"error":{"type":"AuthError","message":"GEMINI_API_KEY is not set","code":401}})

      parsed = Profile.parse(profile, envelope)

      assert parsed.error == "GEMINI_API_KEY is not set"
      refute Map.has_key?(parsed, :result)
    end

    test "a response present alongside an error still surfaces :result (no :error)" do
      profile = Registry.fetch!(:gemini_cli)

      envelope = ~s({"response":"partial answer","error":{"message":"a non-fatal warning"}})

      parsed = Profile.parse(profile, envelope)

      assert parsed.result == "partial answer"
      refute Map.has_key?(parsed, :error)
    end

    test "empty/malformed/non-JSON output degrades to %{} (additive, never crashes)" do
      profile = Registry.fetch!(:gemini_cli)

      assert Profile.parse(profile, "") == %{}
      assert Profile.parse(profile, "   \n") == %{}
      assert Profile.parse(profile, "not json at all") == %{}
      # A valid JSON object with no recognised field yields nothing extractable.
      assert Profile.parse(profile, ~s({"session_id":"sess_x"})) == %{}
      # A JSON array (not an object envelope) yields nothing.
      assert Profile.parse(profile, ~s([1,2,3])) == %{}
    end
  end
end
