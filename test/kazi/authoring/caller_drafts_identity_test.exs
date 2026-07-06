defmodule Kazi.Authoring.CallerDraftsIdentityTest do
  @moduledoc """
  Regression for #787/#793: caller-drafts hardcoded `goal_id` to
  `"caller-supplied-predicates"` (derived from the idea placeholder, never the
  payload), so the proposal store upserted onto ONE slot regardless of the
  payload's own identity — a second, unrelated caller-drafts proposal silently
  overwrote the first, including resetting an already-`approved` proposal back
  to `proposed` with different predicates and destroying its audit trail.

  `Kazi.Authoring.propose/2` now derives BOTH the goal id and the
  `proposal_ref` from the payload's own `"id"` (verbatim) or `"name"` (slugged)
  when a `:proposal` is supplied — never the idea text — so two differently
  identified payloads coexist, and replacing an `approved` proposal is refused
  unless the caller opts in via `replace: true`.
  """
  use ExUnit.Case, async: false

  alias Kazi.Authoring
  alias Kazi.Authoring.Draft
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # A stub that RAISES if driven — proves caller-drafts never spawns a harness.
  defmodule ExplodingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts),
      do: raise("caller-drafts must not drive the harness")
  end

  describe "#787: distinct payloads coexist instead of colliding" do
    test "two differently-named caller-drafts payloads yield DISTINCT proposal_refs" do
      payload_a = %{
        "name" => "goal-a",
        "predicates" => [%{"id" => "a", "provider" => "test_runner"}]
      }

      payload_b = %{
        "name" => "goal-b",
        "predicates" => [%{"id" => "b", "provider" => "test_runner"}]
      }

      assert {:ok, %Draft{} = draft_a} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload_a
               )

      assert {:ok, %Draft{} = draft_b} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload_b
               )

      refute draft_a.proposal_ref == draft_b.proposal_ref
      refute draft_a.goal.id == draft_b.goal.id

      # BOTH proposals persist -- neither destroyed the other.
      assert Repo.aggregate(ProposedGoal, :count) == 2
      assert %ProposedGoal{} = Repo.get_by(ProposedGoal, proposal_ref: draft_a.proposal_ref)
      assert %ProposedGoal{} = Repo.get_by(ProposedGoal, proposal_ref: draft_b.proposal_ref)
    end

    test "an explicit top-level payload \"id\" is honored (not ignored)" do
      payload = %{
        "id" => "my-goal-id",
        "predicates" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, %Draft{goal: goal} = draft} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert goal.id == "my-goal-id"
      assert draft.proposal_ref =~ "my-goal-id"
    end

    test "approving goal-a survives a later, differently-named goal-b proposal" do
      payload_a = %{
        "name" => "goal-a",
        "predicates" => [%{"id" => "a", "provider" => "test_runner"}]
      }

      payload_b = %{
        "name" => "goal-b",
        "predicates" => [%{"id" => "b", "provider" => "test_runner"}]
      }

      assert {:ok, draft_a} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload_a
               )

      assert {:ok, %Kazi.Goal{}} = Authoring.approve(draft_a.proposal_ref)

      assert {:ok, _draft_b} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload_b
               )

      # goal-a's approval + predicates are untouched by the unrelated goal-b draft.
      assert %ProposedGoal{status: "approved", goal: stored} =
               Repo.get_by(ProposedGoal, proposal_ref: draft_a.proposal_ref)

      assert {:ok, rehydrated} = Kazi.Goal.Loader.from_map(stored)
      assert Enum.map(rehydrated.predicates, & &1.id) == ["a"]
    end
  end

  describe "#793: replacing an approved proposal is refused, not silent" do
    test "re-proposing onto the SAME explicit id after approval is refused by default" do
      payload = %{
        "id" => "my-goal-id",
        "predicates" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, draft} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert {:ok, %Kazi.Goal{}} = Authoring.approve(draft.proposal_ref)

      other_payload = %{
        "id" => "my-goal-id",
        "predicates" => [%{"id" => "different", "provider" => "test_runner"}]
      }

      assert {:error, {:proposal_locked, ref, "approved"}} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: other_payload
               )

      assert ref == draft.proposal_ref

      # The approved row is untouched -- still approved, still the ORIGINAL
      # predicates, not silently reset to "proposed" with the new ones.
      assert %ProposedGoal{status: "approved", goal: stored} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)

      assert {:ok, rehydrated} = Kazi.Goal.Loader.from_map(stored)
      assert Enum.map(rehydrated.predicates, & &1.id) == ["p"]
    end

    test "an explicit replace: true opts into overwriting an approved proposal" do
      payload = %{
        "id" => "my-goal-id",
        "predicates" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:ok, draft} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert {:ok, %Kazi.Goal{}} = Authoring.approve(draft.proposal_ref)

      other_payload = %{
        "id" => "my-goal-id",
        "predicates" => [%{"id" => "different", "provider" => "test_runner"}]
      }

      assert {:ok, replaced} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: other_payload,
                 replace: true
               )

      assert replaced.proposal_ref == draft.proposal_ref
      assert replaced.status == :proposed

      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end
  end
end
