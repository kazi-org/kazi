defmodule Kazi.AuthoringTest do
  @moduledoc """
  T3.5a (UC-017): `Kazi.Authoring.propose/2` drives an INJECTED stub harness to
  draft a `Kazi.Goal` of acceptance predicates from a prose idea, and persists it
  as `proposed` in the read-model.

  Tier 0/1 cover the pure shape (deterministic draft, malformed-proposal error,
  goal serialization round-trip); Tier 2 crosses the real SQLite boundary
  (persisted as `proposed`, round-trips back through the read-model). HERMETIC:
  no real `claude`, no network — the harness is a stub module returning a fixed
  proposal.
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.Authoring
  alias Kazi.Authoring.Draft
  alias Kazi.Goal
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  # An injectable stub harness (the seam): returns a fixed JSON proposal in the
  # result map's `:result` field — the shape a `claude --output-format json`
  # envelope carries (T4.1). No real claude, no network.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @proposal ~s({
      "name": "Health endpoint",
      "predicates": [
        {"id": "health", "provider": "http_probe",
         "description": "GET /healthz returns 200",
         "config": {"url": "https://example.test/healthz"}},
        {"id": "smoke", "provider": "browser",
         "description": "home page renders"}
      ]
    })

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{result: @proposal}}
  end

  # A stub that hands back an already-decoded proposal map under `:proposal`.
  defmodule DecodedHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         proposal: %{
           "name" => "Decoded",
           "predicates" => [%{"id" => "ok", "provider" => "test_runner"}]
         }
       }}
    end
  end

  # A stub returning a structurally-valid envelope with no usable predicate.
  defmodule EmptyHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts),
      do: {:ok, %{result: ~s({"name": "nope", "predicates": []})}}
  end

  # A stub whose harness simply could not run.
  defmodule FailingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:error, {:command_not_found, "claude"}}
  end

  setup do
    # Per-test transaction via the SQLite3 Sandbox — isolates rows between tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "propose/2 — Tier 2 (real SQLite boundary)" do
    test "yields a structured draft goal and persists it as proposed" do
      assert {:ok, %Draft{} = draft} =
               Authoring.propose("a health endpoint that returns 200", harness: StubHarness)

      # The draft is a structured, reviewable artifact: a create-mode goal with
      # ≥1 acceptance predicate.
      assert %Goal{mode: :create} = draft.goal
      assert length(draft.goal.predicates) == 2
      assert Enum.all?(draft.goal.predicates, & &1.acceptance?)
      assert draft.status == :proposed
      assert draft.idea == "a health endpoint that returns 200"

      # Persisted as `proposed` in the read-model — round-trips back.
      assert %ProposedGoal{status: "proposed"} =
               row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)

      assert row.idea == draft.idea
      assert row.goal_id == to_string(draft.goal.id)

      # The persisted goal is the canonical goal-file map shape, so T3.5b can
      # rehydrate it through the same validated loader the CLI uses.
      assert {:ok, %Goal{} = rehydrated} = Kazi.Goal.Loader.from_map(row.goal)
      assert rehydrated.mode == :create
      assert length(rehydrated.predicates) == 2
    end

    test "is deterministic: the same idea yields the same draft shape (upsert)" do
      idea = "a deterministic idea"

      assert {:ok, draft1} = Authoring.propose(idea, harness: StubHarness)
      assert {:ok, draft2} = Authoring.propose(idea, harness: StubHarness)

      # Same proposal_ref (content-derived) → upsert, not a duplicate row.
      assert draft1.proposal_ref == draft2.proposal_ref
      assert draft1.goal.id == draft2.goal.id

      assert Repo.aggregate(ProposedGoal, :count) == 1
    end

    test "accepts an already-decoded proposal map from the harness" do
      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("decoded path", harness: DecodedHarness)

      assert [predicate] = goal.predicates
      assert predicate.id == "ok"
      assert predicate.kind == :tests
    end

    test "forwards adapter_opts and workspace to the injected harness" do
      defmodule EchoHarness do
        @behaviour Kazi.HarnessAdapter

        @impl true
        def run(_prompt, workspace, opts) do
          send(Keyword.fetch!(opts, :test_pid), {:ran, workspace, opts})
          {:ok, %{result: ~s({"predicates":[{"id":"x","provider":"test_runner"}]})}}
        end
      end

      assert {:ok, _} =
               Authoring.propose("seam check",
                 harness: EchoHarness,
                 workspace: "/tmp/target",
                 adapter_opts: [test_pid: self(), model: "stub"]
               )

      assert_receive {:ran, "/tmp/target", opts}
      assert opts[:model] == "stub"
    end
  end

  describe "propose/2 — error paths" do
    test "rejects a blank idea" do
      assert {:error, :empty_idea} = Authoring.propose("   ", harness: StubHarness)
    end

    test "rejects a proposal with no usable predicate" do
      assert {:error, {:invalid_proposal, _}} =
               Authoring.propose("empty proposal", harness: EmptyHarness)

      # Nothing persisted on a rejected proposal.
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end

    test "surfaces a harness that could not run" do
      assert {:error, {:harness_failed, {:command_not_found, "claude"}}} =
               Authoring.propose("harness down", harness: FailingHarness)
    end
  end

  describe "parse_proposal/2 — Tier 0 (pure)" do
    test "drafts a create-mode goal of acceptance predicates from JSON" do
      json = ~s({"name":"N","predicates":[{"id":"p","provider":"http_probe"}]})
      assert {:ok, %Goal{mode: :create, name: "N"} = goal} = Authoring.parse_proposal(json, "g")
      assert [%Kazi.Predicate{id: "p", kind: :http_probe, acceptance?: true}] = goal.predicates
    end

    test "drops predicates with an unknown provider but keeps the goal" do
      json =
        ~s({"predicates":[{"id":"a","provider":"http_probe"},{"id":"b","provider":"wat"}]})

      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      assert [%{id: "a"}] = goal.predicates
    end

    test "rejects malformed JSON" do
      assert {:error, {:invalid_proposal, _}} = Authoring.parse_proposal("{not json", "g")
    end

    test "rejects a non-object proposal" do
      assert {:error, {:invalid_proposal, _}} = Authoring.parse_proposal("[1,2,3]", "g")
    end

    test "rejects an empty predicate list" do
      assert {:error, {:invalid_proposal, _}} =
               Authoring.parse_proposal(~s({"predicates":[]}), "g")
    end
  end

  describe "serialize_goal/1 — round-trips through the loader" do
    test "a drafted goal serializes to a goal-file map the loader rehydrates" do
      {:ok, goal} =
        Authoring.parse_proposal(
          ~s({"name":"Round trip","predicates":[
              {"id":"p1","provider":"http_probe","config":{"url":"u"}},
              {"id":"p2","provider":"test_runner"}]}),
          "round-trip"
        )

      serialized = Authoring.serialize_goal(goal)

      assert {:ok, %Goal{} = back} = Kazi.Goal.Loader.from_map(serialized)
      assert back.id == "round-trip"
      assert back.mode == :create
      assert Enum.map(back.predicates, & &1.id) |> Enum.sort() == ["p1", "p2"]
      # config survives the round-trip, re-atomised by the loader.
      p1 = Enum.find(back.predicates, &(&1.id == "p1"))
      assert p1.config[:url] == "u"
    end
  end

  describe "build_prompt/1 — Tier 0 (pure)" do
    test "embeds the idea and asks for machine-checkable acceptance predicates" do
      prompt = Authoring.build_prompt("ship a /healthz route")
      assert prompt =~ "ship a /healthz route"
      assert prompt =~ "acceptance"
      assert prompt =~ "JSON"
    end
  end
end
