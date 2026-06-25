defmodule Kazi.Bench do
  @moduledoc """
  Pure token-capture + report-aggregation core for the multi-iteration token
  benchmark (T19.4, ADR-0010 §"Cache + measure").

  The benchmark answers the question ADR-0010 promised but the single-dispatch
  measurement (devlog 2026-06-24 "token benchmark (T15.9)") could not: on a
  fixture that needs **>= 3 dispatches** to converge, does the kazi orientation
  prefix (T19.1/T19.2) actually pay for itself across iterations? It runs three
  arms over the SAME fixture and compares their per-arm token + cost + iteration
  tables:

    * **arm A — vanilla** `claude -p` (no kazi): one freeform session.
    * **arm B — kazi WITHOUT the prefix** (`orientation_prefix: false`, the
      pre-T19.1 behaviour): kazi drives `claude` but dispatches the evidence-only
      prompt.
    * **arm C — kazi WITH the prefix** (`orientation_prefix: true`, the current
      default; T19.1 stable head + T19.2 stable-prefix discipline): kazi drives
      `claude` with the ranked orientation pack as a cacheable prefix.

  This module is the HERMETIC, side-effect-free part of the harness: it parses a
  recorded `claude --output-format json` envelope into a per-dispatch token
  capture (`parse_capture/1`), and aggregates a list of captures into a per-arm
  total (`arm_summary/2`) and a comparison table (`report/1`, `render_table/1`).
  It NEVER shells out or touches the network — the real 3-arm run that needs a
  live `claude` on PATH lives in `Mix.Tasks.Kazi.Bench` and is executed by a
  maintainer (T19.5). Tests drive these functions with recorded envelopes only.

  ## Token model

  Mirrors `Kazi.Harness.Profiles.Claude.parse/1` and the devlog capture method:
  the `claude --output-format json` envelope carries a `usage` object with
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, and
  `cache_read_input_tokens`, plus a top-level `total_cost_usd`. A capture keeps
  each field separately (so the report can show the cache-read split that the
  cache-hit story turns on) plus the convenience `total` (sum of all four token
  fields, the same total `Profiles.Claude` surfaces).
  """

  @typedoc """
  One dispatch's token + cost capture, parsed from a single
  `claude --output-format json` envelope.

    * `:input`        — `usage.input_tokens` (uncached prompt input).
    * `:output`       — `usage.output_tokens` (generated tokens).
    * `:cache_creation` — `usage.cache_creation_input_tokens` (tokens written to
      the prompt cache this dispatch).
    * `:cache_read`   — `usage.cache_read_input_tokens` (tokens served FROM the
      prompt cache — the lever the stable-prefix story leans on).
    * `:total`        — sum of the four token fields above.
    * `:cost_usd`     — `total_cost_usd` (the harness's own cost figure), or
      `0.0` when the envelope carried none.
  """
  @type capture :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_creation: non_neg_integer(),
          cache_read: non_neg_integer(),
          total: non_neg_integer(),
          cost_usd: float()
        }

  @typedoc """
  A per-arm aggregate over a list of `t:capture/0`: the arm label, its dispatch
  (iteration) count, the summed token fields, and the summed cost.
  """
  @type arm_summary :: %{
          arm: String.t(),
          iterations: non_neg_integer(),
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_creation: non_neg_integer(),
          cache_read: non_neg_integer(),
          total: non_neg_integer(),
          cost_usd: float()
        }

  @token_fields [:input, :output, :cache_creation, :cache_read, :total]

  @typedoc """
  One TIERING arm's roll-up (T19.7, ADR-0033/0035 — the in-family cost proof).

  Where the A/B/C arms above isolate the orientation PREFIX over one model, the
  tiering arms isolate the MODEL choice over one fixture: vanilla-frontier (a
  frontier model does the whole grind) vs static-cheap (a cheap Claude model
  grinds predicates a frontier model authored once) vs escalating (start cheap,
  climb the Haiku→Sonnet→Opus ladder only on a kazi-reported non-progress signal,
  ADR-0035). Each arm folds its captured per-dispatch `claude --output-format
  json` envelopes (the real `$`/tokens) and its terminal `kazi apply --json`
  result (convergence + correctness):

    * `:arm`        — the arm label (`"vanilla-frontier"` / `"static-cheap"` /
      `"escalating"`).
    * `:models`     — the distinct model ids the arm dispatched, in first-seen
      order (one for the static arms; the climbed ladder for an escalating arm).
    * `:dispatches` — the number of captured envelopes (inner-harness calls).
    * `:tokens`     — summed token total across the arm's dispatches.
    * `:cost_usd`   — summed `total_cost_usd` across the arm's dispatches (the real
      provider figure, not a re-priced estimate).
    * `:converged`  — whether the terminal run reached `converged`.
    * `:correct`    — whether the run converged AND every predicate verdict is
      `pass` (the predicate IS the machine-checkable correctness oracle, so a
      cheaper-but-WRONG result is visible, never hidden as a false done).
  """
  @type tiering_arm :: %{
          arm: String.t(),
          models: [String.t()],
          dispatches: non_neg_integer(),
          tokens: non_neg_integer(),
          cost_usd: float(),
          converged: boolean(),
          correct: boolean()
        }

  @typedoc """
  One TIER × SURFACE arm's roll-up (T36.5, ADR-0047 — the inner-harness
  context-budget proof). Where the T19.7 tiering arms isolate the MODEL choice,
  these arms isolate the two ADR-0047 knobs kazi owns over one model + fixture:
  the context TIER (`Kazi.Context.Tier` 0–4: how MUCH context a dispatch
  assembles) and the tool-SURFACE (`Kazi.Harness.DispatchSurface` `:minimal` vs
  `:ambient`: how many tool schemas the harness loads). Each arm folds its captured
  per-dispatch `claude --output-format json` envelopes (the real `$`/tokens) and
  its terminal `kazi apply --json` result (convergence + correctness + stuck), and
  derives the headline `cost_usd / converged-predicate` the operator optimizes:

    * `:arm`        — the arm label (`"t<tier>-<on|off>"`, e.g. `"t1-on"`).
    * `:tier`       — the context tier `0..4` parsed from the label (`nil` if the
      label does not encode one).
    * `:surface`    — `:minimal` (surface ON, the T36.2 default) or `:ambient`
      (surface OFF) parsed from the label; `nil` if unencoded.
    * `:dispatches` — the number of captured envelopes (inner-harness calls).
    * `:tokens`     — summed token total across the arm's dispatches.
    * `:cost_usd`   — summed `total_cost_usd` across the arm's dispatches (the real
      provider figure, never a re-priced estimate).
    * `:converged`  — whether the terminal run reached `converged`.
    * `:correct`    — whether the run converged AND every predicate verdict is
      `pass` (the predicate IS the correctness oracle, so a cheaper-but-WRONG
      result is visible, never a false done).
    * `:converged_predicates` — the count of `pass` verdicts (the KPI denominator).
    * `:cost_per_converged_predicate` — `cost_usd / converged_predicates`, or `nil`
      when there is no converged predicate to divide by (honest-unknown, no
      fabricated "cost per zero", mirroring `Kazi.Economy.KPIs`).
    * `:stuck`      — whether the terminal status was `stuck` (the stuck-rate input).
  """
  @type tier_surface_arm :: %{
          arm: String.t(),
          tier: 0..4 | nil,
          surface: :minimal | :ambient | nil,
          dispatches: non_neg_integer(),
          tokens: non_neg_integer(),
          cost_usd: float(),
          converged: boolean(),
          correct: boolean(),
          converged_predicates: non_neg_integer(),
          cost_per_converged_predicate: float() | nil,
          stuck: boolean()
        }

  @doc """
  Parses a single `claude --output-format json` envelope (a decoded map OR the
  raw JSON string) into a per-dispatch `t:capture/0`.

  Total and best-effort: a string that is not a JSON object, or a map with no
  `usage`, yields a zeroed capture — so a surprising/partial harness output never
  crashes the aggregation, exactly as `Kazi.Harness.Profiles.Claude.parse/1`
  degrades. Negative or non-integer token fields are treated as `0`.
  """
  @spec parse_capture(String.t() | map()) :: capture()
  def parse_capture(envelope) when is_binary(envelope) do
    case Jason.decode(envelope) do
      {:ok, %{} = decoded} -> parse_capture(decoded)
      _ -> zero_capture()
    end
  end

  def parse_capture(%{} = envelope) do
    usage = Map.get(envelope, "usage", %{})
    usage = if is_map(usage), do: usage, else: %{}

    input = nonneg_int(usage, "input_tokens")
    output = nonneg_int(usage, "output_tokens")
    cache_creation = nonneg_int(usage, "cache_creation_input_tokens")
    cache_read = nonneg_int(usage, "cache_read_input_tokens")

    %{
      input: input,
      output: output,
      cache_creation: cache_creation,
      cache_read: cache_read,
      total: input + output + cache_creation + cache_read,
      cost_usd: cost_usd(envelope)
    }
  end

  @doc """
  Aggregates a list of per-dispatch captures into a per-arm `t:arm_summary/0`.

  `:iterations` is the number of captures (one per dispatch); the token fields
  and `:cost_usd` are summed across them. An empty list yields a zeroed summary
  with `iterations: 0`, so an arm that produced no dispatch still tables cleanly.
  """
  @spec arm_summary(String.t(), [capture()]) :: arm_summary()
  def arm_summary(arm, captures) when is_binary(arm) and is_list(captures) do
    base = %{arm: arm, iterations: length(captures), cost_usd: 0.0}

    base = Enum.reduce(@token_fields, base, &Map.put(&2, &1, 0))

    Enum.reduce(captures, base, fn capture, acc ->
      acc
      |> add_field(:input, capture)
      |> add_field(:output, capture)
      |> add_field(:cache_creation, capture)
      |> add_field(:cache_read, capture)
      |> add_field(:total, capture)
      |> Map.update!(:cost_usd, &(&1 + capture.cost_usd))
    end)
  end

  @doc """
  Builds the per-arm report from a keyword/map list of `arm_label => captures`.

  Accepts an ordered list of `{arm_label, [capture]}` pairs (order is preserved
  in the report, so A/B/C stay in submission order) and returns the list of
  `t:arm_summary/0`, one per arm. Pure: it only folds the captures already
  parsed by `parse_capture/1`.
  """
  @spec report([{String.t(), [capture()]}]) :: [arm_summary()]
  def report(arms) when is_list(arms) do
    Enum.map(arms, fn {arm, captures} -> arm_summary(arm, captures) end)
  end

  @doc """
  Renders a list of `t:arm_summary/0` as a deterministic, monospace markdown
  table (the per-arm token + cost + iteration table the benchmark emits).

  Columns: Arm | Iterations | Input | Output | Cache-create | Cache-read | Total
  | Cost (USD). Deterministic for a given summary list, so it is safe to assert
  on byte-for-byte in tests.
  """
  @spec render_table([arm_summary()]) :: String.t()
  def render_table(summaries) when is_list(summaries) do
    header =
      "| Arm | Iterations | Input | Output | Cache-create | Cache-read | Total | Cost (USD) |"

    divider = "|---|---|---|---|---|---|---|---|"

    rows =
      Enum.map(summaries, fn s ->
        "| #{s.arm} | #{s.iterations} | #{s.input} | #{s.output} | " <>
          "#{s.cache_creation} | #{s.cache_read} | #{s.total} | #{format_cost(s.cost_usd)} |"
      end)

    Enum.join([header, divider | rows], "\n") <> "\n"
  end

  @doc """
  Fold one TIERING arm (T19.7) from its terminal `kazi apply --json` result and
  its captured per-dispatch `claude --output-format json` envelopes.

  `result` is the decoded `apply --json` object (read for `status` +
  `predicates[].verdict`); `envelopes` is the ordered list of captured envelopes
  (decoded maps or raw JSON strings) — the `$`/tokens/models the arm spent. A
  missing/blank input degrades to a zeroed, non-converged arm rather than
  crashing, exactly as `parse_capture/1` does (a surprising recording never
  breaks the table).
  """
  @spec tiering_arm(String.t(), map(), [map() | String.t()]) :: tiering_arm()
  def tiering_arm(arm, result, envelopes)
      when is_binary(arm) and is_map(result) and is_list(envelopes) do
    captures = Enum.map(envelopes, &parse_capture/1)
    converged = Map.get(result, "status") == "converged"

    %{
      arm: arm,
      models: envelopes |> Enum.map(&parse_model/1) |> Enum.reject(&(&1 == nil)) |> Enum.uniq(),
      dispatches: length(envelopes),
      tokens: Enum.reduce(captures, 0, &(&1.total + &2)),
      cost_usd: Enum.reduce(captures, 0.0, &(&1.cost_usd + &2)),
      converged: converged,
      correct: converged and all_predicates_pass?(result)
    }
  end

  @doc """
  Build the tiering report from an ordered list of `{arm_label, result, envelopes}`
  triples (order preserved, so vanilla/static/escalating stay in submission order).
  """
  @spec tiering_report([{String.t(), map(), [map() | String.t()]}]) :: [tiering_arm()]
  def tiering_report(arms) when is_list(arms) do
    Enum.map(arms, fn {arm, result, envelopes} -> tiering_arm(arm, result, envelopes) end)
  end

  @doc """
  Render a list of `t:tiering_arm/0` as a deterministic markdown table: the
  per-arm $/tokens/iterations + convergence/correctness comparison T19.7 emits.

  Columns: Arm | Model(s) | Dispatches | Tokens | Cost (USD) | Converged |
  Correct. Byte-stable for a given arm list, so a test can assert on it.
  """
  @spec render_tiering_table([tiering_arm()]) :: String.t()
  def render_tiering_table(arms) when is_list(arms) do
    header = "| Arm | Model(s) | Dispatches | Tokens | Cost (USD) | Converged | Correct |"
    divider = "|---|---|---|---|---|---|---|"

    rows =
      Enum.map(arms, fn a ->
        "| #{a.arm} | #{models_label(a.models)} | #{a.dispatches} | #{a.tokens} | " <>
          "#{format_cost(a.cost_usd)} | #{yes_no(a.converged)} | #{yes_no(a.correct)} |"
      end)

    Enum.join([header, divider | rows], "\n") <> "\n"
  end

  @doc """
  Fold one TIER × SURFACE arm (T36.5) from its terminal `kazi apply --json` result
  and its captured per-dispatch `claude --output-format json` envelopes.

  `arm` is the `"t<tier>-<on|off>"` label (its tier + surface are parsed from it);
  `result` is the decoded `apply --json` object (read for `status` +
  `predicates[].verdict`); `envelopes` is the ordered list of captured envelopes
  (decoded maps or raw JSON strings) — the real `$`/tokens the arm spent. Reuses
  `tiering_arm/3` for the `$`/tokens/convergence/correctness fold, then adds the
  tier/surface labels, the converged-predicate count, the headline
  `cost / converged-predicate`, and the stuck flag. A missing/blank input degrades
  to a zeroed, non-converged arm rather than crashing.
  """
  @spec tier_surface_arm(String.t(), map(), [map() | String.t()]) :: tier_surface_arm()
  def tier_surface_arm(arm, result, envelopes)
      when is_binary(arm) and is_map(result) and is_list(envelopes) do
    base = tiering_arm(arm, result, envelopes)
    converged_predicates = count_passing(result)

    base
    |> Map.drop([:models])
    |> Map.merge(%{
      tier: parse_tier(arm),
      surface: parse_surface(arm),
      converged_predicates: converged_predicates,
      cost_per_converged_predicate: per_predicate(base.cost_usd, converged_predicates),
      stuck: Map.get(result, "status") == "stuck"
    })
  end

  @doc """
  Build the tier × surface report from an ordered list of
  `{arm_label, result, envelopes}` triples (order preserved).
  """
  @spec tier_surface_report([{String.t(), map(), [map() | String.t()]}]) :: [tier_surface_arm()]
  def tier_surface_report(arms) when is_list(arms) do
    Enum.map(arms, fn {arm, result, envelopes} -> tier_surface_arm(arm, result, envelopes) end)
  end

  @doc """
  Render a list of `t:tier_surface_arm/0` as a deterministic markdown table: the
  per-arm tier/surface comparison on `$`/tokens + cost/converged-predicate +
  convergence/correctness + stuck the T36.5 benchmark emits.

  Columns: Arm | Tier | Surface | Dispatches | Tokens | Cost (USD) |
  Cost/conv-pred | Converged | Correct | Stuck. An unavailable cost/conv-pred
  prints `n/a` (never `0`). Byte-stable for a given arm list, so a test can assert
  on it.
  """
  @spec render_tier_surface_table([tier_surface_arm()]) :: String.t()
  def render_tier_surface_table(arms) when is_list(arms) do
    header =
      "| Arm | Tier | Surface | Dispatches | Tokens | Cost (USD) | " <>
        "Cost/conv-pred | Converged | Correct | Stuck |"

    divider = "|---|---|---|---|---|---|---|---|---|---|"

    rows =
      Enum.map(arms, fn a ->
        "| #{a.arm} | #{tier_label(a.tier)} | #{surface_label(a.surface)} | " <>
          "#{a.dispatches} | #{a.tokens} | #{format_cost(a.cost_usd)} | " <>
          "#{format_per_predicate(a.cost_per_converged_predicate)} | " <>
          "#{yes_no(a.converged)} | #{yes_no(a.correct)} | #{yes_no(a.stuck)} |"
      end)

    Enum.join([header, divider | rows], "\n") <> "\n"
  end

  # --- helpers ---------------------------------------------------------------

  # Parse the context tier `0..4` from a `"t<tier>-<on|off>"` arm label; `nil`
  # when the label encodes no `t<digit>` prefix.
  @spec parse_tier(String.t()) :: 0..4 | nil
  defp parse_tier(arm) do
    case Regex.run(~r/^t(\d+)/, arm) do
      [_, digits] ->
        case Integer.parse(digits) do
          {n, ""} when n in 0..4 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Parse the tool-surface from a `"…-on"` / `"…-off"` arm label: `on` ⇒ the
  # `:minimal` default surface, `off` ⇒ the `:ambient` surface; `nil` if unencoded.
  @spec parse_surface(String.t()) :: :minimal | :ambient | nil
  defp parse_surface(arm) do
    cond do
      String.ends_with?(arm, "-on") -> :minimal
      String.ends_with?(arm, "-off") -> :ambient
      true -> nil
    end
  end

  # Count the `pass` verdicts in a recorded `predicates[]` array (the
  # converged-predicate denominator). `0` for an absent/empty/non-list value.
  @spec count_passing(map()) :: non_neg_integer()
  defp count_passing(result) do
    case Map.get(result, "predicates") do
      preds when is_list(preds) -> Enum.count(preds, &(Map.get(&1, "verdict") == "pass"))
      _ -> 0
    end
  end

  # cost / converged-predicates: `nil` when there is no converged predicate to
  # divide by (no fabricated "cost per zero"), else the real ratio.
  @spec per_predicate(float(), non_neg_integer()) :: float() | nil
  defp per_predicate(_cost, 0), do: nil
  defp per_predicate(cost, denom) when is_number(cost) and denom > 0, do: cost / denom

  defp tier_label(nil), do: "—"
  defp tier_label(tier), do: Integer.to_string(tier)

  defp surface_label(:minimal), do: "on"
  defp surface_label(:ambient), do: "off"
  defp surface_label(nil), do: "—"

  defp format_per_predicate(nil), do: "n/a"

  defp format_per_predicate(cost) when is_float(cost),
    do: :erlang.float_to_binary(cost, decimals: 4)

  # Whether every recorded predicate verdict is `pass` (the correctness oracle).
  # An absent/empty predicate list is NOT correct (nothing proven passed).
  defp all_predicates_pass?(result) do
    case Map.get(result, "predicates") do
      [_ | _] = preds -> Enum.all?(preds, &(Map.get(&1, "verdict") == "pass"))
      _ -> false
    end
  end

  # Extract the dispatch's model id from a captured `claude --output-format json`
  # envelope: the `modelUsage` object is keyed by model id; fall back to `nil`
  # (unknown) when the envelope carried none.
  @spec parse_model(map() | String.t()) :: String.t() | nil
  defp parse_model(envelope) when is_binary(envelope) do
    case Jason.decode(envelope) do
      {:ok, %{} = decoded} -> parse_model(decoded)
      _ -> nil
    end
  end

  defp parse_model(%{"modelUsage" => usage}) when is_map(usage) do
    usage |> Map.keys() |> List.first()
  end

  defp parse_model(_envelope), do: nil

  defp models_label([]), do: "—"
  defp models_label(models), do: Enum.join(models, " → ")

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp zero_capture do
    %{
      input: 0,
      output: 0,
      cache_creation: 0,
      cache_read: 0,
      total: 0,
      cost_usd: 0.0
    }
  end

  defp add_field(acc, field, capture),
    do: Map.update!(acc, field, &(&1 + Map.fetch!(capture, field)))

  @spec nonneg_int(map(), String.t()) :: non_neg_integer()
  defp nonneg_int(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  @spec cost_usd(map()) :: float()
  defp cost_usd(%{"total_cost_usd" => cost}) when is_number(cost), do: cost / 1.0
  defp cost_usd(_envelope), do: 0.0

  @spec format_cost(float()) :: String.t()
  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 4)
end
