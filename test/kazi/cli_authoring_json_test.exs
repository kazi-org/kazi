defmodule Kazi.CLIAuthoringJsonTest do
  @moduledoc """
  T15.6 (ADR-0023 decision 2): `kazi list-proposed/approve/reject --json`.

  Structured JSON output for the authoring state machine, so an orchestrator
  drives propose → approve → run programmatically. Each of
  `list-proposed`/`approve`/`reject` emits a parseable JSON result under `--json`;
  transitions report machine-readable success/error, and the human surface stays
  unchanged.

  HERMETIC: the harness that drafts the proposal is an injected stub (no real
  claude, no network); the read-model is the test SQLite Sandbox.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{ReadModel, Repo}

  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({
           "name": "authoring json e2e",
           "predicates": [
             {"id": "code", "provider": "test_runner",
              "description": "the fix lands",
              "config": {"cmd": "sh", "args": ["-c", "test -f fixed.txt"]}},
             {"id": "live", "provider": "http_probe",
              "description": "the endpoint serves 200",
              "config": {"url": "http://127.0.0.1:1/healthz", "expect_status": 200, "expect_body": "ok"}}
           ]
         })
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — argv boundary: --json carries through approve/reject/list-proposed
  # ===========================================================================

  describe "parse/1 — authoring commands carry --json" do
    test "list-proposed/approve/reject carry the --json flag" do
      assert {:list_proposed, list_opts} = Kazi.CLI.parse(["list-proposed", "--json"])
      assert list_opts[:json] == true

      assert {:approve, "prop-x", approve_opts} = Kazi.CLI.parse(["approve", "prop-x", "--json"])
      assert approve_opts[:json] == true

      assert {:reject, "prop-y", reject_opts} = Kazi.CLI.parse(["reject", "prop-y", "--json"])
      assert reject_opts[:json] == true
    end
  end

  # ===========================================================================
  # Tier 2 — list-proposed --json
  # ===========================================================================

  describe "list-proposed --json" do
    test "emits the queue as a parseable JSON object (empty + populated)" do
      # Empty queue.
      empty =
        capture_io(fn -> assert Kazi.CLI.run(["list-proposed", "--json"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(empty))
      assert payload["schema_version"] == 2
      assert payload["count"] == 0
      assert payload["proposals"] == []

      # After a proposal it shows up in the list.
      {0, _} = with_io(fn -> Kazi.CLI.run(["plan", "a listed idea"], harness: StubHarness) end)

      out =
        capture_io(fn -> assert Kazi.CLI.run(["list-proposed", "--json"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 1
      assert [proposal] = payload["proposals"]
      assert proposal["status"] == "proposed"
      assert proposal["idea"] == "a listed idea"
      assert proposal["proposal_ref"] =~ "prop-"
      assert is_binary(proposal["goal_id"])
    end

    test "the --status filter is reflected in the JSON" do
      {0, _} = with_io(fn -> Kazi.CLI.run(["plan", "filtered"], harness: StubHarness) end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["list-proposed", "--status", "approved", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status_filter"] == "approved"
      assert payload["count"] == 0
    end
  end

  # ===========================================================================
  # Tier 2 — approve --json / reject --json
  # ===========================================================================

  describe "approve --json / reject --json — machine-readable transitions" do
    test "approve --json reports the transition to approved with the goal id" do
      proposal_ref = propose_one()

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["approve", proposal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["proposal_ref"] == proposal_ref
      assert payload["status"] == "approved"
      assert is_binary(payload["goal_id"])

      # The transition is persisted.
      assert %ReadModel.ProposedGoal{status: "approved"} =
               ReadModel.get_proposed_goal(proposal_ref)
    end

    test "reject --json reports the transition to rejected" do
      proposal_ref = propose_one()

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["reject", proposal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["proposal_ref"] == proposal_ref
      assert payload["status"] == "rejected"

      assert %ReadModel.ProposedGoal{status: "rejected"} =
               ReadModel.get_proposed_goal(proposal_ref)
    end

    test "approving an unknown ref is a JSON error on stdout, exit 1" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["approve", "prop-nope", "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["error"] =~ "could not approve"
      assert payload["error"] =~ "no proposal carries that ref"
    end

    test "an invalid transition (approve then reject) is a JSON error, exit 1" do
      proposal_ref = propose_one()

      {0, _} = with_io(fn -> Kazi.CLI.run(["approve", proposal_ref, "--json"]) end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["reject", proposal_ref, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "could not reject"
      assert payload["error"] =~ "cannot transition"
    end
  end

  describe "approve/reject (human) — unchanged default surface" do
    test "approve without --json prints the human lines" do
      proposal_ref = propose_one()

      {code, out} = with_io(fn -> Kazi.CLI.run(["approve", proposal_ref]) end)
      assert code == 0
      assert out =~ "APPROVED"
      assert out =~ "kazi apply"
      refute out =~ "schema_version"
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp propose_one do
    {0, out} = with_io(fn -> Kazi.CLI.run(["plan", "an idea"], harness: StubHarness) end)
    parse_proposal_ref(out)
  end

  defp parse_proposal_ref(out) do
    out
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "proposal:", parts: 2) do
        [_, ref] -> String.trim(ref)
        _ -> nil
      end
    end)
  end
end
