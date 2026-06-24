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
end
