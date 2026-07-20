defmodule Kazi.Velocity.Kpis do
  @moduledoc """
  Velocity KPI queries (T67.4, ADR-0079 §4): per-agent and fleet-level RATES and
  RATIOS computed by joining the T67.2 `delivery_events` and T67.3
  `session_counters` projections with the existing run registry
  (`Kazi.ReadModel.Run`). A pure read over `Kazi.Repo` (ADR-0011 §2) — it never
  writes and never touches the loop.

  ## The KPI vocabulary (ADR-0079 §4)

    * **delivered / day** — `:task_tick` delivery rows per trailing window, as a
      rate (count ÷ window days); fleet-level and per-agent.
    * **tokens per delivered task** — a session's cumulative `session_counters`
      tokens ÷ its delivered tasks in the window (a ratio).
    * **stuck ratio** — `(stuck + over_budget) ÷ total terminal verdicts`, over
      finished runs, per agent (session) AND per model.
    * **rescue count** — lanes (goals) whose terminal `converged` run was
      produced by a DIFFERENT session than the one that first claimed the lane.
    * **claim → merge lead time** — a duration DISTRIBUTION (p50/p90) over
      deliveries joined to their claiming run's `started_at`, NEVER a single
      promised ETA.

  ## Rate-only, honest-unknown (ADR-0046)

  Every number here is a rate, a ratio, or a distribution. Insufficient data
  yields an honest `nil` ("not enough data yet"), never a fabricated `0`
  presented as a measurement, and never a division blow-up on an empty window.

  The public `%Kpis{}` struct (and every nested struct) exposes **NO**
  projected-completion / ETA / estimate field at all — a future UI cannot render
  one because the type cannot represent it (`kpis_test.exs` asserts the absence
  at the type layer, the negative assertion T63.9 pins at the render layer).

  ## Reconciliation with `kazi economy`

  The per-model split (`stuck_by_model`) draws its terminal universe from the
  SAME finished-runs population `Kazi.Economy.History.aggregate/1` groups
  (`finished_at` not nil) and buckets `model` through the SAME
  `Kazi.Economy.ModelIdNormalization.normalize/1`, so the per-model terminal
  counts reconcile with economy's group sizes on one fixture rather than forking
  a second cost/outcome truth (`kpis_test.exs` pins the reconciliation).
  """

  import Ecto.Query, only: [from: 2]

  alias Kazi.Economy.ModelIdNormalization
  alias Kazi.ReadModel.{DeliveryEvent, Run, SessionCounters}
  alias Kazi.Repo

  @token_fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_tokens,
    :output_tokens,
    :reasoning_tokens
  ]

  # Terminal verdicts a run can carry (ADR-0058); "stuck ratio" numerator is the
  # subset that means the lane did not converge under budget.
  @stuck_statuses ~w(stuck over_budget)

  defmodule Distribution do
    @moduledoc "A claim→merge lead-time distribution: p50/p90 in seconds over `n` samples (`nil` percentiles when `n == 0`)."
    @type t :: %__MODULE__{p50_s: number() | nil, p90_s: number() | nil, n: non_neg_integer()}
    defstruct p50_s: nil, p90_s: nil, n: 0
  end

  defmodule Agent do
    @moduledoc "Per-agent (session UUID) velocity KPIs. `nil` fields are honest-unknown, never 0."
    @type t :: %__MODULE__{}
    defstruct [
      :session_uuid,
      :session_name,
      :delivered_count,
      :delivered_per_day,
      :tokens_per_delivered_task,
      :stuck_ratio,
      :terminal_count,
      # #1651: WHY `delivered_*` is nil. `:ok` means attribution worked and the
      # numbers are measured (including a real 0). `:unattributable` means this
      # window contains deliveries that carry NO session_uuid, so this agent may
      # own some of them and a 0 would be a fabricated measurement, not a fact.
      :delivered_attribution
    ]
  end

  defmodule ModelStuck do
    @moduledoc "Per-model stuck ratio over finished runs; the terminal universe reconciles with `kazi economy`."
    @type t :: %__MODULE__{}
    defstruct [:model, :stuck_ratio, :stuck_count, :terminal_count]
  end

  @type t :: %__MODULE__{
          window_days: pos_integer(),
          window_label: String.t(),
          delivered_per_day: number() | nil,
          delivered_count: non_neg_integer(),
          tokens_per_delivered_task: number() | nil,
          rescue_count: non_neg_integer(),
          lead_time: Distribution.t(),
          per_agent: [Agent.t()],
          stuck_by_model: [ModelStuck.t()]
        }
  defstruct [
    :window_days,
    :window_label,
    :delivered_per_day,
    :delivered_count,
    :tokens_per_delivered_task,
    :rescue_count,
    :lead_time,
    :per_agent,
    :stuck_by_model
  ]

  @doc """
  Computes the velocity KPIs over a trailing window. Options:

    * `:window_days` — the trailing window width in days (default `7`).
    * `:now` — the window's upper bound (`DateTime`, default `DateTime.utc_now/0`);
      deliveries with a timestamp in `(now - window_days, now]` are counted.

  Returns a `%Kpis{}` with rate/ratio/distribution fields only — no ETA field
  exists. Honest-unknown throughout: an empty window yields `delivered_per_day:
  0` samples with `tokens_per_delivered_task: nil` (no division), and stuck
  ratios are `nil` for a session/model with no terminal run.
  """
  @spec compute(keyword()) :: t()
  def compute(opts \\ []) do
    window_days = Keyword.get(opts, :window_days, 7)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -window_days * 86_400, :second)

    deliveries = windowed_task_ticks(since, now)
    counters = all_counters()
    runs = finished_runs()

    delivered_count = length(deliveries)
    by_session = Enum.group_by(deliveries, & &1.session_uuid)
    counters_by_session = index_counters(counters)
    terminal_by_session = Enum.group_by(runs, & &1.harness_session_id)

    %__MODULE__{
      window_days: window_days,
      window_label: "last #{window_days}d",
      delivered_per_day: rate(delivered_count, window_days),
      delivered_count: delivered_count,
      tokens_per_delivered_task: fleet_tokens_per_task(counters, delivered_count),
      rescue_count: rescue_count(),
      lead_time: lead_time_distribution(deliveries, runs),
      per_agent: per_agent(by_session, counters_by_session, terminal_by_session, window_days),
      stuck_by_model: stuck_by_model(runs)
    }
  end

  # ---------------------------------------------------------------------------
  # Delivered / day
  # ---------------------------------------------------------------------------

  # `:task_tick` deliveries whose delivery instant falls in `(since, now]`. The
  # instant is `merged_at` when present, else the plan `Done:` date at midnight
  # UTC (a git-derived tick with no merge timestamp still counts on its day).
  defp windowed_task_ticks(since, now) do
    from(d in DeliveryEvent, where: d.kind == "task_tick")
    |> Repo.all()
    |> Enum.filter(fn d ->
      case delivered_at(d) do
        nil -> false
        at -> DateTime.compare(at, since) == :gt and DateTime.compare(at, now) != :gt
      end
    end)
  end

  defp delivered_at(%DeliveryEvent{merged_at: %DateTime{} = at}), do: at

  defp delivered_at(%DeliveryEvent{done_on: %Date{} = date}) do
    {:ok, at} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    at
  end

  defp delivered_at(_), do: nil

  # #1651: an agent's delivered figure is a MEASUREMENT only when attribution is
  # actually working for this window. If any delivery in the window carries no
  # session_uuid, an agent with no attributed deliveries may own some of them --
  # so "0.0 /day" would assert something we cannot know. That is the ADR-0046
  # fabricated-measurement failure, and it is worse than an empty cell: an empty
  # cell says nothing, "0.0 /day" affirmatively claims the agent delivered
  # nothing. Note the branch is per AGENT, not per corpus: an agent WITH
  # attributed deliveries still reports its real rate alongside neighbours that
  # report unattributable, so a partially-working join degrades row by row and
  # never collapses everyone to the worst case.
  @spec delivered_attribution(non_neg_integer(), non_neg_integer()) ::
          :ok | :unattributable
  defp delivered_attribution(0, unattributed) when unattributed > 0, do: :unattributable
  defp delivered_attribution(_delivered, _unattributed), do: :ok

  # `nil` over a fabricated 0 -- the Agent struct's own contract ("nil fields are
  # honest-unknown, never 0").
  defp delivered_or_unknown(_delivered, :unattributable), do: nil
  defp delivered_or_unknown(delivered, :ok), do: delivered

  defp delivered_rate(_delivered, _days, :unattributable), do: nil
  defp delivered_rate(delivered, days, :ok), do: rate(delivered, days)

  # A rate is count ÷ window days, rounded to 2dp. Zero deliveries is a real
  # measured 0.0/day (the window happened and nothing landed), not an unknown.
  defp rate(_count, days) when days <= 0, do: nil
  defp rate(count, days), do: Float.round(count / days, 2)

  # ---------------------------------------------------------------------------
  # Tokens per delivered task
  # ---------------------------------------------------------------------------

  # Fleet: total counter tokens across every session ÷ delivered tasks in the
  # window. `nil` (never 0) when nothing delivered (no division) or no session
  # exposed any token counter (honest-unknown).
  defp fleet_tokens_per_task(_counters, 0), do: nil

  defp fleet_tokens_per_task(counters, delivered_count) do
    case sum_tokens(counters) do
      nil -> nil
      total -> Float.round(total / delivered_count, 1)
    end
  end

  # Sum of the non-nil token counters across the given rows. `nil` when EVERY
  # token field on every row is unreported (ADR-0046) — distinct from a real 0.
  defp sum_tokens(rows) do
    values =
      for row <- rows, field <- @token_fields, val = Map.get(row, field), not is_nil(val), do: val

    case values do
      [] -> nil
      vals -> Enum.sum(vals)
    end
  end

  defp index_counters(counters) do
    # Sum across machines: a session's counters may be reported per opted-in host.
    Enum.group_by(counters, & &1.session_uuid)
  end

  # ---------------------------------------------------------------------------
  # Per-agent rollup
  # ---------------------------------------------------------------------------

  defp per_agent(by_session, counters_by_session, terminal_by_session, window_days) do
    # #1651: deliveries in this window that carry NO session_uuid. A git-derived
    # tick has no goal_ref, so `DeliveryProjection.attribute_session/1` leaves
    # `session_uuid` nil rather than guessing (ADR-0046) -- correct at the data
    # layer, but it means an agent's 0 is only a MEASURED zero when this is empty.
    unattributed = length(Map.get(by_session, nil, []))

    session_uuids =
      [Map.keys(by_session), Map.keys(counters_by_session), Map.keys(terminal_by_session)]
      |> Enum.concat()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(session_uuids, fn uuid ->
      deliveries = Map.get(by_session, uuid, [])
      counters = Map.get(counters_by_session, uuid, [])
      terminal = Map.get(terminal_by_session, uuid, [])
      delivered = length(deliveries)
      attribution = delivered_attribution(delivered, unattributed)

      %Agent{
        session_uuid: uuid,
        session_name: session_name(counters, terminal),
        delivered_count: delivered_or_unknown(delivered, attribution),
        delivered_per_day: delivered_rate(delivered, window_days, attribution),
        delivered_attribution: attribution,
        tokens_per_delivered_task: agent_tokens_per_task(counters, delivered),
        stuck_ratio: stuck_ratio(terminal),
        terminal_count: length(terminal)
      }
    end)
  end

  defp agent_tokens_per_task(_counters, 0), do: nil

  defp agent_tokens_per_task(counters, delivered) do
    case sum_tokens(counters) do
      nil -> nil
      total -> Float.round(total / delivered, 1)
    end
  end

  # Display alias only (ADR-0079 §1): the last-observed `session_name`, never a
  # join key. Prefer a counters row's name; fall back to a run's session_name.
  defp session_name(counters, terminal) do
    from_counters = counters |> Enum.map(& &1.session_name) |> Enum.find(&(&1 not in [nil, ""]))
    from_runs = terminal |> Enum.map(& &1.session_name) |> Enum.find(&(&1 not in [nil, ""]))
    from_counters || from_runs
  end

  # ---------------------------------------------------------------------------
  # Stuck ratio (per agent + per model)
  # ---------------------------------------------------------------------------

  # (stuck + over_budget) ÷ total terminal verdicts. `nil` (never 0) for an empty
  # set: a session/model with no terminal run has an UNKNOWN stuck ratio, not a
  # measured 0.0.
  defp stuck_ratio([]), do: nil

  defp stuck_ratio(runs) do
    total = length(runs)
    stuck = Enum.count(runs, &(&1.status in @stuck_statuses))
    Float.round(stuck / total, 3)
  end

  defp stuck_by_model(runs) do
    runs
    |> Enum.group_by(&ModelIdNormalization.normalize(&1.model))
    |> Enum.map(fn {model, model_runs} ->
      %ModelStuck{
        model: model,
        stuck_ratio: stuck_ratio(model_runs),
        stuck_count: Enum.count(model_runs, &(&1.status in @stuck_statuses)),
        terminal_count: length(model_runs)
      }
    end)
    |> Enum.sort_by(&(&1.model || ""))
  end

  # ---------------------------------------------------------------------------
  # Rescue count
  # ---------------------------------------------------------------------------

  # A lane (goal_ref) is RESCUED when the session that produced its terminal
  # `converged` run differs from the session that first claimed the lane (its
  # earliest `started_at` run). Run-registry only — this is the closest durable
  # analogue of "a lane closed by a different session than claimed", since claims
  # themselves are ephemeral git refs, not read-model state.
  defp rescue_count do
    all_runs()
    |> Enum.group_by(& &1.goal_ref)
    |> Enum.count(fn {_goal_ref, runs} -> rescued?(runs) end)
  end

  defp rescued?(runs) do
    claimant = runs |> Enum.min_by(& &1.started_at, DateTime) |> Map.get(:harness_session_id)

    closer =
      runs
      |> Enum.filter(&(&1.status == "converged"))
      |> Enum.max_by(& &1.finished_at, DateTime, fn -> nil end)

    case {claimant, closer} do
      {nil, _} -> false
      {_, nil} -> false
      {claimant, %Run{harness_session_id: closer}} -> not is_nil(closer) and closer != claimant
    end
  end

  # ---------------------------------------------------------------------------
  # Claim → merge lead-time distribution (p50/p90)
  # ---------------------------------------------------------------------------

  # For each delivery with an attributed session and a merge instant, the lead
  # time is `merged_at - claim`, where the claim is the latest `started_at` of a
  # run by that session that is not after the merge (the claim in effect at the
  # merge). Deliveries with no joinable claim contribute no sample (honest-unknown,
  # not a fabricated 0). Reported as a DISTRIBUTION, never a promised ETA.
  defp lead_time_distribution(deliveries, runs) do
    runs_by_session = Enum.group_by(runs, & &1.harness_session_id)

    samples =
      deliveries
      |> Enum.map(&lead_seconds(&1, runs_by_session))
      |> Enum.reject(&is_nil/1)

    %Distribution{
      p50_s: percentile(samples, 50),
      p90_s: percentile(samples, 90),
      n: length(samples)
    }
  end

  defp lead_seconds(%DeliveryEvent{session_uuid: nil}, _runs_by_session), do: nil

  defp lead_seconds(%DeliveryEvent{merged_at: nil}, _runs_by_session), do: nil

  defp lead_seconds(%DeliveryEvent{session_uuid: uuid, merged_at: merged_at}, runs_by_session) do
    runs_by_session
    |> Map.get(uuid, [])
    |> Enum.filter(fn r ->
      match?(%DateTime{}, r.started_at) and DateTime.compare(r.started_at, merged_at) != :gt
    end)
    |> case do
      [] ->
        nil

      candidates ->
        claim = Enum.max_by(candidates, & &1.started_at, DateTime)
        DateTime.diff(merged_at, claim.started_at, :second)
    end
  end

  # Nearest-rank percentile, the SAME method `Kazi.Economy.History` uses so the
  # two surfaces read consistently: rank = ceil(p/100 * n), clamped to [1, n].
  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    n = length(sorted)
    rank = (p / 100 * n) |> Float.ceil() |> trunc() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end

  # ---------------------------------------------------------------------------
  # Read-model loads
  # ---------------------------------------------------------------------------

  # Finished runs = the SAME terminal universe `Kazi.Economy.History` aggregates
  # (`finished_at` not nil), so the per-model split reconciles with `kazi economy`.
  defp finished_runs do
    Repo.all(from(r in Run, where: not is_nil(r.finished_at)))
  end

  defp all_runs, do: Repo.all(Run)

  defp all_counters, do: Repo.all(SessionCounters)
end
