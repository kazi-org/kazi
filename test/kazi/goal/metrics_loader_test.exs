defmodule Kazi.Goal.MetricsLoaderTest do
  @moduledoc """
  T32.10 (ADR-0043): the loader maps `provider = "metrics"` to the `:metrics` kind
  and VALIDATES its pass_when/quantile/burn_rate keys, so a mis-declared live gate
  fails loudly at load time rather than silently at dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "metrics"}, predicate_toml)]
    })
  end

  test "a scalar metrics predicate loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :metrics, config: config}]}} =
             load(%{
               "query_url" => "https://metrics.example.com",
               "query" => "error_rate",
               "pass_when" => "< 0.01"
             })

    assert config.query == "error_rate"
  end

  test "a quantile metrics predicate loads" do
    assert {:ok, _} =
             load(%{
               "query_url" => "https://metrics.example.com",
               "query" => "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)",
               "quantile" => 0.95,
               "pass_when" => "<= 0.5"
             })
  end

  test "a burn_rate metrics predicate loads" do
    assert {:ok, _} =
             load(%{
               "query_url" => "https://metrics.example.com",
               "burn_rate" => %{"long" => "burn_1h", "short" => "burn_5m", "threshold" => 14.4}
             })
  end

  test "a metrics predicate with NO endpoint still loads (it degrades to not-applicable)" do
    assert {:ok, _} = load(%{"query" => "up", "pass_when" => "== 1"})
  end

  test "a scalar/quantile metrics predicate without query is a load error" do
    assert {:error, msg} = load(%{"query_url" => "https://m.example.com", "pass_when" => "< 1"})
    assert msg =~ "requires a non-empty string \"query\""
  end

  test "a scalar metrics predicate without pass_when is a load error" do
    assert {:error, msg} = load(%{"query_url" => "https://m.example.com", "query" => "up"})
    assert msg =~ "requires a \"pass_when\" comparison"
  end

  test "a malformed pass_when is a load error" do
    assert {:error, msg} =
             load(%{"query" => "up", "pass_when" => "is one"})

    assert msg =~ "malformed pass_when"
  end

  test "an out-of-range quantile is a load error" do
    assert {:error, msg} =
             load(%{"query" => "buckets", "quantile" => 1.5, "pass_when" => "<= 1"})

    assert msg =~ "must be a number in 0..1"
  end

  test "a burn_rate missing a window query is a load error" do
    assert {:error, msg} =
             load(%{"burn_rate" => %{"long" => "burn_1h", "threshold" => 14.4}})

    assert msg =~ "requires a non-empty string \"short\" query"
  end

  test "a burn_rate with a non-numeric threshold is a load error" do
    assert {:error, msg} =
             load(%{"burn_rate" => %{"long" => "a", "short" => "b", "threshold" => "lots"}})

    assert msg =~ "requires a numeric \"threshold\""
  end

  test "an unknown direction is a load error" do
    assert {:error, msg} =
             load(%{"query" => "up", "pass_when" => "== 1", "direction" => "sideways"})

    assert msg =~ "unknown direction"
  end
end
