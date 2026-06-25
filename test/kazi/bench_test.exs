defmodule Kazi.BenchTest do
  @moduledoc """
  Hermetic unit tests for the PURE token-capture + report-aggregation core of the
  multi-iteration benchmark harness (T19.4, ADR-0010). Every assertion is driven
  by RECORDED `claude --output-format json` envelopes under
  `test/fixtures/bench/` — NO real `claude`, NO network. They pin:

    * `parse_capture/1` returns the correct per-dispatch token + cost figures from
      a recorded envelope (and degrades to a zeroed capture on a missing/garbage
      `usage`);
    * `arm_summary/2` / `report/1` aggregate a list of captures into the per-arm
      totals deterministically;
    * `render_table/1` renders the deterministic per-arm token + cost + iteration
      table.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bench

  @captures Path.expand("../fixtures/bench/captures", __DIR__)
  @bench_dir Path.expand("../fixtures/bench", __DIR__)

  defp envelope(path), do: path |> File.read!()

  describe "parse_capture/1" do
    test "extracts input/output/cache-creation/cache-read/total + cost from a recorded envelope" do
      capture = Bench.parse_capture(envelope(Path.join(@captures, "A.001.json")))

      assert capture.input == 12_972
      assert capture.output == 1_116
      assert capture.cache_creation == 24_236
      assert capture.cache_read == 288_183
      # total is the sum of the four token fields (mirrors Profiles.Claude).
      assert capture.total == 12_972 + 1_116 + 24_236 + 288_183
      assert capture.cost_usd == 0.4790
    end

    test "a prefix-cache-HIT dispatch (arm C, dispatch 2) shows cache_read, low input" do
      capture = Bench.parse_capture(envelope(Path.join(@captures, "C.002.json")))

      assert capture.input == 1_200
      assert capture.cache_read == 96_000
      assert capture.cache_creation == 0
      assert capture.cost_usd == 0.0400
    end

    test "accepts an already-decoded map, not just a JSON string" do
      decoded =
        envelope(Path.join(@captures, "B.001.json")) |> Jason.decode!()

      assert Bench.parse_capture(decoded) ==
               Bench.parse_capture(envelope(Path.join(@captures, "B.001.json")))
    end

    test "degrades to a zeroed capture on an envelope with no usage" do
      capture = Bench.parse_capture(envelope(Path.join(@bench_dir, "no_usage.json")))

      assert capture == %{
               input: 0,
               output: 0,
               cache_creation: 0,
               cache_read: 0,
               total: 0,
               cost_usd: 0.0
             }
    end

    test "degrades to a zeroed capture on non-JSON garbage (never crashes)" do
      assert Bench.parse_capture("this is not json {{{") == %{
               input: 0,
               output: 0,
               cache_creation: 0,
               cache_read: 0,
               total: 0,
               cost_usd: 0.0
             }
    end

    test "treats negative / non-integer token fields as zero" do
      capture =
        Bench.parse_capture(%{
          "usage" => %{
            "input_tokens" => -5,
            "output_tokens" => "nope",
            "cache_creation_input_tokens" => 10,
            "cache_read_input_tokens" => 20
          }
        })

      assert capture.input == 0
      assert capture.output == 0
      assert capture.cache_creation == 10
      assert capture.cache_read == 20
      assert capture.total == 30
    end
  end

  describe "arm_summary/2" do
    test "sums a list of per-dispatch captures, counting iterations" do
      captures =
        for n <- ["B.001.json", "B.002.json", "B.003.json"] do
          Bench.parse_capture(envelope(Path.join(@captures, n)))
        end

      summary = Bench.arm_summary("B — no prefix", captures)

      assert summary.arm == "B — no prefix"
      assert summary.iterations == 3
      assert summary.input == 4_300 + 4_500 + 4_100
      assert summary.output == 400 + 420 + 380
      assert summary.cache_creation == 96_000 + 96_500 + 95_000
      assert summary.cache_read == 0

      assert summary.total ==
               summary.input + summary.output + summary.cache_creation + summary.cache_read

      assert_in_delta summary.cost_usd, 0.16 + 0.17 + 0.15, 1.0e-9
    end

    test "an empty arm yields a zeroed summary with iterations: 0" do
      summary = Bench.arm_summary("Z — empty", [])

      assert summary.iterations == 0
      assert summary.input == 0
      assert summary.total == 0
      assert summary.cost_usd == 0.0
    end
  end

  describe "report/1 + render_table/1" do
    defp arm_captures(arm) do
      @captures
      |> Path.join("#{arm}.*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn p -> p |> File.read!() |> Bench.parse_capture() end)
    end

    test "report/1 builds one summary per arm, preserving order" do
      report =
        Bench.report([
          {"A — vanilla", arm_captures("A")},
          {"B — no prefix", arm_captures("B")},
          {"C — prefix", arm_captures("C")}
        ])

      assert Enum.map(report, & &1.arm) == ["A — vanilla", "B — no prefix", "C — prefix"]
      assert Enum.map(report, & &1.iterations) == [1, 3, 3]

      # The arm-C prefix story: dispatches 2 & 3 are served from cache, so arm C's
      # summed cache_read is large while its summed cost is far below arm B's.
      [_a, b, c] = report
      assert c.cache_read == 96_000 + 95_000
      assert c.cost_usd < b.cost_usd
    end

    test "render_table/1 renders a deterministic markdown table" do
      report =
        Bench.report([
          {"A", arm_captures("A")},
          {"B", arm_captures("B")},
          {"C", arm_captures("C")}
        ])

      table = Bench.render_table(report)

      assert table ==
               """
               | Arm | Iterations | Input | Output | Cache-create | Cache-read | Total | Cost (USD) |
               |---|---|---|---|---|---|---|---|
               | A | 1 | 12972 | 1116 | 24236 | 288183 | 326507 | 0.4790 |
               | B | 3 | 12900 | 1200 | 287500 | 0 | 301600 | 0.4800 |
               | C | 3 | 6600 | 1170 | 96000 | 191000 | 294770 | 0.2380 |
               """

      # The table is deterministic — rendering twice yields the same bytes.
      assert Bench.render_table(report) == table
    end
  end

  describe "tiering arms (T19.7, ADR-0033/0035)" do
    @tiering Path.expand("../fixtures/bench/tiering", __DIR__)

    defp tiering_result(arm),
      do: Path.join(@tiering, "#{arm}.result.json") |> File.read!() |> Jason.decode!()

    defp tiering_envelopes(arm) do
      @tiering
      |> Path.join("#{arm}.[0-9]*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&File.read!/1)
    end

    test "tiering_arm/3 folds one static arm: model, dispatch, tokens, cost, converged, correct" do
      arm =
        Bench.tiering_arm(
          "static-cheap",
          tiering_result("static-cheap"),
          tiering_envelopes("static-cheap")
        )

      assert arm.arm == "static-cheap"
      assert arm.models == ["claude-haiku-4-5"]
      assert arm.dispatches == 1
      assert arm.tokens == 100 + 1000 + 20_000 + 70_000
      assert arm.cost_usd == 0.05
      assert arm.converged
      assert arm.correct
    end

    test "an escalating arm carries the climbed ladder, summed dispatches/tokens/cost" do
      arm =
        Bench.tiering_arm(
          "escalating",
          tiering_result("escalating"),
          tiering_envelopes("escalating")
        )

      # The model column shows the climb in dispatch order (Haiku → Sonnet → Opus).
      assert arm.models == ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"]
      assert arm.dispatches == 3
      assert arm.tokens == 91_100 + 89_100 + 81_100
      assert_in_delta arm.cost_usd, 0.35, 1.0e-9
      assert arm.converged
      assert arm.correct
    end

    test "a cheaper-but-FAILS arm is visible: converged=false, correct=false (no false done)" do
      arm =
        Bench.tiering_arm(
          "static-fails",
          tiering_result("static-fails"),
          tiering_envelopes("static-fails")
        )

      refute arm.converged
      refute arm.correct
      # the $ it spent failing is still counted (a failed cheap grind is not free).
      assert arm.cost_usd == 0.05
    end

    test "a converged run with a FAILING predicate is not 'correct' (predicate is the oracle)" do
      result = %{"status" => "converged", "predicates" => [%{"id" => "p1", "verdict" => "fail"}]}
      arm = Bench.tiering_arm("x", result, tiering_envelopes("static-cheap"))

      assert arm.converged
      refute arm.correct
    end

    test "tiering_report/1 preserves order and render_tiering_table/1 is deterministic" do
      report =
        Bench.tiering_report([
          {"vanilla-frontier", tiering_result("vanilla-frontier"),
           tiering_envelopes("vanilla-frontier")},
          {"static-cheap", tiering_result("static-cheap"), tiering_envelopes("static-cheap")},
          {"escalating", tiering_result("escalating"), tiering_envelopes("escalating")}
        ])

      assert Enum.map(report, & &1.arm) == ["vanilla-frontier", "static-cheap", "escalating"]

      table = Bench.render_tiering_table(report)

      assert table ==
               """
               | Arm | Model(s) | Dispatches | Tokens | Cost (USD) | Converged | Correct |
               |---|---|---|---|---|---|---|
               | vanilla-frontier | claude-opus-4-8 | 1 | 81100 | 0.1600 | yes | yes |
               | static-cheap | claude-haiku-4-5 | 1 | 91100 | 0.0500 | yes | yes |
               | escalating | claude-haiku-4-5 → claude-sonnet-4-6 → claude-opus-4-8 | 3 | 261300 | 0.3500 | yes | yes |
               """

      assert Bench.render_tiering_table(report) == table
    end
  end

  describe "tier × surface arms (T36.5, ADR-0047)" do
    @tier_surface Path.expand("../fixtures/bench/tier_surface", __DIR__)

    defp ts_result(arm),
      do: Path.join(@tier_surface, "#{arm}.result.json") |> File.read!() |> Jason.decode!()

    defp ts_envelopes(arm) do
      @tier_surface
      |> Path.join("#{arm}.[0-9]*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&File.read!/1)
    end

    test "tier_surface_arm/3 parses tier+surface from the label and folds the real $/tokens" do
      arm = Bench.tier_surface_arm("t1-on", ts_result("t1-on"), ts_envelopes("t1-on"))

      assert arm.arm == "t1-on"
      assert arm.tier == 1
      assert arm.surface == :minimal
      assert arm.dispatches == 1
      assert arm.tokens == 34_640
      assert arm.cost_usd == 0.05
      assert arm.converged
      assert arm.correct
      assert arm.converged_predicates == 1
      assert arm.cost_per_converged_predicate == 0.05
      refute arm.stuck
      # the tiering-only :models key is dropped for the tier-surface shape
      refute Map.has_key?(arm, :models)
    end

    test "a '-off' label parses to the :ambient (surface OFF) arm" do
      arm = Bench.tier_surface_arm("t1-off", ts_result("t1-off"), ts_envelopes("t1-off"))
      assert arm.surface == :ambient
      assert arm.tier == 1
    end

    test "a STUCK arm with no passing predicate: cost/conv-pred is nil (no cost-per-zero), stuck true" do
      arm = Bench.tier_surface_arm("t3-on", ts_result("t3-on"), ts_envelopes("t3-on"))

      assert arm.stuck
      refute arm.converged
      refute arm.correct
      assert arm.converged_predicates == 0
      assert arm.cost_per_converged_predicate == nil
    end

    test "tier_surface_report/1 preserves order and render_tier_surface_table/1 is deterministic" do
      report =
        Bench.tier_surface_report([
          {"t0-on", ts_result("t0-on"), ts_envelopes("t0-on")},
          {"t1-on", ts_result("t1-on"), ts_envelopes("t1-on")},
          {"t1-off", ts_result("t1-off"), ts_envelopes("t1-off")},
          {"t2-on", ts_result("t2-on"), ts_envelopes("t2-on")},
          {"t3-on", ts_result("t3-on"), ts_envelopes("t3-on")}
        ])

      assert Enum.map(report, & &1.arm) == ["t0-on", "t1-on", "t1-off", "t2-on", "t3-on"]

      table = Bench.render_tier_surface_table(report)

      assert table ==
               """
               | Arm | Tier | Surface | Dispatches | Tokens | Cost (USD) | Cost/conv-pred | Converged | Correct | Stuck |
               |---|---|---|---|---|---|---|---|---|---|
               | t0-on | 0 | on | 1 | 30600 | 0.0400 | 0.0400 | yes | yes | no |
               | t1-on | 1 | on | 1 | 34640 | 0.0500 | 0.0500 | yes | yes | no |
               | t1-off | 1 | off | 1 | 36660 | 0.0550 | 0.0550 | yes | yes | no |
               | t2-on | 2 | on | 1 | 38680 | 0.0600 | 0.0600 | yes | yes | no |
               | t3-on | 3 | on | 1 | 40900 | 0.0900 | n/a | no | no | yes |
               """

      assert Bench.render_tier_surface_table(report) == table
    end
  end
end
