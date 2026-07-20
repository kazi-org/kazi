defmodule Kazi.Velocity.KpisTest do
  @moduledoc """
  T67.4 (ADR-0079 §4): the velocity KPI queries. Seeds the T67.2 `delivery_events`
  and T67.3 `session_counters` projections plus the run registry, then pins each
  KPI's arithmetic — delivered/day, tokens-per-delivered-task, stuck ratio (per
  agent AND per model), rescue count, and the claim→merge lead-time p50/p90 —
  including the empty and one-sample edges (honest `nil`, no division blow-up).

  Two structural guards: the public `%Kpis{}` struct (recursively) carries NO
  ETA/estimate/projected-completion field (the type-layer negative assertion), and
  the per-model stuck split reconciles with `Kazi.Economy.History`'s finished-run
  totals on the same fixture (one cost/outcome truth, not a fork).
  """
  use ExUnit.Case, async: false

  alias Kazi.Economy.History
  alias Kazi.ReadModel.{DeliveryEvent, Run, SessionCounters}
  alias Kazi.Repo
  alias Kazi.Velocity.Kpis

  @now ~U[2026-07-18 12:00:00.000000Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # -- fixture seeders --------------------------------------------------------

  defp days_ago(n), do: DateTime.add(@now, -n * 86_400, :second)

  defp seed_tick(attrs) do
    sha = "sha-#{System.unique_integer([:positive])}"

    base = %{
      kind: "task_tick",
      task_id: "T#{System.unique_integer([:positive])}",
      epic: "E67",
      merge_commit_sha: sha,
      dedup_key: "task_tick|#{sha}"
    }

    %DeliveryEvent{}
    |> DeliveryEvent.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp seed_counters(attrs) do
    %SessionCounters{}
    |> SessionCounters.changeset(attrs)
    |> Repo.insert!()
  end

  defp seed_run(attrs) do
    run_id = "run-#{System.unique_integer([:positive])}"

    base = %{
      run_id: run_id,
      pid: "#PID<0.1.0>",
      workspace: "/tmp/ws",
      goal_ref: "goal-#{run_id}",
      started_at: @now,
      heartbeat_at: @now
    }

    %Run{}
    |> Run.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  # Recursively assert no struct field name contains a completion-estimate token.
  defp assert_no_forbidden_keys(%_struct{} = value, forbidden) do
    value
    |> Map.from_struct()
    |> Enum.each(fn {k, v} ->
      key = to_string(k)

      refute Enum.any?(forbidden, &String.contains?(key, &1)),
             "forbidden completion-estimate key present: #{key}"

      assert_no_forbidden_keys(v, forbidden)
    end)
  end

  defp assert_no_forbidden_keys(values, forbidden) when is_list(values) do
    Enum.each(values, &assert_no_forbidden_keys(&1, forbidden))
  end

  defp assert_no_forbidden_keys(_leaf, _forbidden), do: :ok

  # -- delivered / day --------------------------------------------------------

  describe "delivered per day" do
    test "fleet and per-agent rates over a trailing window; out-of-window ticks excluded" do
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(3)})
      seed_tick(%{session_uuid: "sess-b", merged_at: days_ago(2)})
      # Outside the 7d window — must not count.
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(30)})

      kpis = Kpis.compute(window_days: 7, now: @now)

      assert kpis.delivered_count == 3
      assert kpis.delivered_per_day == Float.round(3 / 7, 2)

      by_uuid = Map.new(kpis.per_agent, &{&1.session_uuid, &1})
      assert by_uuid["sess-a"].delivered_count == 2
      assert by_uuid["sess-a"].delivered_per_day == Float.round(2 / 7, 2)
      assert by_uuid["sess-b"].delivered_count == 1
    end

    test "a tick with no merged_at counts on its Done: date; an out-of-window date does not" do
      seed_tick(%{session_uuid: "sess-a", merged_at: nil, done_on: ~D[2026-07-17]})
      seed_tick(%{session_uuid: "sess-a", merged_at: nil, done_on: ~D[2026-06-01]})

      kpis = Kpis.compute(window_days: 7, now: @now)
      assert kpis.delivered_count == 1
    end
  end

  # -- tokens per delivered task ---------------------------------------------

  describe "tokens per delivered task" do
    test "ratio of a session's cumulative tokens to its delivered tasks" do
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(2)})

      seed_counters(%{
        session_uuid: "sess-a",
        input_tokens: 600,
        output_tokens: 400,
        cached_input_tokens: nil
      })

      kpis = Kpis.compute(window_days: 7, now: @now)
      agent = Enum.find(kpis.per_agent, &(&1.session_uuid == "sess-a"))
      # (600 + 400) / 2 delivered = 500.0
      assert agent.tokens_per_delivered_task == 500.0
      # Fleet: same tokens over 2 fleet deliveries.
      assert kpis.tokens_per_delivered_task == 500.0
    end

    test "honest nil (never 0) when the session exposed no token counters" do
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})

      seed_counters(%{
        session_uuid: "sess-a",
        input_tokens: nil,
        output_tokens: nil,
        cached_input_tokens: nil,
        cache_write_tokens: nil,
        reasoning_tokens: nil
      })

      kpis = Kpis.compute(window_days: 7, now: @now)
      agent = Enum.find(kpis.per_agent, &(&1.session_uuid == "sess-a"))
      assert agent.tokens_per_delivered_task == nil
    end
  end

  # -- stuck ratio ------------------------------------------------------------

  describe "stuck ratio" do
    test "per agent and per model over terminal verdicts" do
      # sess-a on model X: 1 converged, 1 stuck, 1 over_budget => 2/3 stuck.
      seed_run(%{
        harness_session_id: "sess-a",
        model: "claude-x",
        status: "converged",
        finished_at: @now
      })

      seed_run(%{
        harness_session_id: "sess-a",
        model: "claude-x",
        status: "stuck",
        finished_at: @now
      })

      seed_run(%{
        harness_session_id: "sess-a",
        model: "claude-x",
        status: "over_budget",
        finished_at: @now
      })

      # sess-b on model Y: 1 converged => 0/1.
      seed_run(%{
        harness_session_id: "sess-b",
        model: "claude-y",
        status: "converged",
        finished_at: @now
      })

      kpis = Kpis.compute(window_days: 7, now: @now)

      by_uuid = Map.new(kpis.per_agent, &{&1.session_uuid, &1})
      assert by_uuid["sess-a"].stuck_ratio == Float.round(2 / 3, 3)
      assert by_uuid["sess-b"].stuck_ratio == 0.0

      by_model = Map.new(kpis.stuck_by_model, &{&1.model, &1})
      assert by_model["claude-x"].stuck_ratio == Float.round(2 / 3, 3)
      assert by_model["claude-x"].terminal_count == 3
      assert by_model["claude-y"].stuck_ratio == 0.0
    end

    test "honest nil for a session/model with no terminal run" do
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})

      kpis = Kpis.compute(window_days: 7, now: @now)
      agent = Enum.find(kpis.per_agent, &(&1.session_uuid == "sess-a"))
      assert agent.stuck_ratio == nil
    end
  end

  # -- rescue count -----------------------------------------------------------

  describe "rescue count" do
    test "counts lanes whose converged run's session differs from the first claimant" do
      # Rescued lane: sess-a claimed first, sess-b converged it.
      seed_run(%{
        goal_ref: "goal-rescue",
        harness_session_id: "sess-a",
        started_at: days_ago(2),
        status: "stuck",
        finished_at: days_ago(1)
      })

      seed_run(%{
        goal_ref: "goal-rescue",
        harness_session_id: "sess-b",
        started_at: days_ago(1),
        status: "converged",
        finished_at: @now
      })

      # Self-closed lane: same session claimed and converged => not a rescue.
      seed_run(%{
        goal_ref: "goal-self",
        harness_session_id: "sess-c",
        started_at: days_ago(2),
        status: "converged",
        finished_at: @now
      })

      kpis = Kpis.compute(window_days: 7, now: @now)
      assert kpis.rescue_count == 1
    end
  end

  # -- claim -> merge lead time ----------------------------------------------

  describe "claim -> merge lead-time distribution" do
    test "p50/p90 over deliveries joined to their claiming run's started_at" do
      # Three deliveries by sess-a, each claimed at started_at, merged later.
      seed_run(%{
        harness_session_id: "sess-a",
        started_at: days_ago(5),
        status: "converged",
        finished_at: days_ago(1)
      })

      for {merged, _label} <- [{days_ago(4), :fast}, {days_ago(3), :mid}, {days_ago(1), :slow}] do
        seed_tick(%{session_uuid: "sess-a", merged_at: merged})
      end

      kpis = Kpis.compute(window_days: 30, now: @now)
      # Lead seconds from the day-5 claim: 1d, 2d, 4d.
      assert kpis.lead_time.n == 3
      assert kpis.lead_time.p50_s == 2 * 86_400
      assert kpis.lead_time.p90_s == 4 * 86_400
    end

    test "no joinable claim contributes no sample (honest nil distribution when empty)" do
      seed_tick(%{session_uuid: "orphan", merged_at: days_ago(1)})

      kpis = Kpis.compute(window_days: 7, now: @now)
      assert kpis.lead_time.n == 0
      assert kpis.lead_time.p50_s == nil
      assert kpis.lead_time.p90_s == nil
    end
  end

  # -- empty / one-sample edges ----------------------------------------------

  describe "insufficient-data edges" do
    test "an empty read-model yields honest nils, never a division blow-up" do
      kpis = Kpis.compute(window_days: 7, now: @now)

      assert kpis.delivered_count == 0
      assert kpis.delivered_per_day == 0.0
      assert kpis.tokens_per_delivered_task == nil
      assert kpis.rescue_count == 0
      assert kpis.per_agent == []
      assert kpis.stuck_by_model == []
      assert kpis.lead_time == %Kpis.Distribution{p50_s: nil, p90_s: nil, n: 0}
    end

    test "a one-sample lead-time distribution reports that single value at both percentiles" do
      seed_run(%{
        harness_session_id: "sess-a",
        started_at: days_ago(3),
        status: "converged",
        finished_at: @now
      })

      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})

      kpis = Kpis.compute(window_days: 7, now: @now)
      assert kpis.lead_time.n == 1
      assert kpis.lead_time.p50_s == 2 * 86_400
      assert kpis.lead_time.p90_s == 2 * 86_400
    end
  end

  # -- structural guards ------------------------------------------------------

  describe "no ETA/estimate field exists (type-layer negative assertion)" do
    test "the public struct and its nested structs carry no completion-estimate field" do
      seed_tick(%{session_uuid: "sess-a", merged_at: days_ago(1)})
      seed_counters(%{session_uuid: "sess-a", input_tokens: 10})

      seed_run(%{
        harness_session_id: "sess-a",
        model: "claude-x",
        status: "stuck",
        finished_at: @now
      })

      kpis = Kpis.compute(window_days: 7, now: @now)

      forbidden =
        ~w(eta estimate estimated projected projection completion complete finish forecast deadline due_date remaining)

      assert_no_forbidden_keys(kpis, forbidden)
    end
  end

  describe "reconciliation with kazi economy (one cost/outcome truth)" do
    test "per-model terminal counts reconcile with History finished-run totals" do
      seed_run(%{
        model: "claude-sonnet-5",
        status: "converged",
        finished_at: @now,
        predicate_count: 3
      })

      seed_run(%{
        model: "claude-sonnet-5",
        status: "stuck",
        finished_at: @now,
        predicate_count: 3
      })

      seed_run(%{
        model: "claude-opus-4-8",
        status: "over_budget",
        finished_at: @now,
        predicate_count: 5
      })

      # A still-running row (no finished_at) must be excluded by BOTH surfaces.
      seed_run(%{model: "claude-opus-4-8", status: "running", finished_at: nil})

      kpis = Kpis.compute(window_days: 7, now: @now)
      %{groups: groups} = History.aggregate()

      velocity_terminal = Enum.sum(Enum.map(kpis.stuck_by_model, & &1.terminal_count))
      economy_terminal = Enum.sum(Enum.map(groups, & &1.n))

      assert velocity_terminal == economy_terminal
      assert velocity_terminal == 3
    end
  end

  describe "per-agent delivered attribution (#1651)" do
    # An agent's 0 is a MEASUREMENT only when attribution actually works for the
    # window. Rendering "0.0 /day" over deliveries that carry no session_uuid
    # asserts "this agent delivered nothing" when the truth is "we cannot tell" —
    # the ADR-0046 fabricated-measurement failure this epic exists to prevent.

    test "unattributable: deliveries exist but carry no session_uuid -> nil, never 0.0" do
      seed_counters(%{session_uuid: "agent-a", machine: "m", message_count: 1})
      # Deliveries in-window with NO session_uuid — the live shape on a
      # trailer-stripped repo, where a git-derived tick has no goal_ref.
      seed_tick(%{merged_at: days_ago(1), session_uuid: nil})
      seed_tick(%{merged_at: days_ago(2), session_uuid: nil})

      [agent] = Kpis.compute(now: @now).per_agent

      # per_day asserted FIRST so a pre-fix run shows the fabricated value itself.
      assert agent.delivered_per_day == nil
      assert agent.delivered_count == nil
      assert agent.delivered_attribution == :unattributable
    end

    test "honest zero: every delivery IS attributed, so an agent with none really delivered 0" do
      seed_counters(%{session_uuid: "agent-a", machine: "m", message_count: 1})
      seed_counters(%{session_uuid: "agent-b", machine: "m", message_count: 1})
      # Fully attributed corpus: agent-a landed one, agent-b landed nothing.
      seed_tick(%{merged_at: days_ago(1), session_uuid: "agent-a"})

      agents = Kpis.compute(now: @now).per_agent
      b = Enum.find(agents, &(&1.session_uuid == "agent-b"))

      # Guards against over-correcting into "never show a zero" — this 0 is real.
      assert b.delivered_attribution == :ok
      assert b.delivered_count == 0
      assert b.delivered_per_day == 0.0
    end

    test "MIXED: a partially-working join degrades per ROW, never collapsing to the worst case" do
      seed_counters(%{session_uuid: "agent-a", machine: "m", message_count: 1})
      seed_counters(%{session_uuid: "agent-b", machine: "m", message_count: 1})
      # agent-a has an attributed delivery; a second delivery is unattributed.
      seed_tick(%{merged_at: days_ago(1), session_uuid: "agent-a"})
      seed_tick(%{merged_at: days_ago(2), session_uuid: nil})

      agents = Kpis.compute(now: @now).per_agent
      a = Enum.find(agents, &(&1.session_uuid == "agent-a"))
      b = Enum.find(agents, &(&1.session_uuid == "agent-b"))

      # The agent WITH an attributed delivery still reports its real numbers...
      assert a.delivered_count == 1
      assert a.delivered_per_day > 0
      # ...but marked a FLOOR, because an unattributed delivery in the same
      # window may also be theirs (#1651 follow-up).
      assert a.delivered_attribution == :partial

      # ...in the SAME render where the one that cannot be measured says so.
      assert b.delivered_per_day == nil
      assert b.delivered_attribution == :unattributable
    end

    test "partial: a positive count beside unattributed deliveries is a FLOOR, not a measurement" do
      seed_counters(%{session_uuid: "agent-a", machine: "m", message_count: 1})
      seed_tick(%{merged_at: days_ago(1), session_uuid: "agent-a"})
      seed_tick(%{merged_at: days_ago(2), session_uuid: nil})

      [a] = Enum.filter(Kpis.compute(now: @now).per_agent, &(&1.session_uuid == "agent-a"))

      # Real observations are kept — a floor is still built from what we saw.
      assert a.delivered_count == 1
      assert a.delivered_per_day > 0
      # But flagged, so the render can say "≥" rather than assert exactness.
      assert a.delivered_attribution == :partial
    end

    test "the floor qualifier DISAPPEARS once attribution is complete" do
      seed_counters(%{session_uuid: "agent-a", machine: "m", message_count: 1})
      # Every delivery in the window is attributed -> nothing unknown remains.
      seed_tick(%{merged_at: days_ago(1), session_uuid: "agent-a"})
      seed_tick(%{merged_at: days_ago(2), session_uuid: "agent-a"})

      [a] = Enum.filter(Kpis.compute(now: @now).per_agent, &(&1.session_uuid == "agent-a"))

      # This is the guard against ambient hedging: the qualifier must carry
      # information, not become decoration an operator learns to ignore.
      assert a.delivered_attribution == :ok
      assert a.delivered_count == 2
    end
  end
end
