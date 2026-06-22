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

  @impl true
  def evaluate(%Predicate{kind: :http_probe, config: config}, _context) do
    case fetch_url(config) do
      {:ok, url} ->
        request(url, config)

      :error ->
        PredicateResult.error(%{reason: :missing_url})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: :unsupported_kind, kind: kind})
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

  defp body_matches?(body, expected, :exact), do: body == expected
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
