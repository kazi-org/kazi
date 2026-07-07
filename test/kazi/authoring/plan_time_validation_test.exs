defmodule Kazi.Authoring.PlanTimeValidationTest do
  @moduledoc """
  Regression for #788: `kazi plan --predicates` accepted a `custom_script`
  predicate with no `cmd` (or any other provider-specific required config) --
  the payload persisted as `proposed` with no error, only to fail later at
  `kazi approve` with "the stored goal no longer loads".

  `Kazi.Authoring.propose/2` now round-trips the drafted goal through the SAME
  canonical loader `approve/2` rehydrates through (`serialize_goal/1` ->
  `Kazi.Goal.Loader.from_map/1`) BEFORE persisting, so a payload that cannot
  load is rejected at `propose` time -- plan-time validation matches load-time
  validation, with exactly one copy of the provider-config rules.
  """
  use ExUnit.Case, async: false

  alias Kazi.Authoring
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

  describe "caller-drafts: a payload that cannot load is rejected at propose" do
    test "a custom_script predicate with no cmd is refused, not persisted" do
      payload = %{
        "name" => "x",
        "predicates" => [
          %{
            "id" => "format_clean",
            "provider" => "custom_script",
            "description" => "mix format --check-formatted exits 0"
          }
        ]
      }

      assert {:error, {:invalid_goal, reason}} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert reason =~ "requires a non-empty string \"cmd\""

      # Nothing persisted -- the orchestrator never gets a proposal_ref for a
      # goal that could not later be approved.
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end

    test "a custom_script predicate WITH a cmd loads and persists cleanly" do
      payload = %{
        "name" => "x",
        "predicates" => [
          %{
            "id" => "format_clean",
            "provider" => "custom_script",
            "description" => "mix format --check-formatted exits 0",
            "config" => %{"cmd" => "mix", "args" => ["format", "--check-formatted"]}
          }
        ]
      }

      assert {:ok, draft} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)

      # And approval, which rehydrates through the SAME loader, now succeeds --
      # the on-ramp no longer dies at this later step.
      assert {:ok, %Kazi.Goal{}} = Authoring.approve(draft.proposal_ref)
    end

    test "an unknown custom_script verdict is refused at propose" do
      payload = %{
        "name" => "x",
        "predicates" => [
          %{
            "id" => "weird",
            "provider" => "custom_script",
            "config" => %{"cmd" => "true", "verdict" => "not-a-real-verdict"}
          }
        ]
      }

      assert {:error, {:invalid_goal, reason}} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert reason =~ "unknown verdict"
    end

    # T48.1 (ADR-0058): the same class of bug, one level up -- a live predicate
    # with no `url` previously loaded fine and only errored `missing_url` at
    # dispatch (potentially never surfacing until the loop burned its whole
    # budget). It is now refused here, at propose, for the same reason a bare
    # custom_script is: a payload that cannot load must never be persisted as
    # `proposed`.
    test "an http_probe predicate with no url is refused, not persisted" do
      payload = %{
        "name" => "x",
        "predicates" => [
          %{
            "id" => "healthz-live",
            "provider" => "http_probe",
            "description" => "GET /healthz returns 200"
          }
        ]
      }

      assert {:error, {:invalid_goal, reason}} =
               Authoring.propose("caller-supplied predicates",
                 harness: ExplodingHarness,
                 proposal: payload
               )

      assert reason =~ "missing required key \"url\""
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end
  end
end
