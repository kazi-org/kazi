defmodule Kazi.Providers.MetricsTest do
  @moduledoc """
  T32.10 (ADR-0043): the live RED/SLO metrics provider. Hermetic — the Prometheus
  HTTP fetch is exercised through the provider's injectable `:fetcher` seam (a
  goal-file cannot express a function; production uses the `:query_url` HTTP path),
  so the windowed-quantile + burn-rate COMPUTATION is tested against fixtures with
  no real Prometheus.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Metrics

  # A Prometheus instant-query "scalar" response carrying one number.
  defp scalar(value) do
    {:ok, %{"status" => "success", "data" => %{"resultType" => "scalar", "result" => [0, value]}}}
  end

  # A Prometheus "vector" of histogram `_bucket` series keyed by `le`.
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

  test "implements the PredicateProvider behaviour" do
    assert Kazi.PredicateProvider in (Metrics.module_info(:attributes)[:behaviour] || [])
  end

  # --- not applicable --------------------------------------------------------

  describe "no metrics endpoint" do
    test "absent query_url and fetcher -> :unknown (not applicable), never a false pass" do
      result = evaluate(%{query: "up", pass_when: "== 1"})

      assert %PredicateResult{status: :unknown, evidence: evidence} = result
      assert evidence.reason == :no_metrics_endpoint
      # :unknown carries no claim, so it is NOT a pass.
      refute PredicateResult.passed?(result)
    end
  end

  # --- scalar mode -----------------------------------------------------------

  describe "scalar mode" do
    test "an error-rate under the threshold -> :pass with score = observed" do
      result =
        evaluate(%{
          query:
            "sum(rate(http_requests_total{code=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))",
          pass_when: "< 0.01",
          window: "5m",
          fetcher: fn _q -> scalar("0.002") end
        })

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.observed == 0.002
      assert evidence.window == "5m"
      assert result.score == 0.002
      # error-rate is lower-better by default.
      assert result.direction == :lower_better
    end

    test "an error-rate over the threshold -> :fail" do
      result =
        evaluate(%{
          query: "error_rate",
          pass_when: "< 0.01",
          fetcher: fn _q -> scalar("0.05") end
        })

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.observed == 0.05
    end

    test "a single-element vector is read as a scalar" do
      vector =
        {:ok,
         %{
           "status" => "success",
           "data" => %{
             "resultType" => "vector",
             "result" => [%{"metric" => %{}, "value" => [0, "0.5"]}]
           }
         }}

      result = evaluate(%{query: "p95", pass_when: "<= 1.0", fetcher: fn _q -> vector end})
      assert %PredicateResult{status: :pass, evidence: %{observed: 0.5}} = result
    end

    test "a Prometheus error response -> :error, not :fail" do
      result =
        evaluate(%{
          query: "bad{",
          pass_when: "< 1",
          fetcher: fn _q -> {:ok, %{"status" => "error", "error" => "parse error"}} end
        })

      assert %PredicateResult{status: :error, evidence: evidence} = result
      assert match?({:prometheus_error, _}, evidence.reason)
    end

    test "a fetch failure -> :error, not :fail" do
      result =
        evaluate(%{
          query: "up",
          pass_when: "== 1",
          fetcher: fn _q -> {:error, {:request_failed, :timeout}} end
        })

      assert %PredicateResult{status: :error} = result
    end
  end

  # --- quantile mode (kazi computes histogram_quantile) ----------------------

  describe "quantile mode" do
    test "computes a windowed p95 from the bucket vector and gates on it -> :pass" do
      # Cumulative bucket rates over W: the 0.95 quantile of this distribution
      # falls in the (0.5, 1.0] bucket and interpolates under the 1.0s SLO.
      buckets =
        bucket_vector([
          {"0.1", "10"},
          {"0.5", "90"},
          {"1.0", "98"},
          {"+Inf", "100"}
        ])

      result =
        evaluate(%{
          query: "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)",
          quantile: 0.95,
          pass_when: "<= 1.0",
          fetcher: fn _q -> buckets end
        })

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.mode == "quantile"
      assert evidence.quantile == 0.95
      # rank = 0.95 * 100 = 95 falls in the (0.5, 1.0] bucket (cum 90 -> 98):
      # 0.5 + (1.0-0.5) * ((95-90)/(98-90)) = 0.8125
      assert_in_delta evidence.observed, 0.8125, 1.0e-9
      assert result.score == evidence.observed
      assert result.direction == :lower_better
    end

    test "a p95 over a tight SLO -> :fail" do
      buckets =
        bucket_vector([
          {"0.1", "10"},
          {"0.5", "20"},
          {"1.0", "40"},
          {"+Inf", "100"}
        ])

      result =
        evaluate(%{
          query: "buckets",
          quantile: 0.95,
          pass_when: "<= 0.5",
          fetcher: fn _q -> buckets end
        })

      # rank 95 falls in the +Inf bucket (cum 40 -> 100), so the computed quantile
      # is the largest finite bound (1.0), which exceeds the 0.5s SLO.
      assert %PredicateResult{status: :fail, evidence: %{observed: 1.0}} = result
    end

    test "histogram_quantile/2 matches the Prometheus algorithm (unit)" do
      buckets = [{0.1, 10.0}, {0.5, 90.0}, {1.0, 98.0}, {:inf, 100.0}]
      assert {:ok, value} = Metrics.histogram_quantile(0.5, buckets)
      # rank = 50 in (0.1, 0.5] bucket (cum 10 -> 90): 0.1 + 0.4*((50-10)/80) = 0.3
      assert_in_delta value, 0.3, 1.0e-9
    end

    test "histogram_quantile/2 rejects a vector with no +Inf bucket" do
      assert {:error, :missing_inf_bucket} =
               Metrics.histogram_quantile(0.5, [{0.1, 1.0}, {0.5, 2.0}])
    end

    test "histogram_quantile/2 rejects an empty-observation histogram" do
      assert {:error, :no_observations} =
               Metrics.histogram_quantile(0.5, [{0.1, 0.0}, {:inf, 0.0}])
    end
  end

  # --- burn-rate mode (multiwindow multi-burn-rate SLO gate) -----------------

  describe "burn-rate mode" do
    # Burn-rate config with a fetcher that resolves the long/short queries to the
    # given burn rates, so both windows are exercised within one evaluation.
    defp burn_predicate(long_burn, short_burn, threshold) do
      by_query = %{"long_q" => long_burn, "short_q" => short_burn}

      %{
        burn_rate: %{"long" => "long_q", "short" => "short_q", "threshold" => threshold},
        fetcher: fn query -> scalar(Float.to_string(Map.fetch!(by_query, query))) end
      }
    end

    test "fires (:fail) only when BOTH windows breach the threshold" do
      result = evaluate(burn_predicate(20.0, 18.0, 14.4))

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.fires == true
      assert evidence.long_window.breach == true
      assert evidence.short_window.breach == true
      assert result.direction == :lower_better
    end

    test "long window breaches but short does not -> :pass (no alert)" do
      result = evaluate(burn_predicate(20.0, 2.0, 14.4))

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.fires == false
      assert evidence.long_window.breach == true
      assert evidence.short_window.breach == false
    end

    test "short window breaches but long does not -> :pass (no alert)" do
      result = evaluate(burn_predicate(2.0, 20.0, 14.4))

      assert %PredicateResult{status: :pass, evidence: %{fires: false}} = result
    end

    test "neither window breaches -> :pass" do
      result = evaluate(burn_predicate(1.0, 0.5, 14.4))

      assert %PredicateResult{status: :pass, evidence: %{fires: false}} = result
    end
  end

  # --- direction override ----------------------------------------------------

  test "direction can be overridden to higher_better (e.g. an availability ratio)" do
    result =
      evaluate(%{
        query: "availability",
        pass_when: ">= 0.999",
        direction: "higher_better",
        fetcher: fn _q -> scalar("0.9995") end
      })

    assert %PredicateResult{status: :pass, direction: :higher_better} = result
  end

  test "unsupported predicate kind -> :error" do
    assert %PredicateResult{status: :error} = Metrics.evaluate(Predicate.new(:x, :tests), %{})
  end
end
