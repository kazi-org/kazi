defmodule Kazi.ReadModel.ProposedMemoryTest do
  @moduledoc """
  Tier 2 — real SQLite boundary for the ADR-0063 Slice 3 proposed-memory
  store: `propose_memory/1`'s idempotent-by-fingerprint insert,
  `list_proposed_memories/1`'s status filter, and
  `transition_proposed_memory/2`'s approve/reject state machine.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel
  alias Kazi.ReadModel.ProposedMemory
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        proposal_ref: "mem-#{System.unique_integer([:positive])}",
        fingerprint: "fp-#{System.unique_integer([:positive])}",
        class: "landmine",
        content: "predicate a repeated 3 times without change",
        goal_ref: "goal-#{System.unique_integer([:positive])}",
        target_doc: "docs/lore.md",
        status: "proposed"
      },
      overrides
    )
  end

  test "propose_memory/1 inserts a new row" do
    assert {:ok, %ProposedMemory{} = row} = ReadModel.propose_memory(attrs())
    assert row.status == "proposed"
    assert row.class == "landmine"
  end

  test "propose_memory/1 is idempotent by fingerprint -- a repeat proposal is not re-inserted" do
    fingerprint = "fp-shared-#{System.unique_integer([:positive])}"
    goal_ref = "goal-shared-#{System.unique_integer([:positive])}"

    assert {:ok, %ProposedMemory{id: id, proposal_ref: proposal_ref}} =
             ReadModel.propose_memory(attrs(%{fingerprint: fingerprint, goal_ref: goal_ref}))

    assert {:ok, %ProposedMemory{id: ^id, proposal_ref: ^proposal_ref}} =
             ReadModel.propose_memory(
               attrs(%{
                 fingerprint: fingerprint,
                 goal_ref: goal_ref,
                 proposal_ref: "mem-different-ref"
               })
             )

    matches =
      ReadModel.list_proposed_memories()
      |> Enum.filter(&(&1.goal_ref == goal_ref))

    assert length(matches) == 1
  end

  test "propose_memory/1 does not re-propose a fingerprint already rejected" do
    fingerprint = "fp-rejected-#{System.unique_integer([:positive])}"
    {:ok, row} = ReadModel.propose_memory(attrs(%{fingerprint: fingerprint}))
    {:ok, rejected} = ReadModel.transition_proposed_memory(row.proposal_ref, "rejected")

    assert {:ok, %ProposedMemory{status: "rejected", id: id}} =
             ReadModel.propose_memory(attrs(%{fingerprint: fingerprint}))

    assert id == rejected.id
  end

  test "list_proposed_memories/1 filters by status" do
    {:ok, proposed} = ReadModel.propose_memory(attrs())
    {:ok, to_approve} = ReadModel.propose_memory(attrs())
    {:ok, _approved} = ReadModel.transition_proposed_memory(to_approve.proposal_ref, "approved")

    proposed_refs =
      ReadModel.list_proposed_memories(status: "proposed") |> Enum.map(& &1.proposal_ref)

    assert proposed.proposal_ref in proposed_refs
    refute to_approve.proposal_ref in proposed_refs

    approved_refs =
      ReadModel.list_proposed_memories(status: "approved") |> Enum.map(& &1.proposal_ref)

    assert to_approve.proposal_ref in approved_refs
  end

  test "transition_proposed_memory/2 approves a proposed row" do
    {:ok, row} = ReadModel.propose_memory(attrs())

    assert {:ok, %ProposedMemory{status: "approved"}} =
             ReadModel.transition_proposed_memory(row.proposal_ref, "approved")
  end

  test "transition_proposed_memory/2 refuses a transition off a terminal state" do
    {:ok, row} = ReadModel.propose_memory(attrs())
    {:ok, _} = ReadModel.transition_proposed_memory(row.proposal_ref, "rejected")

    assert {:error, {:invalid_transition, "rejected", "approved"}} =
             ReadModel.transition_proposed_memory(row.proposal_ref, "approved")
  end

  test "transition_proposed_memory/2 on an unknown ref is a clean error" do
    assert {:error, :not_found} =
             ReadModel.transition_proposed_memory("mem-does-not-exist", "approved")
  end
end
