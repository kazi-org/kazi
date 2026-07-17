defmodule Kazi.AuthoringDiscoverTest do
  @moduledoc """
  T45.6 (UC-059): the opt-in `kazi plan --discover` on-ramp folds stack detection,
  `.feature` use-case discovery, and a public-surface codebase scan into findings
  ATTACHED to the drafted proposal as reviewer evidence (visible via
  `kazi status <proposal-ref> --json`).

  Pins the three acceptance behaviours: `--discover` attaches findings; a
  caller-drafts payload BYPASSES discovery entirely (the harness is never even
  spawned); and any discovery step failing degrades to a plain draft with a
  warning, never a hard error. HERMETIC: a stub harness, a real on-disk fixture
  repo, and the test SQLite Sandbox — no real `claude`, no network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Kazi.Authoring
  alias Kazi.Authoring.Discover
  alias Kazi.Authoring.Draft
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  # Returns a fixed JSON proposal with one valid, loadable predicate — the shape a
  # `claude --output-format json` envelope carries. No real claude, no network.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @proposal ~s({
      "name": "Health endpoint",
      "predicates": [
        {"id": "health", "provider": "http_probe",
         "description": "GET /healthz returns 200",
         "config": {"url": "https://example.test/healthz"}}
      ]
    })

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{result: @proposal}}
  end

  # Raises if driven — proves caller-drafts never spawns the harness/model.
  defmodule ExplodingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts),
      do: raise("caller-drafts must not drive the harness")
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # Shared mode: the CLI status route runs its read-model boot (migration
    # no-op) in a spawned Task that must see this test's sandbox connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # A fixture repo with a `mix.exs` (so Adopt.detect returns :elixir) and one
  # `.feature` file (so the gherkin importer finds a use case).
  defp fixture_repo do
    dir = Path.join(System.tmp_dir!(), "kazi-t456-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "features"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule Fixture.MixProject do\nend\n")

    File.write!(Path.join(dir, "features/foo.feature"), """
    Feature: Foo capability
      Scenario: a user does the foo thing
        Given a precondition
        When they act
        Then it holds
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "propose/2 --discover" do
    test "attaches findings to the proposal, visible via status --json" do
      fixture = fixture_repo()

      assert {:ok, %Draft{} = draft} =
               Authoring.propose("some idea",
                 harness: StubHarness,
                 discover: true,
                 workspace: fixture
               )

      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert row.discovery["stack"] == "elixir"
      assert is_list(row.discovery["use_cases"])
      assert row.discovery["use_cases"] != []

      {0, out} = with_io(fn -> Kazi.CLI.run(["status", draft.proposal_ref, "--json"], []) end)
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["discovery"]["stack"] == "elixir"
    end

    test "caller-drafts bypasses discovery entirely" do
      fixture = fixture_repo()

      proposal = %{
        "predicates" => [
          %{
            "id" => "x",
            "provider" => "http_probe",
            "config" => %{"url" => "https://example.test/"}
          }
        ]
      }

      # discover: true is set, but the payload is caller-drafts, so discovery must
      # NOT run — and ExplodingHarness proves no harness/model was ever spawned.
      assert {:ok, %Draft{} = draft} =
               Authoring.propose("idea",
                 proposal: proposal,
                 discover: true,
                 workspace: fixture,
                 harness: ExplodingHarness
               )

      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert is_nil(row.discovery)
    end

    test "a step that finds nothing degrades to a plain draft with a warning" do
      empty =
        Path.join(System.tmp_dir!(), "kazi-t456-empty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      assert {:ok, %Draft{} = draft} =
               Authoring.propose("some idea",
                 harness: StubHarness,
                 discover: true,
                 workspace: empty
               )

      row = Repo.get_by(ProposedGoal, proposal_ref: draft.proposal_ref)
      assert is_nil(row.discovery["stack"])
      assert row.discovery["warnings"] != []
      # Both stack detection and use-case discovery could not produce findings.
      assert length(row.discovery["warnings"]) >= 2
    end
  end

  describe "Discover.run/2" do
    test "never raises on a non-existent workspace; returns a map with warnings" do
      nope = Path.join(System.tmp_dir!(), "kazi-t456-nope-#{System.unique_integer([:positive])}")

      findings = Discover.run(nope)

      assert is_map(findings)
      assert findings["stack"] == nil
      assert findings["use_cases"] == []
      assert findings["surface"] == []
      assert findings["warnings"] != []
    end
  end
end
