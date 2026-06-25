defmodule Kazi.Context.Escalation do
  @moduledoc """
  Escalate the context-budget tier on non-progress, with a stop rule (T36.4,
  ADR-0047 decisions 2 & 4).

  `Kazi.Context.Tier` (T36.3) NAMES the ladder (0–4, default 1) and records the
  active tier per iteration but ships NO policy — ADR-0047 forbids baking a
  guessed ladder into the loop. This module is that policy, kept pure and config
  driven so the ladder is *tunable*, not hardcoded:

    * **Escalate on non-progress.** When the loop makes no headway against the same
      failing set (the ADR-0041 score gradient is flat — the SAME signal the
      `Kazi.Loop.StuckDetector` reads, see `Kazi.Loop`), step the active tier UP
      one rung (1 → 2 → 3 → 4) so the next dispatch assembles more context (graph,
      then retrieval, then a repo snapshot). Escalation never fires immediately: it
      waits for `threshold` consecutive non-progress observations at the current
      tier.
    * **Stop rule (ADR-0047 §4).** A tier bump is a *bet* that more context buys
      progress. The cost of that bet is the per-iteration token/cost spend
      (ADR-0046). If the escalated rung's first iteration STILL does not progress
      AND it cost MORE than the rung below, the bump was net-negative — the loop
      reverts to the lower tier and stops climbing for the run (cost-per-converged-
      predicate is the KPI, not minimal tokens nor maximal context).

  ## Why config, not constants (ADR-0047 §2)

  ADR-0047 commits the tool-surface win now but GATES the tier ladder on the E19
  benchmark (T19.5/T19.7) measuring which tier minimizes cost-per-converged-
  predicate per task class, and the T36.5 benchmark arms that map onto these
  knobs. Until that data lands, the threshold here is a *provisional default*, not
  a proven one: `default_threshold/0` is `2` — one below the stuck window
  (`Kazi.Loop.StuckDetector.default_iterations/0` is `3`) so a stall is given a
  richer-context attempt BEFORE the run is abandoned as stuck — and every field is
  overridable via the `:context_escalation` loop opt or
  `config :kazi, :context_escalation`. The defaults are explicitly labelled
  provisional pending T36.5; nothing here is shipped as a proven ladder.

  ## Pure state machine

  `init/2` seeds the state from the base tier; `step/3` folds one observation's
  signal into the next state and a decision. No I/O, no process state — the loop
  (`Kazi.Loop`) owns the signal (computing `progressing?`/`cost` from its history
  and usage envelope) and applies the resulting tier; this module only decides.
  """

  alias Kazi.Context.Tier

  @typedoc "The escalation decision for one observation."
  @type decision ::
          :hold
          | {:escalate, Tier.t(), Tier.t()}
          | {:revert, Tier.t(), Tier.t()}

  @typedoc """
  One observation's signal, supplied by `Kazi.Loop`:

    * `:progressing?` — whether the latest code observation made headway (the
      failing set shrank/changed, a graded score improved, or there is no failing
      work). The inverse is the non-progress signal escalation counts.
    * `:cost` — the cost attributable to the dispatch this observation measures
      (the PER-ITERATION token/cost delta, ADR-0046), the stop rule compares
      across an escalation.
  """
  @type signal :: %{progressing?: boolean(), cost: number()}

  defmodule Config do
    @moduledoc """
    The escalation ladder's tunable knobs (ADR-0047 §2). Resolved by
    `Kazi.Context.Escalation.config/1` from the `:context_escalation` loop opt /
    `config :kazi, :context_escalation`, falling back to the provisional defaults.
    """

    @type t :: %__MODULE__{
            enabled: boolean(),
            threshold: pos_integer(),
            min_tier: Kazi.Context.Tier.t(),
            max_tier: Kazi.Context.Tier.t(),
            stop_rule: boolean()
          }

    defstruct enabled: true,
              threshold: 2,
              min_tier: 0,
              max_tier: 4,
              stop_rule: true
  end

  defmodule State do
    @moduledoc """
    The escalation state machine's working set (T36.4). Pure data threaded through
    `Kazi.Context.Escalation.step/3`; `Kazi.Loop` holds it across observations and
    reads `tier` for the active dispatch tier.
    """

    @type t :: %__MODULE__{
            tier: Kazi.Context.Tier.t(),
            base_tier: Kazi.Context.Tier.t(),
            nonprogress: non_neg_integer(),
            awaiting: boolean(),
            baseline_cost: number() | nil,
            escalated_from: Kazi.Context.Tier.t() | nil,
            climbing_stopped: boolean()
          }

    defstruct tier: 1,
              base_tier: 1,
              # consecutive non-progress observations since the last reset/escalation
              nonprogress: 0,
              # true after an escalation, until its effect is assessed by the stop rule
              awaiting: false,
              # the per-iteration cost captured at the escalation under assessment
              baseline_cost: nil,
              # the tier we escalated FROM (the rung the stop rule reverts to)
              escalated_from: nil,
              # the stop rule fired this run: no more escalation
              climbing_stopped: false
  end

  @doc """
  The provisional default escalation threshold: the number of consecutive
  non-progress observations at a tier before stepping up (ADR-0047 §2).

  `2` — one below the stuck window (`Kazi.Loop.StuckDetector.default_iterations/0`
  is `3`) so a stall gets a richer-context attempt BEFORE the run is abandoned as
  stuck. PROVISIONAL pending the E19/T36.5 benchmark that tunes it from data; not
  a proven ladder (ADR-0047 forbids shipping one).

  ## Examples

      iex> Kazi.Context.Escalation.default_threshold()
      2
  """
  @spec default_threshold() :: pos_integer()
  def default_threshold, do: 2

  @doc """
  Resolve an escalation `Config` from the `:context_escalation` loop opt
  (precedence), `config :kazi, :context_escalation`, then the provisional
  defaults. Accepts a `Config`, a keyword/map of overrides, or `nil`.

  Unknown / malformed values fall back to the default for that field, so a bad
  config never crashes a dispatch (the loop assembles the default ladder).

  ## Examples

      iex> Kazi.Context.Escalation.config(threshold: 1).threshold
      1
      iex> Kazi.Context.Escalation.config(enabled: false).enabled
      false
      iex> Kazi.Context.Escalation.config(nil).threshold
      2
  """
  @spec config(Config.t() | keyword() | map() | nil) :: Config.t()
  def config(%Config{} = config), do: config

  def config(nil) do
    config(Application.get_env(:kazi, :context_escalation, []))
  end

  def config(overrides) when is_list(overrides) or is_map(overrides) do
    overrides = Map.new(overrides)

    %Config{
      enabled: boolean_or(overrides[:enabled], true),
      threshold: pos_int_or(overrides[:threshold], default_threshold()),
      min_tier: tier_or(overrides[:min_tier], 0),
      max_tier: tier_or(overrides[:max_tier], 4),
      stop_rule: boolean_or(overrides[:stop_rule], true)
    }
  end

  def config(_), do: %Config{}

  @doc """
  Seed the escalation state from the `base_tier` (the operator/goal-selected tier,
  `Kazi.Context.Tier.resolve/1`) and a resolved `Config`. The active tier starts
  AT the base (the default tier 1 absent any opt), so a run with no non-progress
  is byte-identical to the pre-T36.4 loop.

  ## Examples

      iex> s = Kazi.Context.Escalation.init(1, Kazi.Context.Escalation.config([]))
      iex> Kazi.Context.Escalation.tier(s)
      1
  """
  @spec init(Tier.t(), Config.t()) :: State.t()
  def init(base_tier, %Config{} = config) do
    base = clamp(Tier.normalize(base_tier), config)
    %State{tier: base, base_tier: base}
  end

  @doc """
  The active context tier the next dispatch should assemble at.

  ## Examples

      iex> Kazi.Context.Escalation.init(2, Kazi.Context.Escalation.config([]))
      ...> |> Kazi.Context.Escalation.tier()
      2
  """
  @spec tier(State.t()) :: Tier.t()
  def tier(%State{tier: tier}), do: tier

  @doc """
  Fold one observation's `signal` into the next state + decision (ADR-0047 §2/§4).

    * **Progress** (`progressing?: true`) — the current tier is paying off: reset
      the non-progress streak and any pending stop-rule assessment, KEEP the tier
      (escalation only ever climbs; it never de-escalates a working tier).
    * **Non-progress** (`progressing?: false`):
      * If a prior escalation is under assessment (`awaiting`) and the stop rule is
        enabled and this iteration cost MORE than the rung below
        (`cost > baseline_cost`) without progressing → **revert** one tier and stop
        climbing for the run (the bump was net-negative, ADR-0047 §4).
      * Otherwise, increment the streak; once it reaches `threshold` and the tier
        is below `max_tier` and climbing has not been stopped → **escalate** one
        tier, capturing this iteration's cost as the stop-rule baseline.
      * Else → **hold**.

  Disabled (`enabled: false`) always holds at the base tier.

  Returns `{next_state, decision}`.
  """
  @spec step(State.t(), Config.t(), signal()) :: {State.t(), decision()}
  def step(%State{} = state, %Config{enabled: false}, _signal), do: {state, :hold}

  def step(%State{} = state, %Config{}, %{progressing?: true}) do
    # Progress: the current tier is working. Clear the streak + any pending
    # stop-rule assessment; hold the tier (never de-escalate a paying tier).
    {%State{state | nonprogress: 0, awaiting: false, baseline_cost: nil}, :hold}
  end

  def step(%State{} = state, %Config{} = config, %{progressing?: false} = signal) do
    cost = Map.get(signal, :cost, 0)

    cond do
      # Stop rule (ADR-0047 §4): the rung we just escalated to did NOT progress and
      # cost more than the rung below — net-negative. Revert and stop climbing.
      config.stop_rule and state.awaiting and cost_rose?(cost, state.baseline_cost) ->
        {%State{
           state
           | tier: state.escalated_from,
             awaiting: false,
             baseline_cost: nil,
             escalated_from: nil,
             climbing_stopped: true,
             nonprogress: 0
         }, {:revert, state.tier, state.escalated_from}}

      true ->
        # Either not under assessment, or the escalation was cost-neutral (not
        # net-negative): close the assessment window and (maybe) escalate again on
        # a sustained non-progress streak.
        state = %State{state | awaiting: false, baseline_cost: nil}
        n = state.nonprogress + 1

        if escalatable?(state, config, n) do
          {%State{
             state
             | tier: state.tier + 1,
               escalated_from: state.tier,
               awaiting: true,
               baseline_cost: cost,
               nonprogress: 0
           }, {:escalate, state.tier, state.tier + 1}}
        else
          {%State{state | nonprogress: n}, :hold}
        end
    end
  end

  def step(%State{} = state, %Config{} = _config, _signal), do: {state, :hold}

  # Whether a non-progress streak of `n` warrants stepping up: climbing not stopped,
  # the streak has reached the configured threshold, and there is a rung left.
  @spec escalatable?(State.t(), Config.t(), non_neg_integer()) :: boolean()
  defp escalatable?(%State{climbing_stopped: true}, _config, _n), do: false

  defp escalatable?(%State{tier: tier}, %Config{threshold: threshold, max_tier: max_tier}, n) do
    n >= threshold and tier < max_tier
  end

  @spec cost_rose?(number(), number() | nil) :: boolean()
  defp cost_rose?(cost, baseline) when is_number(cost) and is_number(baseline),
    do: cost > baseline

  defp cost_rose?(_cost, _baseline), do: false

  # Clamp a tier into the config's [min_tier, max_tier] window.
  @spec clamp(Tier.t(), Config.t()) :: Tier.t()
  defp clamp(tier, %Config{min_tier: min_tier, max_tier: max_tier}) do
    tier |> max(min_tier) |> min(max_tier)
  end

  defp boolean_or(value, _default) when is_boolean(value), do: value
  defp boolean_or(_value, default), do: default

  defp pos_int_or(value, _default) when is_integer(value) and value > 0, do: value
  defp pos_int_or(_value, default), do: default

  defp tier_or(value, default) do
    if Tier.valid?(value), do: value, else: default
  end
end
