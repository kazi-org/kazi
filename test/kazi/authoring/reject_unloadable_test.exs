defmodule Kazi.Authoring.RejectUnloadableTest do
  @moduledoc """
  Regression for #945: `Authoring.reject/2` refused a proposal whose stored
  goal-file map no longer loads under the current predicate schema (e.g. a
  `custom_script` predicate authored against a since-removed config key), even
  though rejection is a pure lifecycle transition (`proposed -> rejected`) on
  the read-model row -- it performs no reconciliation and never runs the goal,
  so it must not require the goal to load. `approve/2` is unaffected: approving
  an unloadable goal remains a footgun and stays refused.

  The row's goal is forced to an unloadable map directly via
  `ReadModel.transition_proposed_goal/3` (mirroring
  `Kazi.CLIApplyProposalRefTest`'s "no longer loads" fixture), simulating a
  proposal authored against an older schema that has since drifted -- the only
  way this state arises in practice, since `propose/2` itself validates
  loadability at draft time.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Authoring
  alias Kazi.Authoring.Draft
  alias Kazi.ReadModel
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  # A stub harness so `propose/2` never spawns a real harness/model.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result:
           ~s({"name":"Stale goal","predicates":[{"id":"health","provider":"http_probe","config":{"url":"https://example.test/healthz"}}]})
       }}
    end
  end

  # A goal-file map that PARSES but no longer LOADS: `custom_script` predicates
  # only ever accept `cmd`/`args`/`verdict`/`env` (`Kazi.Predicate.Schema`) --
  # `expected_exit_code` is not a recognised config key, so
  # `Kazi.Goal.Loader.from_map/1` rejects it with "unknown config key" (the
  # exact drift reported in #945).
  @unloadable_goal %{
    "id" => "stale-goal",
    "name" => "A goal authored against an old schema",
    "mode" => "create",
    "predicate" => [
      %{
        "id" => "greeting_file_exists_with_exact_contents",
        "provider" => "custom_script",
        "cmd" => "sh",
        "expected_exit_code" => 0
      }
    ]
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, draft} =
      Authoring.propose("an idea authored against an old schema", harness: StubHarness)

    # Force the stored goal to the unloadable map, simulating schema drift
    # after the proposal was originally drafted (propose/2 itself never
    # persists an unloadable goal — validate_loadable/1 refuses it up front).
    assert {:ok, _row} =
             ReadModel.transition_proposed_goal(draft.proposal_ref, "proposed", @unloadable_goal)

    %{proposal_ref: draft.proposal_ref, goal_id: to_string(draft.goal.id)}
  end

  test "the fixture goal actually fails to load (sanity check)" do
    assert {:error, _reason} = Kazi.Goal.Loader.from_map(@unloadable_goal)
  end

  describe "Authoring.reject/2" do
    test "transitions proposed -> rejected despite the unloadable goal", %{
      proposal_ref: proposal_ref,
      goal_id: goal_id
    } do
      assert {:ok, %Draft{status: :rejected} = draft} = Authoring.reject(proposal_ref)
      assert draft.proposal_ref == proposal_ref
      assert draft.goal_id == goal_id
      assert draft.goal == nil
      refute draft.loadable?
    end

    test "the transition is persisted", %{proposal_ref: proposal_ref} do
      assert {:ok, _draft} = Authoring.reject(proposal_ref)

      assert %ProposedGoal{status: "rejected"} = ReadModel.get_proposed_goal(proposal_ref)

      assert Enum.any?(
               ReadModel.list_proposed_goals(status: "rejected"),
               &(&1.proposal_ref == proposal_ref)
             )
    end

    test "approve/2 still refuses the unloadable goal (unaffected footgun guard)", %{
      proposal_ref: proposal_ref
    } do
      assert {:error, {:invalid_goal, _reason}} = Authoring.approve(proposal_ref)
      assert %ProposedGoal{status: "proposed"} = ReadModel.get_proposed_goal(proposal_ref)
    end
  end

  describe "kazi reject (CLI)" do
    test "--json exits 0 and notes the goal is unloadable", %{proposal_ref: proposal_ref} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["reject", proposal_ref, "--json"]) == 0
        end)

      assert {:ok, %{"status" => "rejected", "loadable" => false}} =
               Jason.decode(String.trim(out))

      assert %ProposedGoal{status: "rejected"} = ReadModel.get_proposed_goal(proposal_ref)
    end

    test "the human surface notes the goal is unloadable", %{proposal_ref: proposal_ref} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["reject", proposal_ref]) == 0
        end)

      assert out =~ "REJECTED"
      assert out =~ "unloadable"
    end
  end
end
