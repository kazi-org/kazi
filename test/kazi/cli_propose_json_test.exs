defmodule Kazi.CLIProposeJsonTest do
  @moduledoc """
  T15.2 (ADR-0023 decision 4): `kazi propose --json` with its TWO drive modes —
  the single authoring path.

  Both modes go through `Kazi.Authoring` (the one WRITE path) and emit the draft
  as ONE JSON object: goal id, `proposal_ref`, predicates[], rationale, and the
  clarify FLOOR (the gaps still open over the draft). Drive modes:

    * **kazi-drafts** — `propose "<idea>" --harness <model> --json`: kazi spawns
      the harness to draft (the existing path), then emits the draft as JSON.
    * **caller-drafts** — `propose --json` with predicates SUPPLIED by the caller
      (--predicates / stdin): the orchestrator already reasoned; kazi applies the
      deterministic floor, persists, and gates approval, WITHOUT spawning an inner
      model.

  HERMETIC: no real `claude`, no network — the `inject_opts` test seam threads a
  stub harness / a `:stdin` payload, mirroring `Kazi.CLIAuthoringTest` /
  `Kazi.CLIJsonTest`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{ReadModel, Repo}
  alias Kazi.ReadModel.ProposedGoal

  # kazi-drafts stub: a fixed JSON proposal in the result envelope (no claude, no
  # network), with a code predicate + a live http_probe predicate.
  defmodule DraftHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, _opts) do
      cond do
        # The clarify-candidate call (T11.3) — no extra questions, so only the
        # deterministic floor stands.
        prompt =~ "clarifying questions" -> {:ok, %{result: "[]"}}
        true -> {:ok, %{result: draft_json()}}
      end
    end

    defp draft_json do
      ~s({
        "name": "Healthz",
        "predicates": [
          {"id": "code", "provider": "test_runner",
           "config": {"cmd": "sh", "args": ["-c", "true"]}},
          {"id": "live", "provider": "http_probe",
           "config": {"url": "http://127.0.0.1/healthz", "expect_status": 200}}
        ],
        "rationale": "probe the deployed endpoint; broader UI is out of scope"
      })
    end
  end

  # A harness that MUST NOT be called in caller-drafts mode: any invocation sends
  # a message to the owning test process, so a test can assert it never ran (no
  # inner model spawned).
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

  # The caller-supplied proposal: predicates the orchestrator already authored,
  # WITHOUT a live-verification target and WITHOUT a scope statement — so the
  # deterministic floor must flag both.
  @caller_predicates ~s({
    "name": "Widgets feature",
    "predicates": [
      {"id": "code", "provider": "test_runner",
       "config": {"cmd": "sh", "args": ["-c", "true"]}}
    ]
  })

  # ===========================================================================
  # Tier 1 — caller-drafts argv boundary
  # ===========================================================================

  describe "parse/1 — caller-drafts options" do
    test "propose --predicates carries the payload and allows no idea" do
      assert {:propose, "", opts} =
               Kazi.CLI.parse(["plan", "--predicates", @caller_predicates, "--json"])

      assert opts[:predicates] == @caller_predicates
      assert opts[:json] == true
    end

    test "propose --json with no idea parses (stdin caller-drafts)" do
      assert {:propose, "", opts} = Kazi.CLI.parse(["plan", "--json"])
      assert opts[:json] == true
    end

    test "a bare propose with neither idea nor caller-drafts signal is still an error" do
      assert {:error, message} = Kazi.CLI.parse(["plan"])
      assert message =~ "requires an <idea>"
    end
  end

  # ===========================================================================
  # kazi-drafts: --json returns a parseable draft object
  # ===========================================================================

  describe "kazi-drafts — propose <idea> --json" do
    test "emits a single parseable draft object (no human prose), exit 0" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "ship a healthz endpoint", "--json", "--yes"],
                   harness: DraftHarness
                 ) == 0
        end)

      assert {:ok, draft} = Jason.decode(String.trim(out))
      refute out =~ "PROPOSED"

      assert draft["schema_version"] == 2
      assert draft["goal_id"] == "ship-a-healthz-endpoint"
      assert draft["proposal_ref"] =~ "prop-"
      assert draft["status"] == "proposed"
      assert draft["rationale"] =~ "probe the deployed endpoint"

      ids = Enum.map(draft["predicates"], & &1["id"])
      assert "code" in ids
      assert "live" in ids

      # The floor applies in this mode too: the draft already has a live predicate
      # (http_probe), so live-target is satisfied; scope was never stated, so it is
      # still flagged.
      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      refute "live-target" in clarify_ids
      assert "scope" in clarify_ids

      # Persisted.
      assert [%ProposedGoal{status: "proposed"}] =
               ReadModel.list_proposed_goals(status: "proposed")
    end
  end

  # ===========================================================================
  # caller-drafts: supplied predicates + the deterministic floor, NO inner model
  # ===========================================================================

  describe "caller-drafts — propose --json with supplied predicates" do
    test "accepts supplied predicates, applies the floor, persists, spawns NO model" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", @caller_predicates],
                   # The harness is injected but MUST NOT be invoked in caller-drafts.
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      # NO inner model was spawned — the spy harness never ran.
      refute_received :harness_invoked

      assert {:ok, draft} = Jason.decode(String.trim(out))
      assert draft["schema_version"] == 2
      assert draft["proposal_ref"] =~ "prop-"

      # The supplied predicate is accepted.
      assert Enum.map(draft["predicates"], & &1["id"]) == ["code"]

      # The DETERMINISTIC FLOOR is applied and flagged in the JSON: the supplied
      # predicates name no live-verification target and the request states no
      # scope, so BOTH gaps are surfaced.
      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      assert "live-target" in clarify_ids
      assert "scope" in clarify_ids

      # The proposal PERSISTED (it is approvable).
      assert [%ProposedGoal{status: "proposed"} = row] =
               ReadModel.list_proposed_goals(status: "proposed")

      assert row.proposal_ref == draft["proposal_ref"]
    end

    test "caller predicates may be supplied on stdin (a bare JSON array too)" do
      # A bare array of predicate entries is wrapped as {"predicates": [...]}.
      stdin = ~s([{"id":"code","provider":"test_runner","config":{}}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json"],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()],
                   stdin: stdin
                 ) == 0
        end)

      refute_received :harness_invoked
      assert {:ok, draft} = Jason.decode(String.trim(out))
      assert Enum.map(draft["predicates"], & &1["id"]) == ["code"]
      # The floor still flags the missing live-target + scope.
      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      assert "live-target" in clarify_ids
      assert "scope" in clarify_ids
    end

    test "a caller-drafts proposal whose predicates name a live target suppresses live-target" do
      payload =
        ~s({"predicates":[{"id":"live","provider":"http_probe","config":{"url":"http://x/healthz"}}]})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", payload],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      refute_received :harness_invoked
      assert {:ok, draft} = Jason.decode(String.trim(out))
      clarify_ids = Enum.map(draft["clarify"], & &1["id"])
      # A live predicate is present, so the floor does NOT re-ask live-target.
      refute "live-target" in clarify_ids
      # Scope was never stated, so it is still flagged.
      assert "scope" in clarify_ids
    end

    test "an empty predicate list is refused as a clear JSON error, exit 1" do
      payload = ~s({"predicates": []})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", payload],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 1
        end)

      refute_received :harness_invoked
      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "could not propose goal"
      assert ReadModel.list_proposed_goals(status: "proposed") == []
    end

    test "malformed caller predicates are a clear JSON error, exit 1" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", "not json at all"],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 1
        end)

      refute_received :harness_invoked
      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "valid JSON"
    end
  end

  # ===========================================================================
  # the non-interactive guarantee holds in caller-drafts too
  # ===========================================================================

  describe "non-interactive — caller-drafts never blocks on stdin" do
    test "no payload at all (empty stdin) errors loudly under --json rather than blocking" do
      # Empty injected stdin and no --predicates: there is nothing to draft and
      # nothing supplied. Under --json this must error as JSON (non-zero), not hang.
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json"],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()],
                   stdin: ""
                 ) == 1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "predicates"
      assert ReadModel.list_proposed_goals(status: "proposed") == []
    end
  end
end
