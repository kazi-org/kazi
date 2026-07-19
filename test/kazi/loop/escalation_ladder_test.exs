defmodule Kazi.Loop.EscalationLadderTest do
  @moduledoc """
  T45.7 (ADR-0056 decision 5): the `[escalation]` MODEL ladder. On a `stuck`
  (or `over_budget`) verdict on the same failing predicate set, the loop
  re-dispatches the SAME goal at the NEXT model in the declared ladder instead of
  terminating, capped at the ladder's end. No `[escalation]` block = single-model
  behavior, byte-identical.

  Real loop-iteration boundary (Tier 2): a recording harness captures the model
  used on every dispatch, so we assert the ACTUAL model sequence across rungs.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # A provider whose predicate is ALWAYS :fail unless a shared "fixed?" flag flips
  # true — so the failing set is stable (the T30.3 signal) and the loop walks the
  # ladder, or converges when a rung flips the flag.
  defmodule FlaggableProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      fixed_pid = context.goal.metadata[:fixed_pid]

      if fixed_pid && Agent.get(fixed_pid, & &1) do
        PredicateResult.pass(%{id: id})
      else
        PredicateResult.fail(%{id: id, status: :fail})
      end
    end
  end

  # Records the model of every dispatch, and (optionally) flips the shared fixed?
  # flag when dispatched with a chosen model — so a test can make the goal converge
  # AT a specific rung.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      model = Keyword.get(opts, :model)
      goal_id = prompt |> :binary.split("goal=") |> List.last() |> :binary.split(" ") |> hd()
      Agent.update(Keyword.fetch!(opts, :record_pid), &[{model, goal_id} | &1])

      case Keyword.get(opts, :fix_on_model) do
        ^model when model != nil ->
          Agent.update(Keyword.fetch!(opts, :fixed_pid), fn _ -> true end)

        _ ->
          :ok
      end

      {:ok, %{output: "ok"}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp start_loop(escalation, adapter_extra, opts) do
    {:ok, record} = Agent.start_link(fn -> [] end)
    {:ok, fixed} = Agent.start_link(fn -> false end)

    goal =
      Goal.new("esc-goal",
        predicates: [Predicate.new(:code, :tests)],
        escalation: escalation,
        metadata: %{fixed_pid: fixed}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        [
          goal: goal,
          providers: %{tests: FlaggableProvider},
          harness: RecordingHarness,
          integrate: NoopIntegrate,
          deploy: NoopDeploy,
          reobserve_interval_ms: 1,
          flake_max_retries: 0,
          adapter_opts: [record_pid: record, fixed_pid: fixed] ++ adapter_extra
        ] ++ opts
      )

    {:ok, result} = Kazi.Loop.await(loop, 5_000)
    dispatches = record |> Agent.get(& &1) |> Enum.reverse()
    {result, models(dispatches), goal_ids(dispatches)}
  end

  # The model sequence dispatched, oldest-first, deduped to distinct RUNGS
  # (consecutive same-model dispatches within a rung collapse to one entry).
  defp models(dispatches), do: dispatches |> Enum.map(&elem(&1, 0)) |> Enum.dedup()

  # The distinct goal ids seen across all dispatches — proves it is ONE goal
  # escalating, not several.
  defp goal_ids(dispatches), do: dispatches |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  test "a stuck goal with a 3-rung ladder walks rung 1 -> 2 -> 3 then terminates stuck" do
    {result, models, goal_ids} =
      start_loop(
        %{ladder: ["m-haiku", "m-sonnet", "m-opus"], max_rungs: nil},
        [],
        stuck_iterations: 2
      )

    # It escalated through every rung, in order, then the terminal stuck stood.
    assert models == ["m-haiku", "m-sonnet", "m-opus"]
    assert result.outcome == :stopped
    assert result.reason == :stuck
    # One goal escalating, not three separate goals.
    assert goal_ids == ["esc-goal"]
  end

  test "converged at a rung stops the ladder immediately (no further escalation)" do
    # The harness fixes the goal when dispatched with the SECOND rung's model, so
    # the goal converges at rung 2 and rung 3 (m-opus) is never used.
    {result, models, _goal_ids} =
      start_loop(
        %{ladder: ["m-haiku", "m-sonnet", "m-opus"], max_rungs: nil},
        [fix_on_model: "m-sonnet"],
        stuck_iterations: 2
      )

    assert result.outcome == :converged
    assert "m-haiku" in models
    assert "m-sonnet" in models
    refute "m-opus" in models
  end

  test "NO [escalation] block never re-dispatches — single model, stuck as before" do
    {result, models, _goal_ids} =
      start_loop(
        # default: empty ladder = no escalation
        Goal.default_escalation(),
        [model: "solo"],
        stuck_iterations: 2
      )

    # Only the one caller-pinned model was ever used — the ladder never engaged.
    assert models == ["solo"]
    assert result.outcome == :stopped
    assert result.reason == :stuck
  end

  test "max_rungs caps the ladder below its declared length" do
    {result, models, _goal_ids} =
      start_loop(
        %{ladder: ["m-haiku", "m-sonnet", "m-opus"], max_rungs: 2},
        [],
        stuck_iterations: 2
      )

    # Only two rungs are used despite a 3-model ladder; then the terminal stands.
    assert models == ["m-haiku", "m-sonnet"]
    assert result.outcome == :stopped
    assert result.reason == :stuck
  end
end
