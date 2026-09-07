defmodule Kazi.Economy.UsageProvenanceTest do
  use ExUnit.Case, async: true
  alias Kazi.Economy.UsageProvenance, as: Provenance

  test "failed launches and missing reports stay in the coverage denominator" do
    first =
      {:ok,
       %{
         exit: 1,
         usage: %{input_tokens: 10, output_tokens: 20},
         usage_source: :model_usage,
         usage_fidelity: :partial,
         cost: %{tokens: 30},
         cost_usd: 2.017401,
         cost_basis: :harness_reported_unverified
       }}

    p = Provenance.new() |> Provenance.record(first) |> Provenance.record({:error, :timeout})
    assert p["dispatches"] == 2
    assert p["usage_reports"] == 1
    assert p["usage_coverage"] == "partial"
    assert p["cost_reports"] == 1
    assert p["cost_coverage"] == "partial"
    assert p["reported_cost_usd"] == 2.017401
    assert p["actual_cost_usd"] == nil
    assert p["cost_basis"] == "harness_reported_unverified"
    assert p["usage_sources"] == %{"model_usage" => 1, "unknown" => 1}
    assert p["field_reports"]["output_tokens"] == 1
    assert p["scope"] == "cumulative_run"
  end

  test "mixed estimates stay separate and known zero survives" do
    p =
      Provenance.new()
      |> Provenance.record({:ok, %{cost_usd: 0, cost_basis: :harness_reported_unverified}})
      |> Provenance.record(
        {:ok, %{cost_usd: 0.02, cost_basis: :price_map_estimate, price_map_as_of: "2026-06-30"}}
      )

    assert p["reported_cost_usd"] == 0
    assert p["estimated_cost_usd"] == 0.02
    assert p["cost_basis"] == "mixed_estimates"
    assert p["cost_coverage"] == "complete"
    assert p["actual_cost_usd"] == nil
    assert p["price_map_dates"] == %{"2026-06-30" => 1}
  end

  test "invalid values are unknown; absent historical snapshots are never complete" do
    p =
      Provenance.new()
      |> Provenance.record(
        {:ok, %{usage: %{input_tokens: -1, output_tokens: "20"}, cost_usd: -1}}
      )

    assert p["usage_reports"] == 0
    assert p["cost_reports"] == 0
    assert p["cost_basis"] == "unknown"
    assert Provenance.render(nil)["usage_coverage"] == "unknown"
    assert Provenance.render(nil)["dispatches"] == nil
  end

  test "persisted string keys preserve counters when recording another report" do
    p =
      Provenance.new()
      |> Provenance.record({:ok, %{usage: %{input_tokens: 1}}})
      |> Jason.encode!()
      |> Jason.decode!()

    p = Provenance.record(p, {:ok, %{usage: %{input_tokens: 2}, usage_source: :top_level_usage}})
    assert p["field_reports"]["input_tokens"] == 2
    assert p["dispatches"] == 2
  end
end
