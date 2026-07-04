defmodule Kazi.Providers.MetricsLeLabelTest do
  @moduledoc """
  M4 (deep-review-001): a non-numeric histogram `le` label (a malformed or
  untrusted Prometheus scrape) maps to a predicate `:error` — never a raised
  `MatchError` that crashes the reconcile tick. The bucket COUNT already used the
  safe path; this pins the same discipline for the `le` bound.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Metrics

  defp bucket_vector(pairs) do
    result =
      Enum.map(pairs, fn {le, count} ->
        %{"metric" => %{"le" => le}, "value" => [0, count]}
      end)

    {:ok, %{"status" => "success", "data" => %{"resultType" => "vector", "result" => result}}}
  end

  defp evaluate(config) do
    Metrics.evaluate(Predicate.new(:live, :metrics, config: config), %{})
  end

  test "a non-numeric le label -> :error, not a crash" do
    buckets =
      bucket_vector([
        {"0.1", "10"},
        {"NaN", "90"},
        {"+Inf", "100"}
      ])

    result =
      evaluate(%{
        query: "buckets",
        quantile: 0.95,
        pass_when: "<= 1.0",
        fetcher: fn _q -> buckets end
      })

    assert %PredicateResult{status: :error, evidence: evidence} = result
    assert evidence.reason == {:unparseable_le, "NaN"}
  end

  test "an empty-string le label -> :error, not a crash" do
    buckets = bucket_vector([{"0.1", "10"}, {"", "50"}, {"+Inf", "100"}])

    result =
      evaluate(%{
        query: "buckets",
        quantile: 0.5,
        pass_when: "<= 1.0",
        fetcher: fn _q -> buckets end
      })

    assert %PredicateResult{status: :error, evidence: %{reason: {:unparseable_le, ""}}} = result
  end

  test "a garbage le label like \"0.5x\" -> :error, not a crash" do
    buckets = bucket_vector([{"0.1", "10"}, {"0.5x", "50"}, {"+Inf", "100"}])

    result =
      evaluate(%{
        query: "buckets",
        quantile: 0.5,
        pass_when: "<= 1.0",
        fetcher: fn _q -> buckets end
      })

    assert %PredicateResult{status: :error, evidence: %{reason: {:unparseable_le, "0.5x"}}} =
             result
  end

  test "well-formed le labels still compute the quantile normally" do
    buckets =
      bucket_vector([
        {"0.1", "10"},
        {"0.5", "90"},
        {"1.0", "98"},
        {"+Inf", "100"}
      ])

    result =
      evaluate(%{
        query: "buckets",
        quantile: 0.95,
        pass_when: "<= 1.0",
        fetcher: fn _q -> buckets end
      })

    assert %PredicateResult{status: :pass} = result
  end
end
