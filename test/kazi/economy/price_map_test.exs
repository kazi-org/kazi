defmodule Kazi.Economy.PriceMapTest do
  # T34.5 (UC-033, ADR-0046): the single, dated price map that turns a usage
  # token envelope into `cost_usd`. The contract under test: a KNOWN model yields
  # a cost computed per-token-class; an UNKNOWN model OMITS cost (returns :error,
  # never a guess); the table is dated and lives in one place.
  #
  # async: true — pure functions + literal data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.CLI.Usage
  alias Kazi.Economy.PriceMap

  describe "cost_usd/2 — a known model yields a cost" do
    test "prices each token class independently and sums them" do
      # claude-opus-4-8 (per 1M): input 5.00, cached 0.50, cache_write 6.25,
      # output 25.00, reasoning 25.00.
      usage = %{
        input_tokens: 1_000_000,
        cached_input_tokens: 1_000_000,
        cache_write_tokens: 1_000_000,
        output_tokens: 1_000_000,
        reasoning_tokens: 1_000_000
      }

      # 5.00 + 0.50 + 6.25 + 25.00 + 25.00 = 61.75
      assert PriceMap.cost_usd("claude-opus-4-8", usage) == {:ok, 61.75}
    end

    test "prices claude-sonnet-5 at list rates ($3 input / $15 output)" do
      # claude-sonnet-5 (per 1M, Anthropic list pricing): input 3.00, cached 0.30,
      # cache_write 3.75, output 15.00, reasoning 15.00. (Introductory $2/$10 runs
      # through 2026-08-31; the table tracks list price — see PriceMap moduledoc.)
      usage = %{
        input_tokens: 1_000_000,
        cached_input_tokens: 1_000_000,
        cache_write_tokens: 1_000_000,
        output_tokens: 1_000_000,
        reasoning_tokens: 1_000_000
      }

      # 3.00 + 0.30 + 3.75 + 15.00 + 15.00 = 37.05
      assert PriceMap.cost_usd("claude-sonnet-5", usage) == {:ok, 37.05}
    end

    test "a realistic split computes a fractional cost (cheap cached reads)" do
      # A cache-hit-heavy run: mostly cached reads, little fresh input.
      usage = %{
        input_tokens: 100,
        output_tokens: 250,
        cache_write_tokens: 0,
        cached_input_tokens: 5000
      }

      # opus-4-8: 100*5 + 250*25 + 0*6.25 + 5000*0.5, all /1e6
      #         = (500 + 6250 + 0 + 2500) / 1_000_000 = 0.00925
      assert PriceMap.cost_usd("claude-opus-4-8", usage) == {:ok, 0.00925}
    end

    test "every model in the table prices a single fresh-input token at its input rate" do
      for model <- PriceMap.models() do
        sheet = Map.fetch!(PriceMap.prices(), model)
        expected = Float.round(sheet.input / 1_000_000, 6)
        assert PriceMap.cost_usd(model, %{input_tokens: 1}) == {:ok, expected}
      end
    end

    test "a token class absent from the envelope contributes nothing (count of zero, not unknown)" do
      # Only output reported; the other four classes are absent → cost is output-only.
      assert PriceMap.cost_usd("claude-haiku-4-5", %{output_tokens: 1_000_000}) == {:ok, 5.0}
    end

    test "reads token fields under string keys too (renderer-agnostic)" do
      assert PriceMap.cost_usd("claude-sonnet-4-6", %{"input_tokens" => 1_000_000}) == {:ok, 3.0}
    end

    test "an empty envelope for a known model costs nothing (still {:ok, _}, not omitted)" do
      assert PriceMap.cost_usd("claude-opus-4-8", %{}) == {:ok, 0.0}
    end
  end

  describe "cost_usd/2 — an unknown model OMITS cost (never a guess)" do
    test "a model absent from the table returns :error" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert PriceMap.cost_usd("some-unpriced-model-v9", usage) == :error
    end

    test "a near-miss / typo'd id is NOT resolved to a priced model" do
      # Exact-id match only — a date-suffixed or misspelled id is unknown.
      assert PriceMap.cost_usd("claude-opus-4-8-20260101", %{input_tokens: 1}) == :error
      assert PriceMap.cost_usd("claude-opus", %{input_tokens: 1}) == :error
    end

    test "a non-binary model or non-map usage returns :error rather than crashing" do
      assert PriceMap.cost_usd(nil, %{input_tokens: 1}) == :error
      assert PriceMap.cost_usd(:claude, %{input_tokens: 1}) == :error
      assert PriceMap.cost_usd("claude-opus-4-8", nil) == :error
    end
  end

  describe "the table is dated and lives in one place" do
    test "as_of/0 is a single ISO-8601 date stamp" do
      assert PriceMap.as_of() =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end

    test "known?/1 reflects table membership" do
      assert PriceMap.known?("claude-opus-4-8")
      refute PriceMap.known?("some-unpriced-model-v9")
      refute PriceMap.known?(nil)
    end

    test "models/0 returns the priced ids, sorted, and each carries a full price sheet" do
      models = PriceMap.models()
      assert models == Enum.sort(models)
      assert "claude-opus-4-8" in models

      for model <- models do
        sheet = Map.fetch!(PriceMap.prices(), model)

        for key <- [:input, :cached, :output, :cache_write, :reasoning] do
          assert is_number(Map.fetch!(sheet, key)),
                 "#{model} is missing a real #{key} price"
        end

        # ZERO-STUB: no placeholder zeros — every priced model has real fresh-input
        # and output rates.
        assert sheet.input > 0
        assert sheet.output > 0
      end
    end

    test "every renderer token field is priced (no envelope class is silently unpriced)" do
      # The compile-time coupling guard enforces this against `Kazi.CLI.Usage`;
      # assert it at runtime too so the contract is visible in the suite. Pricing
      # 1M tokens of each renderer field (minus the computed `cost_usd`) yields a
      # strictly positive cost — proving each class actually feeds the sum (a
      # single token at a sub-$/M rate would round to zero at 6 dp).
      for field <- Usage.fields() -- [:cost_usd] do
        assert {:ok, cost} = PriceMap.cost_usd("claude-opus-4-8", %{field => 1_000_000})
        assert cost > 0, "#{field} did not contribute to the priced cost"
      end
    end
  end
end
