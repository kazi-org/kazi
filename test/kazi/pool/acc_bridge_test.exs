defmodule Kazi.Pool.AccBridgeTest do
  @moduledoc """
  T20.1 (ADR-0026 L1): the `acc:` → predicates BRIDGE.

  Two tiers:

    * **Unit** — pure parsing on FIXTURE `acc:` lines (modeled on real E12-E16 WBS
      tasks): clauses map to the right provider kind, recognised commands become
      `config`, non-mappable clauses degrade to a best-effort described predicate
      (no invented specifics), and the function is DETERMINISTIC + HERMETIC (same
      input → same output, no I/O).
    * **End-to-end** — the produced payload, fed to `kazi propose --json
      --predicates` via the existing `Kazi.CLI` caller-drafts seam with a STUB
      harness, is ACCEPTED (the clarify floor applies; NO inner model is spawned).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  doctest Kazi.Pool.AccBridge

  alias Kazi.Pool.AccBridge
  alias Kazi.{ReadModel, Repo}
  alias Kazi.ReadModel.ProposedGoal

  # A harness that MUST NOT be called in caller-drafts mode (no inner model). Any
  # invocation messages the owning test process so a test can assert it never ran.
  defmodule SpyHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      if pid = opts[:spy_pid], do: send(pid, :harness_invoked)
      {:ok, %{result: ~s({"name":"unexpected","predicates":[]})}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Unit — clause → provider mapping
  # ===========================================================================

  describe "acc_to_predicates/1 — provider mapping" do
    test "a tests-pass clause maps to test_runner; an endpoint-status clause to http_probe" do
      acc = "ExUnit ... ; the endpoint returns 200"
      payload = AccBridge.acc_to_predicates(acc)

      assert Enum.map(payload["predicates"], & &1["provider"]) == ["test_runner", "http_probe"]
    end

    test "`mix format` clean → a test_runner with the concrete check-formatted command" do
      payload = AccBridge.acc_to_predicates("`mix format` clean")
      [pred] = payload["predicates"]

      assert pred["provider"] == "test_runner"
      assert pred["config"] == %{"cmd" => "mix", "args" => ["format", "--check-formatted"]}
    end

    test "a `mix test` / ExUnit clause → mix test command" do
      payload = AccBridge.acc_to_predicates("ExUnit green via `mix test`")
      [pred] = payload["predicates"]
      assert pred["config"] == %{"cmd" => "mix", "args" => ["test"]}
    end

    test "a --warnings-as-errors clause → mix compile --warnings-as-errors" do
      payload = AccBridge.acc_to_predicates("`mix compile --warnings-as-errors` clean")
      [pred] = payload["predicates"]
      assert pred["config"] == %{"cmd" => "mix", "args" => ["compile", "--warnings-as-errors"]}
    end

    test "a playwright clause → npx playwright test" do
      payload = AccBridge.acc_to_predicates("`npx playwright test` green against site/dist")
      [pred] = payload["predicates"]
      assert pred["provider"] == "test_runner"
      assert pred["config"] == %{"cmd" => "npx", "args" => ["playwright", "test"]}
    end

    test "an http_probe clause extracts the path and status into config" do
      payload = AccBridge.acc_to_predicates("GET /healthz returns 200")
      [pred] = payload["predicates"]

      assert pred["provider"] == "http_probe"
      assert pred["config"]["path"] == "/healthz"
      assert pred["config"]["expect_status"] == 200
    end

    test "an http_probe clause with a full URL records the url verbatim" do
      payload =
        AccBridge.acc_to_predicates("the endpoint at https://kazi.sire.run/healthz returns 204")

      [pred] = payload["predicates"]
      assert pred["config"]["url"] == "https://kazi.sire.run/healthz"
      assert pred["config"]["expect_status"] == 204
    end

    test "a production-log clause maps to prod_log" do
      payload = AccBridge.acc_to_predicates("a prod log line confirms the run completed")
      [pred] = payload["predicates"]
      assert pred["provider"] == "prod_log"
    end

    test "a 'live predicate passes' clause maps to prod_log" do
      payload = AccBridge.acc_to_predicates("the live predicate passes")
      [pred] = payload["predicates"]
      assert pred["provider"] == "prod_log"
    end
  end

  # ===========================================================================
  # Unit — best-effort, no invented specifics
  # ===========================================================================

  describe "acc_to_predicates/1 — best-effort, no fabrication" do
    test "a non-mappable clause becomes a DESCRIBED test_runner with NO command" do
      payload = AccBridge.acc_to_predicates("the graph renders in Obsidian")
      [pred] = payload["predicates"]

      assert pred["provider"] == "test_runner"
      assert pred["description"] == "the graph renders in Obsidian"
      # No command is invented for an unmappable clause.
      assert pred["config"] == %{}
    end

    test "a vague 'tests pass' clause is a test_runner with no fabricated command" do
      payload = AccBridge.acc_to_predicates("all the tests pass")
      [pred] = payload["predicates"]
      assert pred["provider"] == "test_runner"
      assert pred["config"] == %{}
    end

    test "an endpoint clause WITHOUT a pinned status omits expect_status (no invented code)" do
      payload = AccBridge.acc_to_predicates("the /widgets endpoint returns the list")
      [pred] = payload["predicates"]
      # No status verb+code present, so it is NOT mis-mapped to http_probe; it is a
      # described best-effort predicate carrying the clause.
      assert pred["provider"] == "test_runner"
      refute Map.has_key?(pred["config"], "expect_status")
    end

    test "a blank acc still yields one non-empty best-effort predicate" do
      payload = AccBridge.acc_to_predicates("   ;  ; ")
      assert [pred] = payload["predicates"]
      assert pred["provider"] == "test_runner"
    end
  end

  # ===========================================================================
  # Unit — determinism + hermeticity
  # ===========================================================================

  describe "acc_to_predicates/1 — deterministic + hermetic" do
    test "the same acc input yields byte-identical output" do
      acc =
        "ExUnit on a fixture spec -- paths become grouped http_probe predicates; `mix format` clean; the endpoint returns 200"

      a = AccBridge.acc_to_predicates(acc)
      b = AccBridge.acc_to_predicates(acc)
      assert a == b
      # And it round-trips through JSON (it is JSON-able).
      assert {:ok, decoded} = Jason.decode(Jason.encode!(a))
      assert decoded == a
    end

    test "predicate ids are stable and unique across clauses" do
      payload =
        AccBridge.acc_to_predicates("ExUnit green; `mix format` clean; the endpoint returns 200")

      ids = Enum.map(payload["predicates"], & &1["id"])
      assert length(ids) == 3
      assert ids == Enum.uniq(ids)
      # Re-running gives the same ids (deterministic, no clock/randomness).
      again =
        AccBridge.acc_to_predicates("ExUnit green; `mix format` clean; the endpoint returns 200")

      assert Enum.map(again["predicates"], & &1["id"]) == ids
    end
  end

  # ===========================================================================
  # End-to-end — the payload is ACCEPTED by `propose --json --predicates`
  # ===========================================================================

  describe "end-to-end — payload accepted by kazi propose --json --predicates" do
    test "the bridge payload is accepted caller-drafts, floor applies, NO model spawned" do
      # A realistic E12-E16-style acc line.
      acc = "ExUnit -- the importer yields grouped predicates; `mix format` clean"
      payload = AccBridge.acc_to_predicates(acc)
      predicates_json = Jason.encode!(payload)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", predicates_json],
                   # The harness is injected but MUST NOT be invoked in caller-drafts.
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      # NO inner model was spawned.
      refute_received :harness_invoked

      assert {:ok, draft} = Jason.decode(String.trim(out))
      assert draft["schema_version"] == 2
      assert draft["proposal_ref"] =~ "prop-"
      assert draft["status"] == "proposed"

      # Both bridged predicates survived into the accepted draft. The draft echoes
      # the predicate KIND (the loader maps the `test_runner` provider string to
      # the `:tests` kind), so the draft reports "tests".
      providers =
        draft["predicates"]
        |> Enum.map(& &1["provider"])
        |> Enum.sort()

      assert providers == ["tests", "tests"]

      # The clarify FLOOR applied: this acc names no live-verification target and no
      # scope, so both gaps are surfaced (the merge gate the session reads).
      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      assert "live-target" in clarify_ids
      assert "scope" in clarify_ids

      # PERSISTED (it is approvable).
      assert [%ProposedGoal{status: "proposed"} = row] =
               ReadModel.list_proposed_goals(status: "proposed")

      assert row.proposal_ref == draft["proposal_ref"]
    end

    test "a bridged http_probe predicate suppresses the live-target floor question" do
      # An acc with a live endpoint criterion → an http_probe predicate, which the
      # floor treats as the live-verification target.
      acc = "GET https://kazi.sire.run/healthz returns 200"
      payload = AccBridge.acc_to_predicates(acc)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", Jason.encode!(payload)],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      refute_received :harness_invoked
      assert {:ok, draft} = Jason.decode(String.trim(out))

      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      # A live (http_probe) predicate is present, so the floor does NOT re-ask
      # live-target; scope is still unstated, so it is flagged.
      refute "live-target" in clarify_ids
      assert "scope" in clarify_ids
    end
  end
end
