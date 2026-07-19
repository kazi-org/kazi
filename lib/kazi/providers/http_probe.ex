defmodule Kazi.Providers.HttpProbe do
  @moduledoc """
  The live probe predicate provider (T0.5b): requests a URL and asserts on the
  response (ADR-0002).

  This is the provider behind the `:http_probe` predicate kind. It performs a
  real HTTP request and maps the response to a `Kazi.PredicateResult`:

    * `:pass`  — every configured assertion holds (status and/or body).
    * `:fail`  — the request succeeded but an assertion does not hold. This is
      real work for a fixer agent (the service answered, just not correctly).
    * `:error` — the request itself could not complete (connection refused, DNS
      failure, timeout) or the config is malformed. Per ADR-0002 this is *not*
      failing work for the agent — conflating it with `:fail` would dispatch an
      agent against an infra problem.

  It is the live predicate used to verify a deployed service — e.g. asserting the
  Wave-2 fixture's `GET /healthz` returns `200` with body `ok`.

  ## Sustained health (T32.10, ADR-0043)

  A single `200` is a weak signal — a service can answer one probe and then fall
  over. With `:samples > 1` the provider takes N **consecutive** samples and only
  passes when ALL of them are healthy (the Kubernetes `failureThreshold` model,
  not a single 200). The first sample that does not hold breaks the run, so a lone
  transient `200` among failures never passes. This is the bake-window discipline
  in code: never converge on a single sample (see `docs/live-providers.md`).

  Sustained results carry envelope-v2 grading (ADR-0041): `score` is the count of
  healthy samples observed and `direction` is `:higher_better`, so the controller
  reads "3 of 5 healthy → 4 of 5 healthy" as progress without probe-specific
  knowledge. A single-sample probe (`:samples` unset or `1`) is byte-identical to
  the pre-T32.10 provider: no score, the same one-request evidence shape.

  ## Config

  Read from `Kazi.Predicate.config`:

    * `:url`           — required. The URL to request (string).
    * `:method`        — optional. `:get` (default) or any atom/string method.
    * `:expect_status` — optional. Integer the response status must equal.
    * `:expect_body`   — optional. Substring the body must contain (default), or
      an exact match when `:body_match` is `:exact`.
    * `:body_match`    — optional. `:contains` (default) or `:exact`.
    * `:headers`       — optional. List of `{name, value}` request headers.
    * `:timeout_ms`    — optional. Request timeout in milliseconds (default 5000).
    * `:samples`       — optional. Number of CONSECUTIVE healthy samples required
      (default `1`). With `> 1` the probe passes only when all N samples hold.
    * `:interval_ms`   — optional. Delay between samples in milliseconds (default
      `0`). Only meaningful with `:samples > 1`.

  At least one of `:expect_status` / `:expect_body` should be given; with neither,
  any completed request passes (the probe only proves reachability).

  ## Evidence

  Evidence always carries enough to justify the status and seed a fixer:
  `:url`, `:method`, and — when the request completed — `:http_status` and a
  truncated `:body`. On a request error it carries `:reason`.

  Uses stdlib `:httpc` (from `:inets`); `:inets` and `:ssl` are declared in
  `mix.exs` `extra_applications` so they are started with the app.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  # Bodies can be large; evidence must stay seed-sized, not a full page dump.
  @body_limit 2_000
  @default_timeout_ms 5_000
  @default_samples 1
  @default_interval_ms 0

  @impl true
  def evaluate(%Predicate{kind: :http_probe, config: config}, _context) do
    case fetch_url(config) do
      {:ok, url} ->
        probe(url, config)

      :error ->
        PredicateResult.error(%{reason: :missing_url})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: :unsupported_kind, kind: kind})
  end

  # A single-sample probe is byte-identical to the pre-T32.10 provider; only when
  # `:samples > 1` do we enter the sustained-health path (T32.10).
  defp probe(url, config) do
    case samples(config) do
      n when n <= 1 -> request(url, config)
      n -> sustained(url, config, n)
    end
  end

  defp fetch_url(config) do
    case Map.get(config, :url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> :error
    end
  end

  defp request(url, config) do
    method = method(config)
    headers = headers(config)
    timeout = Map.get(config, :timeout_ms, @default_timeout_ms)
    http_opts = [timeout: timeout, connect_timeout: timeout]

    request = {String.to_charlist(url), headers}

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_http_version, status, _reason}, _resp_headers, body}} ->
        evaluate_response(url, method, status, body, config)

      {:error, reason} ->
        # Could not complete the request: infra problem, not failing work.
        PredicateResult.error(%{
          url: url,
          method: method,
          reason: inspect_reason(reason)
        })
    end
  end

  defp evaluate_response(url, method, status, body, config) do
    body_string = to_string(body)

    evidence = %{
      url: url,
      method: method,
      http_status: status,
      body: truncate(body_string)
    }

    failures =
      []
      |> check_status(status, config)
      |> check_body(body_string, config)

    if failures == [] do
      PredicateResult.pass(evidence)
    else
      PredicateResult.fail(Map.put(evidence, :assertion_failures, Enum.reverse(failures)))
    end
  end

  # ===========================================================================
  # Sustained health — N consecutive healthy samples (T32.10, ADR-0043)
  # ===========================================================================

  # Take up to N samples sequentially; the run stops at the first sample that is
  # not :pass (a broken streak can never reach N consecutive, and an :error sample
  # is infra). The verdict is then summarized over the samples actually taken.
  defp sustained(url, config, samples) do
    interval = interval_ms(config)

    results = collect_samples(url, config, samples, interval, [])
    summarize(url, samples, results)
  end

  defp collect_samples(url, config, remaining, interval, acc) do
    result = request(url, config)
    acc = [result | acc]

    cond do
      # A non-pass (a failing assertion or an infra :error) breaks the consecutive
      # run — no point taking the rest.
      result.status != :pass -> Enum.reverse(acc)
      remaining <= 1 -> Enum.reverse(acc)
      true -> wait_then_sample(url, config, remaining, interval, acc)
    end
  end

  defp wait_then_sample(url, config, remaining, interval, acc) do
    if interval > 0, do: Process.sleep(interval)
    collect_samples(url, config, remaining - 1, interval, acc)
  end

  # Map the taken samples to one verdict: any :error sample is infra (:error);
  # all-N healthy is :pass; otherwise a real :fail. The score is the healthy count
  # (higher-better), the dense gradient the controller reads as progress (ADR-0041).
  defp summarize(url, samples, results) do
    healthy = Enum.count(results, &(&1.status == :pass))

    evidence = %{
      url: url,
      samples_required: samples,
      healthy_count: healthy,
      samples: Enum.map(results, &sample_summary/1)
    }

    cond do
      errored = Enum.find(results, &(&1.status == :error)) ->
        PredicateResult.error(Map.put(evidence, :reason, errored.evidence[:reason]))

      healthy == samples ->
        PredicateResult.new(:pass, evidence, score: healthy * 1.0, direction: :higher_better)

      true ->
        failed = Enum.find(results, &(&1.status == :fail))

        evidence
        |> Map.put(:assertion_failures, failed.evidence[:assertion_failures])
        |> then(&PredicateResult.new(:fail, &1, score: healthy * 1.0, direction: :higher_better))
    end
  end

  # A seed-sized per-sample record: the status and (when the request completed)
  # the HTTP status. Enough to see WHICH sample broke the streak.
  defp sample_summary(%PredicateResult{status: status, evidence: evidence}) do
    %{status: status, http_status: Map.get(evidence, :http_status)}
  end

  defp samples(config) do
    case Map.get(config, :samples, @default_samples) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_samples
    end
  end

  defp interval_ms(config) do
    case Map.get(config, :interval_ms, @default_interval_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_interval_ms
    end
  end

  defp check_status(failures, status, config) do
    case Map.get(config, :expect_status) do
      nil ->
        failures

      expected when status == expected ->
        failures

      expected ->
        [%{assertion: :status, expected: expected, actual: status} | failures]
    end
  end

  defp check_body(failures, body, config) do
    case Map.get(config, :expect_body) do
      nil ->
        failures

      expected ->
        if body_matches?(body, expected, Map.get(config, :body_match, :contains)) do
          failures
        else
          [
            %{
              assertion: :body,
              match: Map.get(config, :body_match, :contains),
              expected: expected,
              actual: truncate(body)
            }
            | failures
          ]
        end
    end
  end

  # `:body_match` may arrive as an atom (set programmatically) or as a STRING
  # ("exact"/"contains") when it comes from a TOML goal-file, which cannot express
  # atoms (Kazi.Goal.Loader passes config values verbatim). Both spellings of
  # "exact" mean exact equality; anything else is the default substring-contains.
  # Without this, a goal-file's `body_match = "exact"` silently degraded to
  # contains, and e.g. expecting "ok" falsely passed on "not-ok" (substring).
  defp body_matches?(body, expected, match) when match in [:exact, "exact"],
    do: body == expected

  defp body_matches?(body, expected, _contains), do: String.contains?(body, expected)

  defp method(config) do
    case Map.get(config, :method, :get) do
      method when is_atom(method) -> method
      method when is_binary(method) -> method |> String.downcase() |> String.to_atom()
    end
  end

  defp headers(config) do
    config
    |> Map.get(:headers, [])
    |> Enum.map(fn {name, value} ->
      {String.to_charlist(to_string(name)), String.to_charlist(to_string(value))}
    end)
  end

  defp truncate(body) when byte_size(body) <= @body_limit, do: body

  defp truncate(body) do
    binary_part(body, 0, @body_limit) <> "…(truncated)"
  end

  defp inspect_reason(reason) when is_binary(reason), do: reason
  defp inspect_reason(reason), do: inspect(reason)
end
