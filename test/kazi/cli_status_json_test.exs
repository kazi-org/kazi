defmodule Kazi.CLIStatusJsonTest do
  @moduledoc """
  T15.5 (ADR-0023 decision 2): `kazi status --json` (NEW command).

  `kazi status <ref>` reports a run/proposal's CURRENT state from the read-model —
  a pure read, no loop driven, nothing mutated. After a run records an iteration
  (or a propose persists a proposal), `status --json <ref>` returns the persisted
  state (status, predicate vector, last iteration, timestamps); an unknown ref is
  a clear JSON error on stdout with a NON-ZERO exit.

  HERMETIC: the read-model is the test SQLite Sandbox; a recorded iteration and a
  CLI-driven propose stand in for a real run/authoring — no harness, git, or
  network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}

  # An injectable stub harness drafting a fixed proposal, so `propose` persists a
  # proposal-ref `status` can then report on (no real claude / network).
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({
           "name": "status e2e",
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
  # Tier 1 — argv boundary for status
  # ===========================================================================

  describe "parse/1 — status" do
    test "parses `status <ref>` with and without --json" do
      assert {:status, "cli-e2e", opts} = Kazi.CLI.parse(["status", "cli-e2e"])
      assert opts[:json] == false

      assert {:status, "cli-e2e", json_opts} = Kazi.CLI.parse(["status", "cli-e2e", "--json"])
      assert json_opts[:json] == true
    end

    test "a missing ref is an error" do
      assert {:error, message} = Kazi.CLI.parse(["status"])
      assert message =~ "requires a <ref>"
    end

    test "an extra positional is an error" do
      assert {:error, message} = Kazi.CLI.parse(["status", "a", "b"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — status --json reports persisted run state
  # ===========================================================================

  describe "status --json — a run's persisted state" do
    test "returns the latest recorded iteration's state for a goal_ref" do
      # Stand in for a run: record an iteration into the read-model (the same
      # projection the loop's on_iteration seam writes).
      vector =
        PredicateVector.new(%{
          code: PredicateResult.pass(),
          live: PredicateResult.fail()
        })

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "status-run",
          iteration_index: 3,
          predicate_vector: vector,
          converged: false,
          release_ref: "v2026.06.24-abc1234"
        })

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "status-run", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["kind"] == "run"
      assert payload["ref"] == "status-run"
      assert payload["status"] == "in_progress"
      assert payload["converged"] == false
      assert payload["iteration"] == 3
      assert payload["release_ref"] == "v2026.06.24-abc1234"
      assert is_binary(payload["observed_at"])

      vector_json = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector_json == %{"code" => "pass", "live" => "fail"}
    end

    test "a converged run reports status converged" do
      vector = PredicateVector.new(%{code: PredicateResult.pass()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "status-converged",
          iteration_index: 0,
          predicate_vector: vector,
          converged: true
        })

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "status-converged", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["converged"] == true
    end
  end

  describe "status --json — a proposal's persisted state" do
    test "returns the proposal's lifecycle state for a proposal_ref" do
      {0, propose_out} =
        with_io(fn ->
          Kazi.CLI.run(["propose", "ship a healthz endpoint"], harness: StubHarness)
        end)

      proposal_ref = parse_proposal_ref(propose_out)
      assert proposal_ref =~ "prop-"

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", proposal_ref, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["kind"] == "proposal"
      assert payload["ref"] == proposal_ref
      assert payload["status"] == "proposed"
      assert payload["idea"] == "ship a healthz endpoint"
      assert is_binary(payload["goal_id"])
    end
  end

  describe "status --json — unknown ref" do
    test "an unknown ref is a clear JSON error on stdout with a non-zero exit" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "does-not-exist", "--json"]) == 1
        end)

      # The error is a JSON object on STDOUT (not stderr prose), so the
      # orchestrator parses one surface and branches on the non-zero exit.
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["error"] =~ "no run or proposal found"
    end
  end

  describe "status (human) — unchanged default surface" do
    test "reports a run's state in human prose" do
      vector = PredicateVector.new(%{code: PredicateResult.pass()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "status-human",
          iteration_index: 1,
          predicate_vector: vector,
          converged: true
        })

      {code, out} = with_io(fn -> Kazi.CLI.run(["status", "status-human"]) end)
      assert code == 0
      assert out =~ "STATUS"
      assert out =~ "kind=run"
      assert out =~ "converged: true"
      refute out =~ "schema_version"
    end

    test "an unknown ref prints a human error to stderr, exit 1" do
      {code, stderr} =
        with_io(:stderr, fn -> Kazi.CLI.run(["status", "nope"]) end)

      assert code == 1
      assert stderr =~ "no run or proposal found"
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

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
