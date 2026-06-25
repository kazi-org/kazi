defmodule Kazi.CLI.UsageTest do
  @moduledoc """
  T34.1 (ADR-0046): the `usage` economy envelope renderer.

  The renderer is the heart of the additive envelope — it surfaces ONLY the
  token/cost components a harness actually reported and OMITS absent ones (absent
  ≠ zero, honest-unknown). These unit tests pin that present/absent behaviour
  directly; the end-to-end wiring through the `--json` result is covered by
  `Kazi.CLIRunJsonTest`.
  """
  use ExUnit.Case, async: true

  alias Kazi.CLI.Usage

  describe "render/1 — present fields" do
    test "renders every reported component, in the canonical envelope order" do
      usage = %{
        input_tokens: 1500,
        cached_input_tokens: 18_000,
        cache_write_tokens: 0,
        output_tokens: 2400,
        reasoning_tokens: 120,
        cost_usd: 0.0123
      }

      rendered = Usage.render(usage)

      assert rendered == usage
      # Order is the declared field order (stable for a diffable contract).
      assert Map.keys(rendered) |> Enum.sort() == Enum.sort(Usage.fields())
    end

    test "renders a partial envelope — only the reported subset, others absent" do
      # A Claude run that reports dollars + the fresh/cached split but no reasoning.
      rendered = Usage.render(%{input_tokens: 100, cached_input_tokens: 5000, cost_usd: 0.01})

      assert rendered == %{input_tokens: 100, cached_input_tokens: 5000, cost_usd: 0.01}
      refute Map.has_key?(rendered, :reasoning_tokens)
      refute Map.has_key?(rendered, :output_tokens)
      refute Map.has_key?(rendered, :cache_write_tokens)
    end

    test "a zero value is reported (a real zero ≠ unreported)" do
      rendered = Usage.render(%{cache_write_tokens: 0})

      assert rendered == %{cache_write_tokens: 0}
    end

    test "accepts string keys (decoded JSON round-trips back through the renderer)" do
      rendered = Usage.render(%{"input_tokens" => 7, "cost_usd" => 0.5})

      assert rendered == %{input_tokens: 7, cost_usd: 0.5}
    end
  end

  describe "render/1 — absent fields are omitted (not zero-filled)" do
    test "an empty accumulator renders the empty map" do
      assert Usage.render(%{}) == %{}
    end

    test "an explicit nil component is omitted, never coerced to zero" do
      rendered = Usage.render(%{input_tokens: 42, output_tokens: nil, cost_usd: nil})

      assert rendered == %{input_tokens: 42}
      refute Map.has_key?(rendered, :output_tokens)
      refute Map.has_key?(rendered, :cost_usd)
    end

    test "unknown keys are ignored — only the envelope fields are surfaced" do
      assert Usage.render(%{total_tokens: 999, foo: "bar"}) == %{}
    end
  end
end
