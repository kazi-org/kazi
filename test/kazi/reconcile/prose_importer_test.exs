defmodule Kazi.Reconcile.ProseImporterTest do
  @moduledoc """
  T13.3 (UC-025, ADR-0021 decision 1 — the prose path): a PROSE doc (an ADR /
  requirements / design doc) is drafted into candidate acceptance predicates via
  the EXISTING authoring path (`Kazi.Authoring`), producing a `proposed` draft a
  human reviews before acceptance.

  HERMETIC: the harness is an INJECTED stub returning a fixed proposal — no real
  `claude`, no network. The deterministic clarify floor (ADR-0019) still applies,
  and nothing is accepted without going through the existing `proposed → approve`
  gate (`Kazi.Authoring.approve/2`).
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.Authoring
  alias Kazi.Authoring.Draft
  alias Kazi.Goal
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Reconcile.ProseImporter
  alias Kazi.Repo

  @doc_text """
  # ADR 0099: Health surface

  The service MUST expose a `/healthz` endpoint that returns 200 over HTTP so an
  operator can verify the deploy is live.
  """

  # An injectable stub harness (the seam): returns a fixed JSON proposal in the
  # result map's `:result` field — the shape a `claude --output-format json`
  # envelope carries. No real claude, no network. The drafted predicate keys off
  # whether the doc text reached the prompt, so a test can prove the doc drove it.
  defmodule DocHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, _opts) do
      cond do
        # The candidate-question call (interactive clarify): no candidates, so the
        # deterministic floor stands alone.
        prompt =~ "clarifying questions" ->
          {:ok, %{result: "[]"}}

        # The draft call: the doc text reached the prompt, so draft the health
        # predicate the doc describes.
        prompt =~ "/healthz" ->
          {:ok,
           %{
             result:
               ~s({"name":"Health surface","predicates":[{"id":"healthz","provider":"http_probe",) <>
                 ~s("description":"GET /healthz returns 200",) <>
                 ~s("config":{"url":"https://example.test/healthz"}}],) <>
                 ~s("rationale":"the ADR requires a live health surface"})
           }}

        true ->
          {:ok, %{result: ~s({"predicates":[{"id":"x","provider":"test_runner"}]})}}
      end
    end
  end

  # A stub that RAISES if driven — proves the harness is never touched on the
  # error paths that should short-circuit before drafting (empty doc), and that
  # caller-drafts skips it.
  defmodule ExplodingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts),
      do: raise("the harness must not be driven on this path")
  end

  # A stub whose harness simply could not run — surfaced verbatim by propose/2.
  defmodule FailingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:error, {:command_not_found, "claude"}}
  end

  setup do
    # Per-test transaction via the SQLite3 Sandbox — isolates rows between tests.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "import/2 — a prose doc yields a proposed draft via Kazi.Authoring" do
    test "drafts candidate predicates as a proposed draft" do
      assert {:ok, %Draft{} = draft} = ProseImporter.import(@doc_text, harness: DocHarness)

      # A create-mode goal of acceptance predicates — the candidate intent the doc
      # describes, drafted by the harness.
      assert %Goal{mode: :create} = draft.goal
      assert [predicate] = draft.goal.predicates
      assert predicate.id == "healthz"
      assert predicate.kind == :http_probe
      assert predicate.acceptance?

      # Persisted through the SAME write path as any propose — status `proposed`.
      assert draft.status == :proposed

      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end

    test "the persisted draft round-trips through the canonical loader" do
      assert {:ok, %Draft{} = draft} = ProseImporter.import(@doc_text, harness: DocHarness)

      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert {:ok, %Goal{} = rehydrated} = Goal.Loader.from_map(row.goal)
      assert rehydrated.mode == :create
      assert [%{id: "healthz"}] = rehydrated.predicates
    end

    test "a :title is prepended as a heading over the doc body" do
      defmodule TitleEchoHarness do
        @behaviour Kazi.HarnessAdapter

        @impl true
        def run(prompt, _workspace, opts) do
          send(Keyword.fetch!(opts, :test_pid), {:prompt, prompt})
          {:ok, %{result: ~s({"predicates":[{"id":"x","provider":"test_runner"}]})}}
        end
      end

      assert {:ok, _draft} =
               ProseImporter.import("body text",
                 harness: TitleEchoHarness,
                 title: "Requirements doc",
                 adapter_opts: [test_pid: self()]
               )

      assert_receive {:prompt, prompt}
      assert prompt =~ "# Requirements doc"
      assert prompt =~ "body text"
    end
  end

  describe "import/2 — routed through the review/approve gate (nothing accepted without approval)" do
    test "the draft is proposed, not runnable, until approved" do
      assert {:ok, %Draft{status: :proposed} = draft} =
               ProseImporter.import(@doc_text, harness: DocHarness)

      # The proposal sits as `proposed` — it is NOT auto-accepted.
      assert %ProposedGoal{status: "proposed"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)

      # Approval is the gate that turns it into a runnable goal — the SAME flow
      # any other proposal uses.
      assert {:ok, %Goal{} = goal} = Authoring.approve(draft.proposal_ref)
      assert goal.mode == :create
      assert [%{id: "healthz"}] = goal.predicates

      assert %ProposedGoal{status: "approved"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end

    test "a reviewer may reject the drafted proposal instead" do
      assert {:ok, %Draft{} = draft} = ProseImporter.import(@doc_text, harness: DocHarness)

      assert {:ok, %Draft{status: :rejected}} = Authoring.reject(draft.proposal_ref)

      assert %ProposedGoal{status: "rejected"} =
               Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
    end
  end

  describe "import/2 — the deterministic clarify floor still applies (ADR-0019)" do
    test "an injected :ask callback receives the deterministic floor questions" do
      ask = fn questions ->
        send(self(), {:asked, Enum.map(questions, & &1.id)})
        %{}
      end

      # A doc with no live-target/scope signal triggers the full floor.
      doc = "The widgets feature should let a user create and list widgets."

      assert {:ok, _draft} = ProseImporter.import(doc, harness: DocHarness, ask: ask)

      assert_received {:asked, ids}
      # The deterministic floor still applies over a prose doc — its must-ask gaps
      # (live-verification target and scope) are asked before drafting.
      assert "live-target" in ids
      assert "scope" in ids
    end
  end

  describe "import/2 — the injectable harness seam" do
    test "caller-drafts: a supplied :proposal bypasses the harness entirely" do
      proposal = %{
        "name" => "Caller drafted from a doc",
        "predicates" => [%{"id" => "code", "provider" => "test_runner"}]
      }

      assert {:ok, %Draft{goal: goal}} =
               ProseImporter.import(@doc_text, harness: ExplodingHarness, proposal: proposal)

      assert [%{id: "code"}] = goal.predicates
    end

    test "surfaces a harness that could not run" do
      assert {:error, {:harness_failed, {:command_not_found, "claude"}}} =
               ProseImporter.import(@doc_text, harness: FailingHarness)
    end
  end

  describe "import/2 — error paths" do
    test "rejects a blank doc without driving the harness" do
      assert {:error, :empty_doc} = ProseImporter.import("   \n\n  ", harness: ExplodingHarness)
      assert Repo.aggregate(ProposedGoal, :count) == 0
    end
  end

  describe "import_file/2 — reads a prose doc off disk" do
    @tag :tmp_dir
    test "imports a doc read from a path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "0099-health.md")
      File.write!(path, @doc_text)

      assert {:ok, %Draft{} = draft} = ProseImporter.import_file(path, harness: DocHarness)
      assert [%{id: "healthz"}] = draft.goal.predicates
      assert draft.status == :proposed
    end

    test "surfaces an unreadable path" do
      assert {:error, {:read_failed, :enoent}} =
               ProseImporter.import_file("does/not/exist.md", harness: ExplodingHarness)
    end
  end
end
