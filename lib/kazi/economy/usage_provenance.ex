defmodule Kazi.Economy.UsageProvenance do
  @moduledoc "Cumulative coverage and unverified cost provenance, recorded once per harness launch."

  @token_fields ~w(input_tokens cached_input_tokens cache_write_tokens output_tokens reasoning_tokens)a
  @cost_bases ~w(harness_reported_unverified price_map_estimate)

  def new do
    %{
      "scope" => "cumulative_run",
      "dispatches" => 0,
      "usage_reports" => 0,
      "cost_reports" => 0,
      "usage_coverage" => "not_applicable",
      "cost_coverage" => "not_applicable",
      "usage_sources" => %{},
      "usage_fidelities" => %{},
      "field_reports" => %{},
      "cost_bases" => %{},
      "cost_fidelities" => %{},
      "price_map_dates" => %{},
      "cost_basis" => "unknown",
      "currency" => nil,
      "reported_cost_usd" => nil,
      "estimated_cost_usd" => nil,
      "actual_cost_usd" => nil
    }
  end

  def record(provenance, result) do
    result = result_map(result)
    usage = fetch(result, :usage) || %{}
    fields = Enum.filter(@token_fields, fn key -> valid_tokens?(fetch(usage, key)) end)
    reported? = fields != [] or valid_tokens?(fetch(fetch(result, :cost) || %{}, :tokens))
    source = if reported?, do: label(fetch(result, :usage_source)), else: "unknown"
    fidelity = if reported?, do: label(fetch(result, :usage_fidelity)), else: "unknown"

    p =
      provenance
      |> increment("dispatches")
      |> maybe_increment("usage_reports", reported?)
      |> increment_category("usage_sources", source)
      |> increment_category("usage_fidelities", fidelity)

    p = Enum.reduce(fields, p, &increment_category(&2, "field_reports", to_string(&1)))
    p = record_cost(p, result)

    p
    |> Map.put("usage_coverage", coverage(p["usage_reports"], p["dispatches"]))
    |> Map.put("cost_coverage", coverage(p["cost_reports"], p["dispatches"]))
  end

  def render(nil),
    do: %{
      "scope" => "unknown",
      "dispatches" => nil,
      "usage_coverage" => "unknown",
      "cost_coverage" => "unknown",
      "cost_basis" => "unknown",
      "actual_cost_usd" => nil
    }

  def render(provenance) when is_map(provenance), do: provenance

  def aggregate(snapshots) do
    known = Enum.filter(snapshots, &(is_map(&1) and &1["scope"] == "cumulative_run"))

    %{
      "scope" => "run_history",
      "runs_with_provenance" => length(known),
      "unknown_historical_runs" => length(snapshots) - length(known),
      "known_dispatches" => Enum.sum(Enum.map(known, &(&1["dispatches"] || 0))),
      "runs_by_cost_basis" =>
        Enum.frequencies_by(snapshots, fn p ->
          if is_map(p), do: p["cost_basis"] || "unknown", else: "unknown"
        end),
      "runs_by_usage_coverage" =>
        Enum.frequencies_by(snapshots, fn p ->
          if is_map(p), do: p["usage_coverage"] || "unknown", else: "unknown"
        end),
      "known_reported_cost_usd" => sum_known(known, "reported_cost_usd"),
      "known_estimated_cost_usd" => sum_known(known, "estimated_cost_usd"),
      "actual_cost_usd" => nil
    }
  end

  defp sum_known(snapshots, key) do
    case snapshots |> Enum.map(& &1[key]) |> Enum.filter(&is_number/1) do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  defp record_cost(p, result) do
    case fetch(result, :cost_usd) do
      cost when is_number(cost) and cost >= 0 ->
        basis =
          case label(fetch(result, :cost_basis)) do
            known when known in @cost_bases -> known
            _ -> "harness_reported_unverified"
          end

        field =
          if basis == "price_map_estimate", do: "estimated_cost_usd", else: "reported_cost_usd"

        p =
          p
          |> increment("cost_reports")
          |> increment_category("cost_bases", basis)
          |> increment_category("cost_fidelities", label(fetch(result, :cost_fidelity)))
          |> Map.update!(field, &((&1 || 0) + cost))
          |> Map.put("currency", "USD")

        p =
          case fetch(result, :price_map_as_of) do
            date when is_binary(date) and basis == "price_map_estimate" ->
              increment_category(p, "price_map_dates", date)

            _ ->
              p
          end

        Map.put(
          p,
          "cost_basis",
          if(map_size(p["cost_bases"]) > 1, do: "mixed_estimates", else: basis)
        )

      _ ->
        p
    end
  end

  defp result_map({:ok, result}) when is_map(result), do: result
  defp result_map({:error, result}) when is_map(result), do: result
  defp result_map(_), do: %{}
  defp fetch(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp fetch(_, _), do: nil
  defp valid_tokens?(n), do: is_integer(n) and n >= 0
  defp label(nil), do: "unknown"
  defp label(:none), do: "unknown"
  defp label(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp label(_), do: "unknown"
  defp increment(p, key), do: Map.update!(p, key, &(&1 + 1))
  defp maybe_increment(p, key, true), do: increment(p, key)
  defp maybe_increment(p, _, false), do: p

  defp increment_category(p, key, category),
    do: Map.update!(p, key, &Map.update(&1, category, 1, fn n -> n + 1 end))

  defp coverage(_, 0), do: "not_applicable"
  defp coverage(0, _), do: "none"
  defp coverage(n, n), do: "complete"
  defp coverage(_, _), do: "partial"
end
