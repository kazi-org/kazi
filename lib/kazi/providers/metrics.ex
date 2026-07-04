defmodule Kazi.Providers.Metrics do
  @moduledoc """
  The `:metrics` predicate provider (T32.10, ADR-0043): queries a
  Prometheus-compatible metrics endpoint and gates on a RED/SLO signal — the
  windowed evidence that a deploy is *behaving*, not merely reachable (concept §3,
  §5, ADR-0002).

  Querying metrics supersedes the `prod_log` grep for behavioural verification
  (ADR-0043 decision 3); `prod_log` stays a coarse safety net. A `:metrics`
  predicate's truth is a number computed over a window W — an error-rate, a p95/p99
  latency, an SLO burn-rate — compared to a threshold, not an agent's opinion.

  ## Three evaluation modes

    * **scalar** (default) — the `:query` is a PromQL expression Prometheus
      evaluates to a single number (e.g. `histogram_quantile(0.95, sum(rate(
      http_request_duration_seconds_bucket[5m])) by (le))` for p95, or an
      error-rate ratio). The provider reads the scalar and gates it via
      `:pass_when`.
    * **quantile** — set `:quantile` (a float in `0..1`) and let `:query` return the
      windowed bucket *vector* (`sum(rate(..._bucket[W])) by (le)`); the provider
      itself computes `histogram_quantile/2` over those buckets (the Prometheus
      algorithm, linear interpolation within the rank bucket) and gates the result
      via `:pass_when`. kazi computes the quantile, not just Prometheus.
    * **burn_rate** — set `:burn_rate` to a `{long, short, threshold}` spec for an
      SLO multiwindow multi-burn-rate gate (Google SRE workbook). The gate FIRES
      (`:fail`) only when BOTH the long-window AND the short-window burn rates breach
      the threshold; a single window breaching is noise, not an alert.

  ## Not applicable without an endpoint

  Live metric checks assume an observability stack kazi cannot provision. Absent a
  `:query_url` (and no injected `:fetcher`), the provider returns `:unknown` with
  `reason: :no_metrics_endpoint` — **never `:pass`** (ADR-0043 consequence). An
  `:unknown` carries no claim, so it neither falsely converges nor dispatches a
  fixer; it simply reports that this signal is not applicable in this environment.

  ## The bake-window discipline

  A single sample is a weak signal — never converge on one (see
  `docs/live-providers.md`). A `:metrics` predicate is inherently windowed: it reads
  a `rate(...[W])` over a window W, and a burn-rate gate requires two windows to
  agree. Prefer a relative comparison (error-rate ratio, burn-rate factor) over an
  absolute count.

  ## Config

  Read from `Kazi.Predicate.config`:

    * `:query_url` — the Prometheus HTTP API base, e.g. `"https://metrics.example.com"`.
      The provider GETs `<query_url>/api/v1/query?query=<expr>`. Absent (and no
      `:fetcher`) → `:unknown` (not applicable).
    * `:query`     — the PromQL expression (string). Required for the scalar and
      quantile modes.
    * `:pass_when` — the comparison the observed number must satisfy to `:pass`,
      written `"<op> <number>"` with `<op>` one of `== != < <= > >=` (e.g.
      `"<= 0.5"`, `"< 0.01"`). Required for the scalar and quantile modes.
    * `:quantile`  — a float in `0..1` selecting the quantile mode; the provider
      computes `histogram_quantile(:quantile, buckets)` over the query's bucket
      vector.
    * `:burn_rate` — a map `%{"long" => promql, "short" => promql, "threshold" =>
      number}` selecting the burn-rate mode.
    * `:direction` — `"higher_better"` or `"lower_better"` (default `lower_better`,
      since latency/error-rate/burn-rate all improve going DOWN). Threads the
      envelope-v2 score direction so the controller reads progress (ADR-0041).
    * `:window`    — informational; recorded in evidence so the proof states the
      span it speaks for. kazi does not rewrite the query's own `[W]`.
    * `:timeout_ms`— HTTP request timeout in milliseconds (default 5000).
    * `:fetcher`   — a 1-arity function `query -> {:ok, prometheus_json_map} |
      {:error, reason}` overriding the built-in HTTP fetch. The test seam (a
      goal-file cannot express a function); production uses the `:query_url` fetch.

  ## Evidence

  Every result carries the proof a fixer needs (ADR-0002): the `:query`,
  `:pass_when`, and the `:observed` number on the scalar/quantile path (plus the
  `:quantile` and a bounded `:buckets` sample); the `:threshold` and both windows'
  burn rates + breach flags on the burn-rate path. A fetch/parse failure is an
  `:error` (infra), never a silent pass.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  @default_timeout_ms 5_000
  # Keep the bucket sample seed-sized, not a full histogram dump.
  @bucket_sample_limit 32

  # A pass_when comparison: an operator and a numeric operand (mirrors
  # Kazi.Providers.CustomScript).
  @pass_when_re ~r/^\s*(==|!=|<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$/

  @impl true
  def evaluate(%Predicate{kind: :metrics, config: config}, _context) do
    case resolve_fetcher(config) do
      :not_applicable ->
        PredicateResult.unknown(%{
          reason: :no_metrics_endpoint,
          detail: "no :query_url or :fetcher configured — this live metric is not applicable here"
        })

      {:ok, fetcher} ->
        evaluate_mode(config, fetcher)
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  @doc """
  Computes the φ-quantile (`q` in `0..1`) of a Prometheus-style cumulative
  histogram, ported from Prometheus' `histogram_quantile` (linear interpolation
  within the bucket that contains the rank).

  `buckets` is a list of `{upper_bound, cumulative_count}` where `upper_bound` is a
  float or `:inf` for the `+Inf` bucket. Returns `{:ok, value}` or `{:error,
  reason}` (too few buckets, no `+Inf` bucket, or no observations).

  ## Examples

      iex> Kazi.Providers.Metrics.histogram_quantile(0.5, [{0.1, 1.0}, {0.5, 2.0}, {1.0, 4.0}, {:inf, 4.0}])
      {:ok, 0.5}
  """
  @spec histogram_quantile(number(), [{float() | :inf, number()}]) ::
          {:ok, float()} | {:error, term()}
  def histogram_quantile(q, buckets)
      when is_number(q) and q >= 0 and q <= 1 and is_list(buckets) do
    sorted = Enum.sort_by(buckets, &bound_sort_key/1)

    cond do
      length(sorted) < 2 ->
        {:error, :too_few_buckets}

      not inf_bucket?(List.last(sorted)) ->
        {:error, :missing_inf_bucket}

      true ->
        {_bound, total} = List.last(sorted)

        if total <= 0 do
          {:error, :no_observations}
        else
          {:ok, compute_quantile(q, sorted, total)}
        end
    end
  end

  def histogram_quantile(_q, _buckets), do: {:error, :invalid_quantile}

  # ===========================================================================
  # Fetcher resolution
  # ===========================================================================

  # The injected :fetcher wins (test seam); else a real HTTP fetch against
  # :query_url; else the signal is not applicable in this environment.
  defp resolve_fetcher(config) do
    cond do
      is_function(Map.get(config, :fetcher), 1) ->
        {:ok, Map.get(config, :fetcher)}

      is_binary(Map.get(config, :query_url)) and Map.get(config, :query_url) != "" ->
        {:ok, http_fetcher(Map.get(config, :query_url), timeout_ms(config))}

      true ->
        :not_applicable
    end
  end

  # The production fetch: GET <base>/api/v1/query?query=<expr> and decode the JSON
  # body. A non-2xx status or a request error is infra, surfaced as {:error, _}
  # the caller maps to a provider :error (never a :fail).
  defp http_fetcher(base, timeout) do
    fn query ->
      url = build_query_url(base, query)
      http_opts = [timeout: timeout, connect_timeout: timeout]

      case :httpc.request(:get, {String.to_charlist(url), []}, http_opts, body_format: :binary) do
        {:ok, {{_v, status, _r}, _headers, body}} when status in 200..299 ->
          decode_json(to_string(body))

        {:ok, {{_v, status, _r}, _headers, body}} ->
          {:error, {:http_status, status, truncate(to_string(body))}}

        {:error, reason} ->
          {:error, {:request_failed, inspect(reason)}}
      end
    end
  end

  defp build_query_url(base, query) do
    String.trim_trailing(base, "/") <> "/api/v1/query?query=" <> URI.encode_www_form(query)
  end

  # ===========================================================================
  # Mode dispatch
  # ===========================================================================

  defp evaluate_mode(config, fetcher) do
    cond do
      is_map(Map.get(config, :burn_rate)) -> burn_rate_mode(config, fetcher)
      not is_nil(Map.get(config, :quantile)) -> quantile_mode(config, fetcher)
      true -> scalar_mode(config, fetcher)
    end
  end

  # Scalar instant-query: Prometheus evaluates :query to one number; gate it.
  defp scalar_mode(config, fetcher) do
    with {:ok, query} <- require_string(config, :query),
         {:ok, expr} <- require_string(config, :pass_when),
         {:ok, {op, operand}} <- parse_pass_when(expr),
         {:ok, data} <- fetch(fetcher, query),
         {:ok, value} <- scalar_value(data) do
      evidence = %{mode: "scalar", query: query, pass_when: expr, observed: value}
      decide(compare(value, op, operand), put_window(evidence, config), value, direction(config))
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason})
    end
  end

  # Quantile: :query returns the windowed bucket vector; kazi computes the quantile.
  defp quantile_mode(config, fetcher) do
    with {:ok, q} <- require_quantile(config),
         {:ok, query} <- require_string(config, :query),
         {:ok, expr} <- require_string(config, :pass_when),
         {:ok, {op, operand}} <- parse_pass_when(expr),
         {:ok, data} <- fetch(fetcher, query),
         {:ok, buckets} <- bucket_vector(data),
         {:ok, value} <- histogram_quantile(q, buckets) do
      evidence = %{
        mode: "quantile",
        query: query,
        quantile: q,
        pass_when: expr,
        observed: value,
        buckets: bucket_evidence(buckets)
      }

      decide(compare(value, op, operand), put_window(evidence, config), value, direction(config))
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason})
    end
  end

  # SLO multiwindow multi-burn-rate gate: fire (:fail) iff BOTH windows breach.
  defp burn_rate_mode(config, fetcher) do
    spec = Map.get(config, :burn_rate)

    with {:ok, long_q} <- require_map_string(spec, "long"),
         {:ok, short_q} <- require_map_string(spec, "short"),
         {:ok, threshold} <- require_map_number(spec, "threshold"),
         {:ok, long_data} <- fetch(fetcher, long_q),
         {:ok, long_burn} <- scalar_value(long_data),
         {:ok, short_data} <- fetch(fetcher, short_q),
         {:ok, short_burn} <- scalar_value(short_data) do
      long_breach = long_burn >= threshold
      short_breach = short_burn >= threshold
      fires? = long_breach and short_breach

      evidence = %{
        mode: "burn_rate",
        threshold: threshold,
        long_window: %{query: long_q, burn_rate: long_burn, breach: long_breach},
        short_window: %{query: short_q, burn_rate: short_burn, breach: short_breach},
        fires: fires?
      }

      # The worse (higher) burn is the score; lower is better.
      score = max(long_burn, short_burn) * 1.0
      status = if fires?, do: :fail, else: :pass
      PredicateResult.new(status, evidence, score: score, direction: :lower_better)
    else
      {:error, reason} -> PredicateResult.error(%{reason: reason})
    end
  end

  defp decide(true, evidence, score, direction),
    do: PredicateResult.new(:pass, evidence, score: score * 1.0, direction: direction)

  defp decide(false, evidence, score, direction),
    do: PredicateResult.new(:fail, evidence, score: score * 1.0, direction: direction)

  # ===========================================================================
  # Prometheus response extraction
  # ===========================================================================

  # Validate the Prometheus envelope, returning its inner `data` object. A
  # status:"error" or an unexpected shape is infra (:error), never a :fail.
  defp fetch(fetcher, query) do
    case fetcher.(query) do
      {:ok, %{"status" => "success", "data" => data}} ->
        {:ok, data}

      {:ok, %{"status" => "error"} = err} ->
        {:error, {:prometheus_error, err["error"] || err["errorType"]}}

      {:ok, other} ->
        {:error, {:unexpected_prometheus_response, shape(other)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:fetcher_raised, Exception.message(error)}}
  end

  # A scalar or single-element vector reduced to one number.
  defp scalar_value(%{"resultType" => "scalar", "result" => [_ts, value]}),
    do: parse_number(value)

  defp scalar_value(%{"resultType" => "vector", "result" => [%{"value" => [_ts, value]} | _]}),
    do: parse_number(value)

  defp scalar_value(%{"resultType" => "vector", "result" => []}),
    do: {:error, :empty_vector}

  defp scalar_value(other), do: {:error, {:not_a_scalar, shape(other)}}

  # A vector of `{le, cumulative_rate}` bucket samples for histogram_quantile.
  defp bucket_vector(%{"resultType" => "vector", "result" => results})
       when is_list(results) and results != [] do
    Enum.reduce_while(results, {:ok, []}, fn entry, {:ok, acc} ->
      case bucket_entry(entry) do
        {:ok, bucket} -> {:cont, {:ok, [bucket | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp bucket_vector(_), do: {:error, :not_a_bucket_vector}

  defp bucket_entry(%{"metric" => %{"le" => le}, "value" => [_ts, value]}) do
    with {:ok, count} <- parse_number(value),
         {:ok, bound} <- parse_le(le) do
      {:ok, {bound, count}}
    end
  end

  defp bucket_entry(_), do: {:error, :missing_le_or_value}

  # M4 (deep-review-001): a non-numeric `le` label (a malformed/untrusted
  # Prometheus scrape) maps to `{:error, {:unparseable_le, le}}` -- never a
  # raised `MatchError` -- via the SAFE `parse_number/1`, mirroring the bucket
  # count's own handling above and every other provider's config-error discipline.
  defp parse_le(le) when le in ["+Inf", "Inf", "inf", "+inf"], do: {:ok, :inf}

  defp parse_le(le) when is_binary(le) do
    case parse_number(le) do
      {:ok, number} -> {:ok, number}
      {:error, _} -> {:error, {:unparseable_le, le}}
    end
  end

  defp parse_le(le) when is_number(le), do: {:ok, le * 1.0}

  defp bucket_evidence(buckets) do
    buckets
    |> Enum.sort_by(&bound_sort_key/1)
    |> Enum.take(@bucket_sample_limit)
    |> Enum.map(fn {bound, count} -> %{le: bound_label(bound), cumulative: count} end)
  end

  defp bound_label(:inf), do: "+Inf"
  defp bound_label(b), do: b

  # ===========================================================================
  # histogram_quantile internals
  # ===========================================================================

  # Sort finite bounds ascending, the +Inf bucket last.
  defp bound_sort_key({:inf, _count}), do: {1, 0.0}
  defp bound_sort_key({bound, _count}), do: {0, bound * 1.0}

  defp inf_bucket?({:inf, _count}), do: true
  defp inf_bucket?(_), do: false

  defp compute_quantile(q, sorted, total) do
    rank = q * total
    last_idx = length(sorted) - 1
    idx = Enum.find_index(sorted, fn {_bound, count} -> count >= rank end) || last_idx

    cond do
      # The rank falls in the +Inf bucket: return the largest finite bound.
      idx >= last_idx ->
        {bound, _count} = Enum.at(sorted, last_idx - 1)
        finite(bound)

      true ->
        interpolate(sorted, idx, rank)
    end
  end

  # Linear interpolation within bucket `idx`: bucketStart is the previous bucket's
  # bound (0 for the first), the rank-within-bucket scaled across the bucket width.
  defp interpolate(sorted, idx, rank) do
    {bucket_end, cum} = Enum.at(sorted, idx)

    {bucket_start, cum_prev} =
      if idx == 0, do: {0.0, 0.0}, else: prev_bound(Enum.at(sorted, idx - 1))

    count = cum - cum_prev
    rank_in_bucket = rank - cum_prev
    bend = finite(bucket_end)

    if count <= 0 do
      bucket_start
    else
      bucket_start + (bend - bucket_start) * (rank_in_bucket / count)
    end
  end

  defp prev_bound({bound, cum}), do: {finite(bound), cum}

  defp finite(:inf), do: 0.0
  defp finite(bound), do: bound * 1.0

  # ===========================================================================
  # pass_when + comparison (mirrors Kazi.Providers.CustomScript)
  # ===========================================================================

  defp parse_pass_when(expr) do
    case Regex.run(@pass_when_re, expr) do
      [_, op, num] -> {:ok, {op, parse_number!(num)}}
      _ -> {:error, {:invalid_pass_when, expr}}
    end
  end

  defp compare(value, "==", operand), do: value == operand
  defp compare(value, "!=", operand), do: value != operand
  defp compare(value, "<", operand), do: value < operand
  defp compare(value, "<=", operand), do: value <= operand
  defp compare(value, ">", operand), do: value > operand
  defp compare(value, ">=", operand), do: value >= operand

  # ===========================================================================
  # Config helpers
  # ===========================================================================

  defp require_string(config, key) do
    case Map.get(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config_key, key}}
    end
  end

  defp require_quantile(config) do
    case Map.get(config, :quantile) do
      q when is_number(q) and q >= 0 and q <= 1 -> {:ok, q}
      other -> {:error, {:invalid_quantile, other}}
    end
  end

  defp require_map_string(spec, key) do
    case Map.get(spec, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_burn_rate_key, key}}
    end
  end

  defp require_map_number(spec, key) do
    case Map.get(spec, key) do
      value when is_number(value) -> {:ok, value}
      _ -> {:error, {:missing_burn_rate_key, key}}
    end
  end

  defp direction(config) do
    case Map.get(config, :direction) do
      "higher_better" -> :higher_better
      :higher_better -> :higher_better
      _ -> :lower_better
    end
  end

  defp put_window(evidence, config) do
    case Map.get(config, :window) do
      nil -> evidence
      window -> Map.put(evidence, :window, window)
    end
  end

  defp timeout_ms(config) do
    case Map.get(config, :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end

  defp parse_number(value) when is_number(value), do: {:ok, value * 1.0}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, {:unparseable_number, value}}
    end
  end

  defp parse_number(other), do: {:error, {:unparseable_number, other}}

  defp parse_number!(value) do
    {:ok, number} = parse_number(value)
    number
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json_body}
    end
  end

  # A compact description of an unexpected response, for evidence without dumping it.
  defp shape(%{"resultType" => type}), do: {:result_type, type}
  defp shape(value) when is_map(value), do: {:keys, Map.keys(value)}
  defp shape(value), do: value

  defp truncate(body) when is_binary(body) do
    if String.length(body) > 500, do: String.slice(body, 0, 500) <> "…[truncated]", else: body
  end

  defp truncate(body), do: body
end
