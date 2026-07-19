defmodule Kazi.Economy.KPIs do
  @moduledoc """
  Run-end economy KPIs, folded from the per-iteration accounting envelopes
  (T34.6, ADR-0046 §5).

  The per-iteration envelopes added by T34.1 (the run-aggregate `usage`
  token/cost split), T34.2 (the per-profile breakdown + `usage_fidelity`), and
  T34.3 (the per-iteration `context` + `tools` counters) record WHAT a run spent.
  This module turns that record into the KPIs the operator actually optimizes —
  cost and convergence economics, not raw token totals (ADR-0046 §5):

      cost_usd per converged predicate
      wall-clock per converged predicate
      iterations to convergence
      tokens  (the run-aggregate token total, threaded from each dispatch's
               parsed harness usage — non-zero on a real run, T34.8)
      fresh input tokens avoided  (the cached reads a stable prefix served)
      rediscovery tool-calls avoided  (the falling file/search re-discovery)
      stuck rate  (by harness / model / context tier)

  It is PURE: it folds a normalized recorded run (or a list of them) and never
  touches the read-model, the network, or a harness. A caller builds the
  normalized run from a `Kazi.Loop` terminal result + the recorded
  `Kazi.ReadModel.Iteration` rows (`from_iterations/2`); tests drive the fold
  directly with fixtures.

  ## Honest-unknown discipline (ADR-0046 §6)

  A KPI whose inputs were not reported is `nil` — **unavailable**, never `0`. A
  run whose harness reported no `cost_usd` has a `nil` cost-per-converged-predicate
  (not a free run); a run with no per-iteration `tools` stream has a `nil`
  rediscovery-avoided (not zero re-discovery). The renderers OMIT a `nil` field
  (the `--json` economy object) or print `n/a` (the benchmark table), so a
  consumer never mistakes "unreported" for "zero". This mirrors the `context`
  (always populated ⇒ a real `0`) vs `tools` (present only with a signal ⇒ absent
  is unknown) split `Kazi.Loop.Counters` records.

  ## Single run vs. breakdown

    * `compute/1` folds ONE normalized run into its KPI map (`stuck` is a boolean
      for the single run).
    * `aggregate/1` groups a list of runs by `{harness, model, context_tier}` and
      folds each group into a breakdown row — this is where `stuck_rate` becomes a
      fraction and the per-converged-predicate costs are averaged. The E19/E36
      benchmark (T34.7) consumes this to table arms by harness/model/tier.
  """

  @typedoc """
  One normalized recorded iteration the KPIs fold over. All fields optional —
  a pre-T34.3 row carries an empty `context`/`tools`; a run without persistence
  carries no iterations at all (then the per-iteration KPIs are `nil`).

    * `:converged`   — whether this observation satisfied the whole vector.
    * `:context`     — the T34.3 context counters (`orientation_cache`,
      `retrieval_cache`, `orientation_tokens`, `evidence_tokens`,
      `retrieval_tokens`); atom- or string-keyed. Empty `%{}` ⇒ unrecorded.
    * `:tools`       — the T34.3 tool counters (`tool_calls`, `file_reads`,
      `search_calls`, `graph_calls`); atom- or string-keyed. Empty `%{}` ⇒ the
      harness exposed no tool-use stream (absent ≠ zero).
    * `:observed_at` — when the predicates were evaluated (for wall-clock).
  """
  @type iteration :: %{
          optional(:converged) => boolean(),
          optional(:context) => map(),
          optional(:tools) => map(),
          optional(:observed_at) => DateTime.t() | nil
        }

  @typedoc """
  A normalized recorded run. `:status` is required (the terminal verdict);
  everything else degrades to a `nil`/unavailable KPI when unreported.

    * `:harness` / `:model` / `:context_tier` — the breakdown labels (the arm a
      benchmark assigns). `nil` collapses into the catch-all group.
    * `:status` — `"converged"` | `"stuck"` | `"over_budget"` | `"error"`.
    * `:converged_predicates` — how many predicates reached `pass` at run end
      (the KPI denominator). `nil`/`0` ⇒ the per-predicate ratios are unavailable.
    * `:iteration_count` — the loop's observation count (the `iterations` field of
      the terminal result), used when the per-iteration `:iterations` list is
      absent (no persistence).
    * `:usage` — the run-aggregate `usage` envelope (T34.1); `cost_usd` feeds the
      cost KPIs.
    * `:iterations` — the per-iteration list (`from_iterations/2` fills it from the
      read-model rows). May be `[]`.
  """
  @type run :: %{
          optional(:harness) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:context_tier) => String.t() | nil,
          required(:status) => String.t(),
          optional(:converged_predicates) => non_neg_integer() | nil,
          optional(:iteration_count) => non_neg_integer() | nil,
          optional(:usage) => map(),
          optional(:iterations) => [iteration()]
        }

  @typedoc "The KPI map a single run folds to (a `nil` field is unavailable)."
  @type kpis :: %{
          harness: String.t() | nil,
          model: String.t() | nil,
          context_tier: String.t() | nil,
          status: String.t(),
          stuck: boolean(),
          converged_predicates: non_neg_integer() | nil,
          iterations: non_neg_integer(),
          iterations_to_convergence: non_neg_integer() | nil,
          tokens: non_neg_integer() | nil,
          cost_usd: float() | nil,
          wall_clock_s: float() | nil,
          cost_per_converged_predicate: float() | nil,
          wall_clock_per_converged_predicate: float() | nil,
          fresh_input_tokens_avoided: non_neg_integer() | nil,
          rediscovery_tool_calls_avoided: non_neg_integer() | nil
        }

  # ===========================================================================
  # single run
  # ===========================================================================

  @doc """
  Fold ONE normalized `t:run/0` into its `t:kpis/0` map.

  Each derived KPI is `nil` when its inputs were not reported (honest-unknown);
  the convenience fields (`status`, `stuck`, `iterations`) are always present.
  """
  @spec compute(run()) :: kpis()
  def compute(run) when is_map(run) do
    status = Map.get(run, :status) |> to_status()
    iterations = list_iterations(run)
    iteration_count = iteration_count(run, iterations)
    converged_predicates = converged_predicates(run)
    tokens = tokens(run)
    cost_usd = cost_usd(run)
    wall_clock_s = wall_clock_s(iterations)

    %{
      harness: Map.get(run, :harness),
      model: Map.get(run, :model),
      context_tier: Map.get(run, :context_tier),
      status: status,
      stuck: status == "stuck",
      converged_predicates: converged_predicates,
      iterations: iteration_count,
      iterations_to_convergence: iterations_to_convergence(status, iterations, iteration_count),
      tokens: tokens,
      cost_usd: cost_usd,
      wall_clock_s: wall_clock_s,
      cost_per_converged_predicate: ratio(cost_usd, converged_predicates),
      wall_clock_per_converged_predicate: ratio(wall_clock_s, converged_predicates),
      fresh_input_tokens_avoided: fresh_input_tokens_avoided(iterations),
      rediscovery_tool_calls_avoided: rediscovery_tool_calls_avoided(iterations)
    }
  end

  @typedoc """
  Per-category token usage (T60.5/#1070): the SAME components `tokens/1`
  (inside `compute/1`) sums, unsummed. `nil` (never a fabricated 0) per
  category the harness did not report.
  """
  @type token_breakdown :: %{
          input: non_neg_integer() | nil,
          output: non_neg_integer() | nil,
          cached: non_neg_integer() | nil,
          cache_write: non_neg_integer() | nil
        }

  @doc """
  The per-category token breakdown for the human-readable convergence report
  (T60.5/#1070): `input`/`output`/`cached`/`cache_write`, each `nil` when the
  harness did not report that category (honest-unknown, never a fabricated 0).
  Takes a raw `usage` map (the SAME ADR-0046 envelope `tokens/1`'s sum reads,
  atom OR string keyed) directly -- deliberately NOT folded into `t:kpis/0`,
  so the `--json` `economy` object this module also produces stays
  byte-unchanged; this is purely additive human-terminal-output data.
  """
  @spec token_breakdown(map()) :: token_breakdown()
  def token_breakdown(usage) when is_map(usage) do
    %{
      input: usage_field(usage, :input_tokens),
      output: usage_field(usage, :output_tokens),
      cached: usage_field(usage, :cached_input_tokens),
      cache_write: usage_field(usage, :cache_write_tokens)
    }
  end

  def token_breakdown(_not_a_map), do: %{input: nil, output: nil, cached: nil, cache_write: nil}

  @doc """
  Build a normalized `t:run/0` from recorded `Kazi.ReadModel.Iteration` rows (or
  the equivalent maps) plus a `meta` map, and fold it to `t:kpis/0`.

  `meta` carries the run-level fields the iteration rows don't hold:
  `:status`, `:converged_predicates`, `:iteration_count`, `:usage`, and the
  `:harness` / `:model` / `:context_tier` labels. The iteration rows supply the
  per-iteration `context` / `tools` / `converged` / `observed_at` the cache and
  re-discovery KPIs fold over. This is the `from a RECORDED run` path the
  acceptance exercises.
  """
  @spec from_iterations([map()], map()) :: kpis()
  def from_iterations(iterations, meta) when is_list(iterations) and is_map(meta) do
    meta
    |> Map.put(:iterations, Enum.map(iterations, &normalize_iteration/1))
    |> compute()
  end

  @doc "Map `compute/1` over a list of normalized runs (the input to `aggregate/1`)."
  @spec compute_runs([run()]) :: [kpis()]
  def compute_runs(runs) when is_list(runs), do: Enum.map(runs, &compute/1)

  @doc """
  Reconstruct a per-run `t:kpis/0` map from a recorded `kazi apply --json` result
  object (a decoded map) plus the arm's `{harness, model, context_tier}` labels.

  This is the benchmark's consumer path (T34.7): a recorded run already carries
  its `economy` object (the per-run KPIs the run computed) and its `usage` /
  `predicates` / `status`. `from_run_result/2` reads that back into a `t:kpis/0`
  map — re-deriving nothing — overlaying the arm labels so `aggregate/1` can table
  the run by harness/model/tier. A field the run reported unavailable stays `nil`
  (honest-unknown is preserved across the round-trip). Accepts atom or string
  keys; `labels` keys are `:harness` / `:model` / `:context_tier`.
  """
  @spec from_run_result(map(), map()) :: kpis()
  def from_run_result(result, labels \\ %{}) when is_map(result) do
    economy = get(result, :economy) || %{}
    status = get(economy, :status) || get(result, :status) |> to_status()

    %{
      harness: Map.get(labels, :harness) || get(economy, :harness),
      model: Map.get(labels, :model) || get(economy, :model),
      context_tier: Map.get(labels, :context_tier) || get(economy, :context_tier),
      status: status,
      stuck: status == "stuck",
      converged_predicates:
        get(economy, :converged_predicates) || count_passing(get(result, :predicates)),
      iterations: get(economy, :iterations) || get(result, :iterations) || 0,
      iterations_to_convergence: get(economy, :iterations_to_convergence),
      tokens: get(economy, :tokens) || token_total(get(result, :usage) || %{}),
      cost_usd: get(economy, :cost_usd) || get(get(result, :usage) || %{}, :cost_usd),
      wall_clock_s: get(economy, :wall_clock_s),
      cost_per_converged_predicate: get(economy, :cost_per_converged_predicate),
      wall_clock_per_converged_predicate: get(economy, :wall_clock_per_converged_predicate),
      fresh_input_tokens_avoided: get(economy, :fresh_input_tokens_avoided),
      rediscovery_tool_calls_avoided: get(economy, :rediscovery_tool_calls_avoided)
    }
  end

  # ===========================================================================
  # breakdown (by harness / model / context tier)
  # ===========================================================================

  @typedoc "One breakdown row: a `{harness, model, context_tier}` group's KPIs."
  @type group :: %{
          harness: String.t() | nil,
          model: String.t() | nil,
          context_tier: String.t() | nil,
          runs: non_neg_integer(),
          stuck_rate: float(),
          converged_rate: float(),
          mean_cost_per_converged_predicate: float() | nil,
          mean_wall_clock_per_converged_predicate: float() | nil,
          mean_iterations_to_convergence: float() | nil,
          fresh_input_tokens_avoided: non_neg_integer() | nil,
          rediscovery_tool_calls_avoided: non_neg_integer() | nil
        }

  @doc """
  Fold a list of per-run `t:kpis/0` maps into per-`{harness, model, context_tier}`
  breakdown rows (the benchmark's arm table, T34.6/T34.7).

  The input is the per-run KPI maps — each `compute/1`'s output (or
  `from_run_result/2`'s, when the benchmark re-reads recorded `apply --json`
  results). `stuck_rate` and `converged_rate` are always computable (every run
  carries a status); the per-converged-predicate means and the avoided-token sums
  are `nil` when NO run in the group reported the underlying field
  (honest-unknown). Rows are sorted by `{harness, model, context_tier}` for a
  deterministic table.
  """
  @spec aggregate([kpis()]) :: [group()]
  def aggregate(kpis_list) when is_list(kpis_list) do
    kpis_list
    |> Enum.group_by(fn k -> {k.harness, k.model, k.context_tier} end)
    |> Enum.map(fn {{harness, model, tier}, kpis} ->
      n = length(kpis)

      %{
        harness: harness,
        model: model,
        context_tier: tier,
        runs: n,
        stuck_rate: rate(kpis, &(&1.status == "stuck"), n),
        converged_rate: rate(kpis, &(&1.status == "converged"), n),
        mean_cost_per_converged_predicate: mean(kpis, & &1.cost_per_converged_predicate),
        mean_wall_clock_per_converged_predicate:
          mean(kpis, & &1.wall_clock_per_converged_predicate),
        mean_iterations_to_convergence: mean(kpis, & &1.iterations_to_convergence),
        fresh_input_tokens_avoided: sum_present(kpis, & &1.fresh_input_tokens_avoided),
        rediscovery_tool_calls_avoided: sum_present(kpis, & &1.rediscovery_tool_calls_avoided)
      }
    end)
    |> Enum.sort_by(fn g ->
      {to_string(g.harness), to_string(g.model), to_string(g.context_tier)}
    end)
  end

  # ===========================================================================
  # renderers
  # ===========================================================================

  @doc """
  Render a single run's `t:kpis/0` as a JSON-safe map for the `--json` run-result
  `economy` object, OMITTING every `nil`-valued (unavailable) KPI so an absent
  key means "unreported", never "zero" (ADR-0046 §6).

  Always present: `status`, `stuck`, `iterations`. Everything else is included
  only when it was derivable. The `harness` / `model` / `context_tier` labels are
  included only when non-`nil`.
  """
  @spec to_json(kpis()) :: map()
  def to_json(kpis) when is_map(kpis) do
    base = %{
      "status" => kpis.status,
      "stuck" => kpis.stuck,
      "iterations" => kpis.iterations
    }

    [
      {"harness", kpis.harness},
      {"model", kpis.model},
      {"context_tier", kpis.context_tier},
      {"converged_predicates", kpis.converged_predicates},
      {"iterations_to_convergence", kpis.iterations_to_convergence},
      {"tokens", kpis.tokens},
      {"cost_usd", kpis.cost_usd},
      {"wall_clock_s", kpis.wall_clock_s},
      {"cost_per_converged_predicate", kpis.cost_per_converged_predicate},
      {"wall_clock_per_converged_predicate", kpis.wall_clock_per_converged_predicate},
      {"fresh_input_tokens_avoided", kpis.fresh_input_tokens_avoided},
      {"rediscovery_tool_calls_avoided", kpis.rediscovery_tool_calls_avoided}
    ]
    |> Enum.reduce(base, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  @doc """
  Render the `aggregate/1` breakdown rows as a deterministic markdown table (the
  benchmark's per-arm economy table, T34.7). An unavailable cell prints `n/a`
  (never `0`); the table is byte-stable for a given row list, so a test can
  assert on it. An empty list yields the header-only table.
  """
  @spec render_table([group()]) :: String.t()
  def render_table(groups) when is_list(groups) do
    header =
      "| Harness | Model | Tier | Runs | Stuck-rate | Converged-rate | " <>
        "Cost/conv-pred | Wall/conv-pred (s) | Iters-to-conv | " <>
        "Fresh-input-avoided | Rediscovery-avoided |"

    divider = "|---|---|---|---|---|---|---|---|---|---|---|"

    rows =
      Enum.map(groups, fn g ->
        "| #{label(g.harness)} | #{label(g.model)} | #{label(g.context_tier)} | " <>
          "#{g.runs} | #{fmt_rate(g.stuck_rate)} | #{fmt_rate(g.converged_rate)} | " <>
          "#{fmt_usd(g.mean_cost_per_converged_predicate)} | " <>
          "#{fmt_float(g.mean_wall_clock_per_converged_predicate)} | " <>
          "#{fmt_float(g.mean_iterations_to_convergence)} | " <>
          "#{fmt_int(g.fresh_input_tokens_avoided)} | " <>
          "#{fmt_int(g.rediscovery_tool_calls_avoided)} |"
      end)

    Enum.join([header, divider | rows], "\n") <> "\n"
  end

  # ===========================================================================
  # per-KPI derivations
  # ===========================================================================

  defp converged_predicates(run) do
    case Map.get(run, :converged_predicates) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp cost_usd(run) do
    case fetch(Map.get(run, :usage, %{}) || %{}, :cost_usd) do
      {:ok, n} when is_number(n) -> n / 1.0
      _ -> nil
    end
  end

  # The run-aggregate token total surfaced in the economy object (T34.8): the sum
  # of the run's reported token components (the T34.1/T34.2 `usage` envelope the
  # loop accumulated from each dispatch's parsed Anthropic usage). `nil` when the
  # harness reported NO token component at all (absent ≠ zero — honest-unknown),
  # so a consumer never reads kazi's economy as "tokens: 0" on a run whose harness
  # simply did not report usage; a run that DID report usage carries the real,
  # non-zero total here without a capture shim.
  defp tokens(run), do: token_total(Map.get(run, :usage, %{}) || %{})

  defp usage_field(usage, key) do
    case fetch(usage, key) do
      {:ok, n} when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  # The token fields of the ADR-0046 `usage` envelope (the same five
  # `Kazi.CLI.Usage` renders, minus `cost_usd`). Summed for the economy `tokens`
  # total; an envelope reporting none of them yields `nil`, never `0`.
  @usage_token_fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_tokens,
    :output_tokens,
    :reasoning_tokens
  ]

  @spec token_total(map()) :: non_neg_integer() | nil
  defp token_total(usage) when is_map(usage) do
    Enum.reduce(@usage_token_fields, nil, fn field, acc ->
      case fetch(usage, field) do
        {:ok, n} when is_integer(n) and n >= 0 -> (acc || 0) + n
        _ -> acc
      end
    end)
  end

  defp token_total(_usage), do: nil

  # Iterations to convergence: the 1-based position of the FIRST converged
  # observation in the per-iteration list. With no per-iteration list (no
  # persistence) fall back to the loop's observation count ONLY on a converged
  # run (a converged run's last observation IS the converging one); a
  # non-converged run never reached convergence ⇒ `nil` (honest, not the total).
  defp iterations_to_convergence("converged", [], iteration_count)
       when is_integer(iteration_count) and iteration_count > 0,
       do: iteration_count

  defp iterations_to_convergence(_status, [], _iteration_count), do: nil

  defp iterations_to_convergence(_status, iterations, _iteration_count) do
    case Enum.find_index(iterations, &(&1.converged == true)) do
      nil -> nil
      idx -> idx + 1
    end
  end

  # Wall-clock seconds: the span between the first and last recorded observation
  # timestamp. Needs at least two timestamps to measure a span; fewer ⇒ `nil`
  # (a single timestamp gives no measurable duration — unavailable, not `0`).
  defp wall_clock_s(iterations) do
    stamps =
      iterations
      |> Enum.map(& &1.observed_at)
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> Enum.sort(DateTime)

    case stamps do
      [_, _ | _] = sorted ->
        DateTime.diff(List.last(sorted), List.first(sorted), :microsecond) / 1_000_000

      _ ->
        nil
    end
  end

  # Fresh input tokens avoided: the orientation/retrieval section tokens served
  # from the inner harness's prompt cache (a `"hit"`) instead of re-sent as fresh
  # input — the saving a stable prefix (T19.2) buys. Derived from the T34.3
  # `context` counters. `nil` when NO iteration recorded any context counters
  # (pre-T34.3 / no dispatch); a real measured `0` when context WAS recorded but
  # nothing hit (cold or cache-off run).
  defp fresh_input_tokens_avoided(iterations) do
    context_bearing = Enum.filter(iterations, &(map_size(&1.context) > 0))

    case context_bearing do
      [] ->
        nil

      rows ->
        Enum.reduce(rows, 0, fn it, acc ->
          acc + avoided_for_section(it.context, :orientation_cache, :orientation_tokens) +
            avoided_for_section(it.context, :retrieval_cache, :retrieval_tokens)
        end)
    end
  end

  defp avoided_for_section(context, cache_key, tokens_key) do
    case fetch(context, cache_key) do
      {:ok, "hit"} -> int(fetch(context, tokens_key))
      _ -> 0
    end
  end

  # Rediscovery tool-calls avoided: a cold first dispatch must re-discover the
  # working set (file reads + searches + graph queries); a working stable prefix
  # lets later dispatches skip that re-discovery. Avoided = the per-iteration
  # shortfall below the cold baseline, summed over the later tool-bearing
  # iterations. `tools` is present ONLY when the harness exposed a tool stream
  # (absent ≠ zero), so this needs >= 2 tool-bearing iterations; fewer ⇒ `nil`
  # (unmeasurable, not zero).
  defp rediscovery_tool_calls_avoided(iterations) do
    rediscovery =
      iterations
      |> Enum.filter(&(map_size(&1.tools) > 0))
      |> Enum.map(&rediscovery_calls(&1.tools))

    case rediscovery do
      [baseline | rest] when rest != [] ->
        Enum.reduce(rest, 0, fn calls, acc -> acc + max(0, baseline - calls) end)

      _ ->
        nil
    end
  end

  defp rediscovery_calls(tools) do
    int(fetch(tools, :file_reads)) + int(fetch(tools, :search_calls)) +
      int(fetch(tools, :graph_calls))
  end

  # ===========================================================================
  # aggregate helpers
  # ===========================================================================

  defp rate(_kpis, _pred, 0), do: 0.0

  defp rate(kpis, pred, n) do
    Enum.count(kpis, pred) / n
  end

  # Mean of the present (non-nil) values; `nil` when every run was unavailable.
  defp mean(kpis, getter) do
    present = kpis |> Enum.map(getter) |> Enum.reject(&is_nil/1)

    case present do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end

  # Sum of the present (non-nil) values; `nil` when every run was unavailable.
  defp sum_present(kpis, getter) do
    present = kpis |> Enum.map(getter) |> Enum.reject(&is_nil/1)

    case present do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  # ===========================================================================
  # normalization + small helpers
  # ===========================================================================

  defp list_iterations(run) do
    case Map.get(run, :iterations) do
      list when is_list(list) -> Enum.map(list, &normalize_iteration/1)
      _ -> []
    end
  end

  defp iteration_count(run, iterations) do
    case Map.get(run, :iteration_count) do
      n when is_integer(n) and n >= 0 -> n
      _ -> length(iterations)
    end
  end

  # Normalize an iteration (a `Kazi.ReadModel.Iteration` struct, or a map with
  # atom or string keys) into the internal atom-keyed shape the fold reads.
  defp normalize_iteration(%_{} = struct) do
    %{
      converged: Map.get(struct, :converged) == true,
      context: Map.get(struct, :context) || %{},
      tools: Map.get(struct, :tools) || %{},
      observed_at: Map.get(struct, :observed_at)
    }
  end

  defp normalize_iteration(map) when is_map(map) do
    %{
      converged: fetch_bool(map, :converged),
      context: fetch_map(map, :context),
      tools: fetch_map(map, :tools),
      observed_at: Map.get(map, :observed_at, Map.get(map, "observed_at"))
    }
  end

  defp fetch_bool(map, key), do: match?({:ok, true}, fetch(map, key))

  defp fetch_map(map, key) do
    case fetch(map, key) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # Read a key under its atom OR string form; a missing/nil value is `:error`.
  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key, Map.get(map, to_string(key))) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  # Read a key under its atom OR string form, returning the value or `nil`.
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_map, _key), do: nil

  # Count the `pass` verdicts in a recorded `predicates[]` array (a list of
  # `{"id", "verdict"}` maps), the converged-predicate denominator when a recorded
  # result carries no explicit count. `nil` for an absent/non-list value.
  defp count_passing(predicates) when is_list(predicates) do
    Enum.count(predicates, fn p -> get(p, :verdict) == "pass" end)
  end

  defp count_passing(_), do: nil

  defp int({:ok, n}) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0

  # cost_usd / converged-predicates (or wall-clock / converged-predicates):
  # `nil` when the numerator is unavailable OR there is no converged predicate to
  # divide by (no division by zero, no fabricated "0 per 0").
  defp ratio(_numerator, denom) when denom in [nil, 0], do: nil
  defp ratio(nil, _denom), do: nil
  defp ratio(numerator, denom) when is_number(numerator), do: numerator / denom

  defp to_status(status) when is_binary(status), do: status
  defp to_status(status) when is_atom(status) and not is_nil(status), do: Atom.to_string(status)
  defp to_status(_), do: "unknown"

  defp label(nil), do: "—"
  defp label(value), do: to_string(value)

  defp fmt_rate(rate) when is_float(rate), do: :erlang.float_to_binary(rate, decimals: 2)
  defp fmt_usd(nil), do: "n/a"
  defp fmt_usd(value) when is_number(value), do: :erlang.float_to_binary(value / 1.0, decimals: 6)
  defp fmt_float(nil), do: "n/a"

  defp fmt_float(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1.0, decimals: 2)

  defp fmt_int(nil), do: "n/a"
  defp fmt_int(value) when is_integer(value), do: Integer.to_string(value)
end
