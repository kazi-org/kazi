defmodule Kazi.Memory.HarvestTest do
  @moduledoc """
  ADR-0063: `Kazi.Memory.Harvest` detects a repeated, no-progress dispatch
  approach from a goal's own recorded iteration log and proposes it as a
  landmine candidate -- deterministically, idempotently, and WITHOUT ever
  touching the corpus itself (the write path stays gated behind a human
  `kazi memory approve`, `Kazi.Memory.Promote`).

  Harvesting runs controller-side only, never from the harness/dispatch path
  (`lib/kazi/harness.ex` / `lib/kazi/actions/` name no `Harvest` reference) --
  the SAME structural guarantee that lets corpus files stay eligible
  `[enforcement] read_only_paths` (ADR-0042) during a run: the inner agent has
  no path to influence what gets proposed, and the corpus itself is never
  written mid-run.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Action, PredicateResult, PredicateVector}
  alias Kazi.Memory.Harvest
  alias Kazi.ReadModel
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp fail_vector, do: PredicateVector.new(%{a: PredicateResult.fail(%{output: "boom"})})

  defp record_repeated_dispatch(goal_ref, count) do
    for index <- 0..(count - 1) do
      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: index,
          predicate_vector: fail_vector(),
          converged: false,
          action:
            Action.new(:dispatch_agent,
              params: %{failing: [:a], evidence: %{a: "boom: undefined function foo/0"}}
            ),
          observed_at: DateTime.utc_now()
        })
    end
  end

  test "proposes a landmine after the same approach repeats at/above the threshold" do
    goal_ref = "harvest-goal-#{System.unique_integer([:positive])}"
    record_repeated_dispatch(goal_ref, 3)

    proposals = Harvest.harvest("run-1", goal_ref, %{outcome: :stopped, reason: :stuck})

    assert [proposal] = proposals
    assert proposal.class == "landmine"
    assert proposal.goal_ref == goal_ref
    assert proposal.status == "proposed"
    assert proposal.evidence["iterations"] == [0, 1, 2]
    assert proposal.evidence["failing"] == ["a"]
    assert proposal.content =~ goal_ref
  end

  test "below the repeat threshold, nothing is proposed" do
    goal_ref = "harvest-goal-#{System.unique_integer([:positive])}"
    record_repeated_dispatch(goal_ref, 2)

    assert Harvest.harvest("run-1", goal_ref, %{outcome: :stopped, reason: :stuck}) == []
  end

  test "a converged outcome harvests nothing -- there is nothing to warn about" do
    goal_ref = "harvest-goal-#{System.unique_integer([:positive])}"
    record_repeated_dispatch(goal_ref, 5)

    assert Harvest.harvest("run-1", goal_ref, %{outcome: :converged, reason: nil}) == []
  end

  test "harvesting the same facts twice is idempotent -- never a duplicate proposal" do
    goal_ref = "harvest-goal-#{System.unique_integer([:positive])}"
    record_repeated_dispatch(goal_ref, 4)

    first = Harvest.harvest("run-1", goal_ref, %{outcome: :over_budget, reason: :max_iterations})
    second = Harvest.harvest("run-2", goal_ref, %{outcome: :over_budget, reason: :max_iterations})

    assert length(first) == 1
    assert Enum.map(first, & &1.id) == Enum.map(second, & &1.id)

    assert length(ReadModel.list_proposed_memories() |> Enum.filter(&(&1.goal_ref == goal_ref))) ==
             1
  end

  test "harvest is READ-ONLY with respect to the corpus -- it never writes docs/lore.md or docs/devlog.md" do
    lore_before = File.read!("docs/lore.md")
    devlog_before = File.read!("docs/devlog.md")

    goal_ref = "harvest-goal-#{System.unique_integer([:positive])}"
    record_repeated_dispatch(goal_ref, 5)
    Harvest.harvest("run-1", goal_ref, %{outcome: :stopped, reason: :stuck})

    assert File.read!("docs/lore.md") == lore_before
    assert File.read!("docs/devlog.md") == devlog_before
  end
end
