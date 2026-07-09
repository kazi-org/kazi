defmodule Kazi.Harness.OpencodeProfileTest do
  # T8.4 (UC-026, ADR-0016): the built-in :opencode harness profile — argv
  # assembly for `opencode run … --format json [--model …]` and parsing of
  # opencode's NDJSON event stream.
  #
  # NOTE: Kazi.Harness.CliAdapter (the generic subprocess driver) is delivered in
  # parallel by T8.2 and is NOT on origin/main in this worktree. So the end-to-end
  # `CliAdapter.run/3` assertion the task describes is covered once T8.2 lands;
  # here we test the profile directly: build_args via the Profile API, and the
  # NDJSON parser against the REAL stub binary's stdout (we run the stub ourselves
  # and feed its output to Profile.parse/2 — the same bytes the adapter would).
  #
  # Not async: the stub reads STUB_* OS env (process-global); per-test isolation is
  # via unique tmp workspaces + serial run.
  use ExUnit.Case, async: false

  alias Kazi.Harness.{Profile, Registry}

  @json_stub Path.expand("../../support/stub_opencode_json.sh", __DIR__)

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-opencode-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  describe "Registry lookup" do
    test "fetch(:opencode) returns the opencode profile" do
      assert {:ok, %Profile{id: :opencode, command: "opencode"} = profile} =
               Registry.fetch(:opencode)

      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # :model is declared so resolution forwards it; :workspace is declared so
      # the CliAdapter-threaded workspace renders as --dir (T39.7); Claude-only
      # hygiene flags are NOT in supported_opts, so they are never passed to
      # opencode.
      assert :model in profile.supported_opts
      assert :command in profile.supported_opts
      assert :workspace in profile.supported_opts
      refute :max_budget_usd in profile.supported_opts
      refute :permission_mode in profile.supported_opts
    end

    test "ids/0 lists :opencode alongside :claude" do
      assert :opencode in Registry.ids()
      assert :claude in Registry.ids()
    end
  end

  describe ":opencode argv (Profile.build_args/3)" do
    test "with a model: run <prompt> --format json --model <provider/model>" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X", model: "local/qwen3.6") ==
               ["run", "do X", "--format", "json", "--model", "local/qwen3.6"]
    end

    test "without a model: just run <prompt> --format json" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X", []) ==
               ["run", "do X", "--format", "json"]
    end

    test "an empty-string model is treated as no model (no --model flag)" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X", model: "") ==
               ["run", "do X", "--format", "json"]
    end

    # T39.7 regression: `opencode run` ignores the launch cwd (it resolves its
    # own project root / attaches to a persistent server), so the workspace the
    # CliAdapter threads in MUST render as an explicit `--dir <workspace>` —
    # without it the inner agent's edits land outside the goal's workspace and
    # kazi's workspace-scoped predicates never converge.
    test "with a workspace: --dir <workspace> is rendered (T39.7)" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X", workspace: "/tmp/goal-ws") ==
               ["run", "do X", "--format", "json", "--dir", "/tmp/goal-ws"]
    end

    test "workspace and model together: --dir precedes --model (T39.7)" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X",
               workspace: "/tmp/goal-ws",
               model: "local/qwen3.6"
             ) ==
               [
                 "run",
                 "do X",
                 "--format",
                 "json",
                 "--dir",
                 "/tmp/goal-ws",
                 "--model",
                 "local/qwen3.6"
               ]
    end

    test "an empty-string workspace is treated as no workspace (no --dir flag)" do
      profile = Registry.fetch!(:opencode)

      assert Profile.build_args(profile, "do X", workspace: "") ==
               ["run", "do X", "--format", "json"]
    end
  end

  describe ":opencode NDJSON parse (Profile.parse/2 against the real stub stdout)" do
    test "carries the final :result text and summed :tokens/:cost from the stream",
         %{workspace: workspace} do
      profile = Registry.fetch!(:opencode)

      {output, 0} = System.cmd(@json_stub, [], cd: workspace)

      # The stub really ran in the workspace (edit landed there).
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))

      parsed = Profile.parse(profile, output)

      assert parsed.result == "Made the failing unit test pass."
      # input 120 + output 340 + reasoning 40 + cache.read 900 + cache.write 0.
      assert parsed.tokens == 120 + 340 + 40 + 900 + 0
      assert parsed.cost == %{tokens: 1400}
      assert parsed.cost_usd == 0.0042
    end

    test "with overridden token/cost env, parse reports the exact stub totals",
         %{workspace: workspace} do
      profile = Registry.fetch!(:opencode)

      env = [
        {"STUB_INPUT_TOKENS", "10"},
        {"STUB_OUTPUT_TOKENS", "20"},
        {"STUB_REASONING_TOKENS", "5"},
        {"STUB_CACHE_READ_TOKENS", "7"},
        {"STUB_CACHE_WRITE_TOKENS", "3"},
        {"STUB_COST_USD", "0.5"}
      ]

      {output, 0} = System.cmd(@json_stub, [], cd: workspace, env: env)
      parsed = Profile.parse(profile, output)

      assert parsed.tokens == 10 + 20 + 5 + 7 + 3
      assert parsed.cost == %{tokens: 45}
      assert parsed.cost_usd == 0.5
    end

    test "when the stream reports NO usage, token keys are OMITTED (no fabrication)",
         %{workspace: workspace} do
      profile = Registry.fetch!(:opencode)

      {output, 0} = System.cmd(@json_stub, [], cd: workspace, env: [{"STUB_NO_USAGE", "1"}])
      parsed = Profile.parse(profile, output)

      # The result text still comes through additively...
      assert parsed.result == "Made the failing unit test pass."
      # ...but with no usage event, the budget falls back to an estimate (ADR-0008).
      refute Map.has_key?(parsed, :tokens)
      refute Map.has_key?(parsed, :cost)
      refute Map.has_key?(parsed, :cost_usd)
    end

    test "malformed/empty output degrades to %{} (additive, never crashes)" do
      profile = Registry.fetch!(:opencode)

      assert Profile.parse(profile, "") == %{}
      assert Profile.parse(profile, "not json at all\nstill not json") == %{}
      # A valid-but-irrelevant event yields nothing extractable.
      assert Profile.parse(profile, ~s({"type":"session.created","properties":{}})) == %{}
    end

    test "last assistant text wins as :result across multiple text parts" do
      profile = Registry.fetch!(:opencode)

      stream =
        Enum.join(
          [
            ~s({"type":"message.part.updated","properties":{"part":{"type":"text","text":"first"}}}),
            ~s({"type":"message.part.updated","properties":{"part":{"type":"text","text":"final answer"}}})
          ],
          "\n"
        )

      assert Profile.parse(profile, stream).result == "final answer"
    end

    # A RICHER, multi-event fixture (T8.9): a realistic interleaved opencode
    # `--format json` turn — session/step lifecycle events, tool-call parts, two
    # assistant text parts, TWO `message.updated` usage events (incremental then
    # final), and a trailing non-JSON plain-text echo. It exercises the parser's
    # tolerance (skip-unrecognised), last-wins for text AND usage, and that
    # tool/lifecycle noise contributes nothing — beyond the simple two-line
    # streams already covered above.
    test "rich interleaved stream: skips noise, takes last text + last usage (last-wins)" do
      profile = Registry.fetch!(:opencode)

      stream =
        Enum.join(
          [
            # Lifecycle + an unrecognised top-level event — ignored.
            ~s({"type":"session.created","properties":{"info":{"id":"ses_x"}}}),
            ~s({"type":"message.part.updated","properties":{"part":{"id":"p0","type":"step-start"}}}),
            # A tool-call part (not text) — contributes no :result.
            ~s({"type":"message.part.updated","properties":{"part":{"id":"p1","type":"tool","tool":"edit","state":{"status":"completed"}}}}),
            # First assistant text part (superseded by the later one).
            ~s({"type":"message.part.updated","properties":{"part":{"id":"p2","type":"text","text":"working on it"}}}),
            # An INCREMENTAL usage event — superseded by the final one below.
            ~s({"type":"message.updated","properties":{"info":{"role":"assistant","cost":0.001,"tokens":{"input":5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}}}),
            # The FINAL assistant text part — this is the :result.
            ~s({"type":"message.part.updated","properties":{"part":{"id":"p3","type":"text","text":"Done. The test is green."}}}),
            # The FINAL usage event — last-wins for tokens AND cost.
            ~s({"type":"message.updated","properties":{"info":{"role":"assistant","cost":0.0211,"tokens":{"input":700,"output":120,"reasoning":33,"cache":{"read":2000,"write":50}}}}}),
            # A trailing non-JSON plain-text echo of the final part (non-TTY mode).
            "Done. The test is green."
          ],
          "\n"
        )

      parsed = Profile.parse(profile, stream)

      assert parsed.result == "Done. The test is green."
      # Final usage wins: 700 + 120 + 33 + 2000 + 50.
      assert parsed.tokens == 700 + 120 + 33 + 2000 + 50
      assert parsed.cost == %{tokens: 2903}
      assert parsed.cost_usd == 0.0211
    end

    test "usage carried on a step-finish part (not message.updated) is still summed" do
      # Robustness to shape drift (ADR-0016 moduledoc): tokens may arrive on a
      # `part` rather than `info`. The parser scans both wrappings.
      profile = Registry.fetch!(:opencode)

      stream =
        Enum.join(
          [
            ~s({"type":"message.part.updated","properties":{"part":{"type":"text","text":"ok"}}}),
            ~s({"type":"message.part.updated","properties":{"part":{"type":"step-finish","cost":0.003,"tokens":{"input":10,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}}})
          ],
          "\n"
        )

      parsed = Profile.parse(profile, stream)

      assert parsed.result == "ok"
      assert parsed.tokens == 12
      assert parsed.cost == %{tokens: 12}
      assert parsed.cost_usd == 0.003
    end
  end
end
