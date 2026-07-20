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
  alias Kazi.ReadModel
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo
  alias Kazi.Runtime

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
         "description": "home page renders",
         "config": {"url": "https://example.test/"}}
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

  # T26.8: a stub that returns EXACTLY what the real `claude` adapter produces when
  # drafting a proposal — the captured stderr-warning-prefixed `--output-format
  # json` stdout, run through the REAL `:claude` profile parser. This proves the
  # on-ramp end to end against real bytes: the prior PR #623 parser was authored
  # with no live capture and STILL returned "proposal has no predicates" because the
  # warning line broke the envelope parse so `:result` never reached authoring. The
  # stub reads the checked-in fixture and merges the parsed subset over the base
  # result map exactly as `Kazi.Harness.CliAdapter` does.
  defmodule RealClaudeDraftHarness do
    @behaviour Kazi.HarnessAdapter

    @fixture Path.expand("../fixtures/harness/claude_authoring_draft_stdout.txt", __DIR__)

    @impl true
    def run(_prompt, workspace, _opts) do
      output = File.read!(@fixture)
      base = %{output: output, exit: 0, command: "claude", workspace: workspace}

      {:ok,
       Map.merge(base, Kazi.Harness.Profile.parse(Kazi.Harness.Registry.fetch!(:claude), output))}
    end
  end

  # T26.8 (layer 2): a stub returning a `custom_script` draft in the CORRECT,
  # loader-valid shape (`cmd` + `args`) — what the harness emits once the drafting
  # prompt pins the provider config contract. The prior live failure was claude
  # inventing a `{"script", "interpreter", "expect_exit"}` config that PARSED but
  # then failed to load (`custom_script … requires a non-empty string "cmd"`),
  # killing the on-ramp at `approve`. This stub proves the fixed shape loads.
  defmodule ValidCustomScriptHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result:
           ~s({"name":"greeting","predicates":[) <>
             ~s({"id":"greeting_file_exists_with_exact_contents",) <>
             ~s("provider":"custom_script",) <>
             ~s("description":"greeting.txt contains exactly hello world",) <>
             ~s("config":{"cmd":"grep","args":["-Fxq","hello world","greeting.txt"]}}]})
       }}
    end
  end

  # A stub whose harness simply could not run.
  defmodule FailingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:error, {:command_not_found, "claude"}}
  end

  # A stub that RAISES if driven — used to prove caller-drafts (a supplied
  # `:proposal`) never spawns the harness/model (T15.2, ADR-0023 decision 4).
  defmodule ExplodingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts),
      do: raise("caller-drafts must not drive the harness")
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

    # T15.2 (ADR-0023 decision 4): caller-drafts. A `:proposal` supplied by the
    # caller is used DIRECTLY — the same write path (parse → persist) — and the
    # harness is NEVER driven, so the orchestrator pays for no second model call.
    test "caller-drafts: a supplied :proposal bypasses the harness entirely" do
      proposal = %{
        "name" => "Caller drafted",
        "predicates" => [%{"id" => "code", "provider" => "test_runner"}]
      }

      assert {:ok, %Draft{} = draft} =
               Authoring.propose("caller idea",
                 harness: ExplodingHarness,
                 proposal: proposal
               )

      # The supplied predicate was accepted and persisted, with NO harness run.
      assert [predicate] = draft.goal.predicates
      assert predicate.id == "code"
      assert draft.status == :proposed

      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end

    test "caller-drafts: a supplied :proposal may be a JSON string" do
      proposal = ~s({"predicates":[{"id":"code","provider":"test_runner"}]})

      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("caller idea", harness: ExplodingHarness, proposal: proposal)

      assert [%{id: "code"}] = goal.predicates
    end

    # A drafting harness routinely wraps its JSON in a Markdown code fence; the raw
    # string is not valid JSON, which broke `kazi plan "<idea>"` (the on-ramp step-1
    # bug). A caller-drafts string travels the SAME decode path as harness output,
    # so a fenced / prose-wrapped string pins the JSON-extraction fix.
    test "a JSON proposal wrapped in a code fence is parsed" do
      proposal =
        "Here are the acceptance predicates:\n\n" <>
          "```json\n{\"predicates\":[{\"id\":\"code\",\"provider\":\"test_runner\"}]}\n```\n\nThat is the draft."

      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("fenced idea", harness: ExplodingHarness, proposal: proposal)

      assert [%{id: "code"}] = goal.predicates
    end

    test "a JSON proposal surrounded by prose (no fence) is parsed" do
      proposal =
        ~s(Sure, here is the goal: {"predicates":[{"id":"code","provider":"test_runner"}]} -- done.)

      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("prose idea", harness: ExplodingHarness, proposal: proposal)

      assert [%{id: "code"}] = goal.predicates
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

  describe "propose/2 — clarify phase (T11.4, T11.5, ADR-0019)" do
    # A stub that distinguishes the two harness calls of an interactive propose:
    # the candidate-question call (no candidates here, so the floor is used) and
    # the draft call, whose drafted provider keys off whether the folded answer
    # ("Production logs" = prod_log) reached the draft prompt. This lets a test
    # assert the author's answer actually shaped the draft.
    defmodule ClarifyStub do
      @behaviour Kazi.HarnessAdapter

      @impl true
      def run(prompt, _workspace, _opts) do
        cond do
          prompt =~ "clarifying questions" ->
            {:ok, %{result: "[]"}}

          prompt =~ "Production logs" ->
            {:ok,
             %{
               result:
                 ~s({"name":"G","predicates":[{"id":"p","provider":"prod_log"}],"rationale":"probe the runtime; tests-only is out of scope"})
             }}

          true ->
            {:ok,
             %{
               result:
                 ~s({"name":"G","predicates":[{"id":"h","provider":"http_probe",) <>
                   ~s("config":{"url":"https://example.test/healthz"}}]})
             }}
        end
      end
    end

    test "an injected :ask callback folds answers so the draft reflects them" do
      # The author picks prod_log for the live-verification target.
      ask = fn _questions -> %{"live-target" => "prod_log", "scope" => "core"} end

      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("add a widgets feature", harness: ClarifyStub, ask: ask)

      assert [predicate] = goal.predicates
      assert predicate.kind == :prod_log
    end

    test "the :ask callback receives the deterministic floor questions" do
      ask = fn questions ->
        send(self(), {:asked, Enum.map(questions, & &1.id)})
        %{}
      end

      assert {:ok, _draft} =
               Authoring.propose("add a widgets feature", harness: ClarifyStub, ask: ask)

      assert_received {:asked, ids}
      assert "live-target" in ids
      assert "scope" in ids
    end

    test "without an :ask callback, propose stays the one-shot it always was" do
      # No clarify phase: the draft prompt never carries "Production logs", so the
      # stub drafts the default http_probe predicate.
      assert {:ok, %Draft{goal: goal}} =
               Authoring.propose("add a widgets feature", harness: ClarifyStub)

      assert [predicate] = goal.predicates
      assert predicate.kind == :http_probe
    end

    test "the inline rationale is stored on the goal metadata and round-trips" do
      ask = fn _questions -> %{"live-target" => "prod_log"} end

      assert {:ok, %Draft{goal: goal} = draft} =
               Authoring.propose("add a widgets feature", harness: ClarifyStub, ask: ask)

      assert goal.metadata["rationale"] =~ "out of scope"

      # Round-trips through the canonical loader the approval workflow uses.
      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert {:ok, %Goal{} = rehydrated} = Kazi.Goal.Loader.from_map(row.goal)
      assert rehydrated.metadata["rationale"] =~ "out of scope"
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

    # T26.8: real claude routinely nests the goal under a wrapper key instead of
    # returning predicates at the top level. After T26.7 that JSON PARSED but
    # `build_predicates` saw no top-level list and reported "proposal has no
    # predicates" — the on-ramp step-1 blocker. The parser now descends into the
    # wrapper so each plausible shape yields ≥1 usable predicate.
    test "accepts predicates nested under a \"goal\" wrapper" do
      json = ~s({"goal":{"name":"Wrapped","predicates":[{"id":"p","provider":"http_probe"}]}})
      assert {:ok, %Goal{mode: :create} = goal} = Authoring.parse_proposal(json, "g")
      assert [%Kazi.Predicate{id: "p", kind: :http_probe, acceptance?: true}] = goal.predicates
    end

    test "accepts predicates nested under a \"proposal\" wrapper" do
      json = ~s({"proposal":{"predicates":[{"id":"p","provider":"http_probe"}]}})
      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      assert [%{id: "p"}] = goal.predicates
    end
  end

  # T45.11 (#1620): the single-goal proposal chain could not land a PR because
  # parse_proposal ignored `"integration"` and serialize_goal dropped it, so an
  # approved proposal reloaded with mode :none and SerialLanding returned
  # :nothing_to_land. parse_proposal now honors it (via the SAME loader parser),
  # and serialize_goal round-trips it through persistence.
  describe "parse_proposal/2 + serialize_goal/1 integration (T45.11, #1620)" do
    @proposal ~s({
      "predicates": [{"id": "p", "provider": "http_probe", "url": "https://example.test"}],
      "integration": {"mode": "pr", "branch": "feat/x", "base": "main"}
    })

    test "honors an [integration] block in the proposal payload" do
      assert {:ok, goal} = Authoring.parse_proposal(@proposal, "g")
      assert goal.integration.mode == :pr
      assert goal.integration.branch == "feat/x"
      assert goal.integration.base == "main"
    end

    test "PARITY: proposal integration parsing == goal-file loader integration parsing" do
      {:ok, goal} = Authoring.parse_proposal(@proposal, "g")

      {:ok, loader_parsed} =
        Kazi.Goal.Loader.parse_integration(%{
          "mode" => "pr",
          "branch" => "feat/x",
          "base" => "main"
        })

      assert goal.integration == loader_parsed
    end

    test "round-trips through serialize_goal -> from_map (the drop that broke landing)" do
      {:ok, goal} = Authoring.parse_proposal(@proposal, "g")

      serialized = Authoring.serialize_goal(goal)
      assert serialized["integration"]["mode"] == "pr"

      {:ok, reloaded} = Kazi.Goal.Loader.from_map(serialized)
      assert reloaded.integration == goal.integration
      refute reloaded.integration.mode == :none
    end

    test "no integration block -> mode :none default; serialize omits the key (byte-identical)" do
      json = ~s({"predicates":[{"id":"p","provider":"http_probe"}]})
      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      assert goal.integration.mode == :none
      refute Map.has_key?(Authoring.serialize_goal(goal), "integration")
    end

    test "a malformed integration block fails the draft loudly" do
      json = ~s({"predicates":[{"id":"p","provider":"http_probe"}],"integration":{"mode":"wat"}})
      assert {:error, {:invalid_proposal, reason}} = Authoring.parse_proposal(json, "g")
      assert reason =~ "integration"
    end

    test "accepts a goal-file-shaped object with the singular \"predicate\" array" do
      json =
        ~s({"name":"GF","predicate":[{"id":"p","provider":"http_probe","url":"https://x/healthz"}]})

      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      assert [%Kazi.Predicate{id: "p", kind: :http_probe} = predicate] = goal.predicates
      # sibling config keys (the goal-file convention) survive as predicate config.
      assert predicate.config[:url] == "https://x/healthz"
    end

    # T26.8 (the E32 provider gap): authoring used to carry its own 4-entry
    # provider map that omitted custom_script (and the rest of the E32 catalog), so
    # a drafted/caller predicate naming a modern provider was silently dropped. It
    # now defers to the loader's catalog, so a custom_script predicate survives.
    test "a predicate naming custom_script survives into the built goal" do
      json =
        ~s({"predicates":[{"id":"lint","provider":"custom_script","verdict":"exit_zero","cmd":"mix credo"}]})

      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      assert [%Kazi.Predicate{id: "lint", kind: :custom_script}] = goal.predicates
    end

    test "wrapped + custom_script together (a realistic drafted shape)" do
      json =
        ~s({"goal":{"name":"Harden","predicate":[) <>
          ~s({"id":"tests","provider":"test_runner"},) <>
          ~s({"id":"static","provider":"static","cmd":"mix dialyzer"}]}})

      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      kinds = goal.predicates |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == [:static, :tests]
    end

    # T26.8 (layer 2): a drafted `custom_script` predicate carrying the REAL `cmd`
    # config (what the pinned prompt elicits) survives end to end AND the
    # serialized goal-file rehydrates through the SAME loader `approve` uses — so
    # the loader's custom_script validation passes instead of erroring on a missing
    # `cmd`. This is the pure-tier guard for the `approve` blocker.
    test "a cmd-shaped custom_script predicate loads through the loader" do
      json =
        ~s({"predicates":[{"id":"file_exists","provider":"custom_script",) <>
          ~s("config":{"cmd":"test","args":["-f","greeting.txt"]}}]})

      assert {:ok, goal} = Authoring.parse_proposal(json, "g")
      serialized = Authoring.serialize_goal(goal)

      assert {:ok, %Goal{} = loaded} = Kazi.Goal.Loader.from_map(serialized)
      cs = Enum.find(loaded.predicates, &(&1.kind == :custom_script))
      assert cs.config[:cmd] == "test"
      assert cs.config[:args] == ["-f", "greeting.txt"]
    end
  end

  # T26.8: the end-to-end on-ramp against REAL captured `claude` output. The prior
  # speculative parser (PR #623) was authored with no live capture and STILL failed
  # live with "proposal has no predicates"; the real cause was the harness layer
  # dropping `:result` when claude's stderr warning prefixed the JSON envelope. This
  # block drives `propose/2` through a stub that reproduces the real adapter result
  # (the captured stdout run through the real `:claude` profile parser), proving a
  # drafted proposal that matches what real claude returns yields a usable goal.
  describe "propose/2 — real claude draft shape (T26.8, the on-ramp step-1 fix)" do
    # T26.8 layer 1: the envelope PARSES over real captured bytes (the prior bug
    # was the harness layer dropping `:result` when claude's stderr warning
    # prefixed the JSON, which read as "no predicates" — nothing to do with
    # provider-config validity). Exercised via `parse_proposal/2` directly so
    # this stays a pure pin on the parse layer, independent of the #788 plan-time
    # load-validation gate exercised below (this exact fixture's custom_script
    # config predates the T26.8 layer-2 prompt fix and does not load).
    test "a real claude draft PARSES into ≥1 predicate (no 'no predicates')" do
      {:ok, %{result: output}} = RealClaudeDraftHarness.run("idea", ".", [])

      assert {:ok, %Goal{} = goal} = Authoring.parse_proposal(output, "git-branch-cli")
      assert length(goal.predicates) >= 1
      assert :custom_script in Enum.map(goal.predicates, & &1.kind)
    end

    # #788: this fixture predates the T26.8 layer-2 prompt fix — its custom_script
    # config uses an invented `{"script", …}` shape with no `cmd`. Before #788 that
    # PARSED fine and was persisted as `proposed`, only failing later at `approve`
    # ("the stored goal no longer loads"). Plan-time validation now matches
    # load-time validation, so `propose` rejects it immediately and nothing is
    # persisted — the caller never gets a proposal that can never run.
    test "a drafted custom_script goal missing cmd is rejected at propose, not later at approve" do
      assert {:error, {:invalid_goal, reason}} =
               Authoring.propose("a CLI tool that prints the current git branch name",
                 harness: RealClaudeDraftHarness
               )

      assert reason =~ "requires a non-empty string \"cmd\""
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end

    # T26.8 (layer 2, the `approve` blocker): the NEXT layer of the same bug. After
    # the parse fix the proposal PARSED, but a drafted `custom_script` config used
    # an invented `{"script", …}` shape with no `cmd`, so the persisted goal then
    # FAILED to load (`requires a non-empty string "cmd"`) — the on-ramp died at
    # `approve`. With the drafting prompt pinned to the real `cmd` contract, a
    # drafted `custom_script` goal now LOADS end to end: decode → build → persist →
    # the loader's custom_script validation passes (so `approve` would succeed).
    test "a drafted custom_script goal LOADS through the loader (no missing-cmd)" do
      assert {:ok, draft} =
               Authoring.propose("create greeting.txt with contents hello world",
                 harness: ValidCustomScriptHarness
               )

      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert {:ok, %Goal{} = goal} = Kazi.Goal.Loader.from_map(row.goal)

      cs = Enum.find(goal.predicates, &(&1.kind == :custom_script))
      assert cs, "expected a custom_script predicate to survive into the loaded goal"
      assert cs.config[:cmd] == "grep"
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

    # Authoring depth is the DEFAULT: the drafting prompt must instruct dense,
    # dispatch-sufficient descriptions (the converging model sees only the
    # goal + failing predicates), one requirement per predicate, and
    # negative-space companions for text-presence checks -- without the
    # operator having to ask each time.
    test "instructs implementation-brief descriptions by default" do
      prompt = Authoring.build_prompt("ship a /healthz route")
      assert prompt =~ "IMPLEMENTATION BRIEF"
      assert prompt =~ "one requirement per predicate"
      assert prompt =~ "negative-space"
    end

    # T26.8 (layer 2): the prompt must PIN the provider config contract so the
    # harness drafts a loader-valid `config` instead of an invented one. It must
    # teach that `custom_script` requires `cmd` and must NOT use the invented
    # `script` shape that load-failed live, and the contract must be sourced from
    # `Kazi.Predicate.Schema` so it never drifts from the providers.
    test "pins the custom_script config contract (cmd required, not script)" do
      prompt = Authoring.build_prompt("create greeting.txt")

      # The custom_script contract is present, with cmd marked required.
      assert prompt =~ "custom_script: cmd (string) *required*"
      # The invented shape is explicitly forbidden.
      assert prompt =~ "MUST NOT use `script`"
      assert prompt =~ "interpreter"
      # Sourced from the schema's own example (the cmd-based shape), not invented.
      assert prompt =~ ~s("cmd":"semgrep")
      # Every documented provider's contract is rendered from the single source.
      for kind <- Kazi.Predicate.Schema.kinds() do
        assert prompt =~ "- #{kind}:"
      end
    end
  end

  # T3.5b (UC-017): the approval workflow over a proposed goal. Tier 2 — every
  # transition crosses the real SQLite boundary; HERMETIC (the stub harness drafts
  # the proposal, no real claude, no network, no loop spun).
  describe "approve/2 — Tier 2 (transitions to runnable)" do
    setup do
      {:ok, draft} = Authoring.propose("a health endpoint that returns 200", harness: StubHarness)
      %{draft: draft}
    end

    test "transitions proposed → approved and returns a runnable goal", %{draft: draft} do
      assert {:ok, %Goal{} = goal} = Authoring.approve(draft.proposal_ref)

      # The returned goal is exactly what the freshly-proposed draft held — the
      # approval rehydrated it through the same loader, losing nothing.
      assert goal.mode == :create
      assert Enum.map(goal.predicates, & &1.id) == Enum.map(draft.goal.predicates, & &1.id)

      # Runnable by Kazi.Runtime: `approve` hands back a `%Goal{}` (the shape
      # `Runtime.run/2` accepts at its guard) whose every predicate kind the
      # runtime can dispatch — exactly the gate `resolve_providers/2` enforces.
      dispatchable = Runtime.provider_modules()
      kinds = Goal.all_predicates(goal) |> Enum.map(& &1.kind) |> Enum.uniq()
      assert Enum.all?(kinds, &Map.has_key?(dispatchable, &1))

      # The transition is durable: the row now reads `approved` and is queryable.
      assert %ProposedGoal{status: "approved"} =
               ReadModel.get_proposed_goal(draft.proposal_ref)

      assert Enum.any?(
               ReadModel.list_proposed_goals(status: "approved"),
               &(&1.proposal_ref == draft.proposal_ref)
             )
    end

    test "an approved goal round-trips identically through the loader", %{draft: draft} do
      assert {:ok, goal} = Authoring.approve(draft.proposal_ref)

      row = ReadModel.get_proposed_goal(draft.proposal_ref)
      assert {:ok, reloaded} = Kazi.Goal.Loader.from_map(row.goal)
      assert reloaded.id == goal.id
      assert Enum.map(reloaded.predicates, & &1.id) == Enum.map(goal.predicates, & &1.id)
    end

    test "rejects an unknown proposal ref" do
      assert {:error, :not_found} = Authoring.approve("prop-does-not-exist")
    end

    test "refuses to approve an already-rejected goal (invalid transition)", %{draft: draft} do
      assert {:ok, _} = Authoring.reject(draft.proposal_ref)

      assert {:error, {:invalid_transition, :rejected, :approved}} =
               Authoring.approve(draft.proposal_ref)
    end

    test "refuses to re-approve an already-approved goal", %{draft: draft} do
      assert {:ok, _} = Authoring.approve(draft.proposal_ref)

      assert {:error, {:invalid_transition, :approved, :approved}} =
               Authoring.approve(draft.proposal_ref)
    end
  end

  describe "reject/2 — Tier 2 (persisted + queryable)" do
    setup do
      {:ok, draft} = Authoring.propose("an idea to decline", harness: StubHarness)
      %{draft: draft}
    end

    test "transitions proposed → rejected, persisted and queryable", %{draft: draft} do
      assert {:ok, %Draft{status: :rejected} = rejected} = Authoring.reject(draft.proposal_ref)
      assert rejected.proposal_ref == draft.proposal_ref

      assert %ProposedGoal{status: "rejected"} =
               ReadModel.get_proposed_goal(draft.proposal_ref)

      assert Enum.any?(
               ReadModel.list_proposed_goals(status: "rejected"),
               &(&1.proposal_ref == draft.proposal_ref)
             )
    end

    test "refuses to reject an already-approved goal", %{draft: draft} do
      assert {:ok, _} = Authoring.approve(draft.proposal_ref)

      assert {:error, {:invalid_transition, :approved, :rejected}} =
               Authoring.reject(draft.proposal_ref)
    end

    test "rejects an unknown proposal ref" do
      assert {:error, :not_found} = Authoring.reject("prop-missing")
    end
  end

  describe "edit/3 — Tier 2 (re-review with an amended goal)" do
    setup do
      {:ok, draft} = Authoring.propose("an idea to refine", harness: StubHarness)
      %{draft: draft}
    end

    test "replaces the goal payload and keeps it proposed", %{draft: draft} do
      # A reviewer narrows the goal to a single test_runner predicate.
      changes = %{
        "id" => "refined-goal",
        "mode" => "create",
        "predicate" => [
          %{"id" => "tests", "provider" => "test_runner", "acceptance" => true}
        ]
      }

      assert {:ok, %Draft{status: :proposed} = edited} =
               Authoring.edit(draft.proposal_ref, changes)

      assert edited.goal.id == "refined-goal"
      assert Enum.map(edited.goal.predicates, & &1.id) == ["tests"]

      # Persisted: the row still reads `proposed`, now carrying the edited goal,
      # which still rehydrates into a runnable goal.
      row = ReadModel.get_proposed_goal(draft.proposal_ref)
      assert row.status == "proposed"
      assert {:ok, reloaded} = Kazi.Goal.Loader.from_map(row.goal)
      assert reloaded.id == "refined-goal"

      # An edited-then-approved goal is runnable.
      assert {:ok, %Goal{}} = Authoring.approve(draft.proposal_ref)
    end

    test "refuses a malformed edit (goal that won't load) and writes nothing", %{draft: draft} do
      # No predicates → the loader rejects it; the row must be untouched.
      assert {:error, {:invalid_goal, _reason}} =
               Authoring.edit(draft.proposal_ref, %{"id" => "broken", "mode" => "create"})

      assert %ProposedGoal{status: "proposed", goal: goal} =
               ReadModel.get_proposed_goal(draft.proposal_ref)

      # The original drafted goal survives the failed edit.
      assert {:ok, intact} = Kazi.Goal.Loader.from_map(goal)
      assert length(intact.predicates) == length(draft.goal.predicates)
    end

    test "refuses to edit a terminal (approved) goal", %{draft: draft} do
      assert {:ok, _} = Authoring.approve(draft.proposal_ref)

      assert {:error, {:invalid_transition, :approved, :proposed}} =
               Authoring.edit(draft.proposal_ref, %{
                 "id" => "x",
                 "mode" => "create",
                 "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
               })
    end
  end
end
