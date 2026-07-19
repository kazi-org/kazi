defmodule Kazi.CLIApplyProposalRefTest do
  @moduledoc """
  T39.2 (ADR-0049): `kazi apply <proposal-ref>` runs an APPROVED proposal
  directly from the read-model — no goal-file on disk.

  `plan`/`approve` never write a goal-file, so before T39.2 an orchestrator had
  to RECONSTRUCT one before it could `apply` — the broken seam the T15.9
  nested-loop dogfood surfaced. These tests close it: the `prop-...` ref an
  orchestrator carries from `plan --json` through `approve --json` is accepted
  by `apply` in the goal-file position, resolved against the read-model, and
  run through the SAME converge wiring a goal-file path uses (same loader, same
  pre-loop guards). A non-approved or unknown ref is a clear non-zero error; a
  path argument behaves exactly as before, and an EXISTING file named
  `prop-...` still wins the tie as a path.

  HERMETIC, mirroring `Kazi.CLIRunJsonTest` / `Kazi.CLIHarnessTest`: the inner
  harness is a local stub script (the `:adapter_opts` `:command` seam), the
  workspace a non-git tmp dir — no real claude, no network, no git.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Authoring, ReadModel, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    work = Path.join(System.tmp_dir!(), "kazi-apply-ref-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    {:ok, work: work}
  end

  # The orchestrator's step 1: `plan --json` in caller-drafts mode, naming the
  # goal via the payload's goal_id (T39.1). Returns the minted proposal_ref.
  defp plan_proposal(goal_id) do
    payload =
      ~s({"goal_id":"#{goal_id}","idea":"converge the #{goal_id} fixture",) <>
        ~s("predicates":[{"id":"code","provider":"test_runner",) <>
        ~s("config":{"cmd":"sh","args":["-c","test -f fixed.txt"]}}]})

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["plan", "--json", "--predicates", payload]) == 0
      end)

    assert {:ok, draft} = Jason.decode(String.trim(out))
    draft["proposal_ref"]
  end

  # The orchestrator's step 2: `approve --json`.
  defp approve(ref) do
    capture_io(fn -> assert Kazi.CLI.run(["approve", ref, "--json"]) == 0 end)
    ref
  end

  # A harness stub that fixes the goal: creates the marker file the code
  # predicate checks (cwd = the workspace, via the adapter's System.cmd cd:).
  defp write_fixing_harness(work) do
    path = Path.join(work, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp run_opts(work) do
    [
      adapter_opts: [command: write_fixing_harness(work)],
      reobserve_interval_ms: 5,
      await_timeout: 15_000
    ]
  end

  # ===========================================================================
  # the closed loop: plan --json -> approve --json -> apply <prop-ref> --json
  # ===========================================================================

  describe "apply <proposal-ref> — an APPROVED proposal runs directly" do
    test "loads the approved goal from the read-model and converges it", %{work: work} do
      ref = "t39-apply-ref-converge" |> plan_proposal() |> approve()

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"], run_opts(work)) ==
                   0
        end)

      # The SAME versioned run-result contract a goal-file apply emits — the
      # converge wiring ran (observe t0 fail -> dispatch -> re-observe pass).
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["goal_id"] == "t39-apply-ref-converge"
      assert payload["status"] == "converged"
      assert payload["next_action"] == "done"

      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector == %{"code" => "pass"}

      # The fix landed IN the workspace the ref-loaded goal was run against.
      assert File.exists?(Path.join(work, "fixed.txt"))
    end
  end

  # ===========================================================================
  # non-approved / unknown refs are clear non-zero errors
  # ===========================================================================

  describe "apply <proposal-ref> — refused refs" do
    test "a proposed-but-not-approved ref is a clear JSON error, exit 1", %{work: work} do
      ref = plan_proposal("t39-not-approved")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"], run_opts(work)) ==
                   1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "proposed, not approved"
      assert message =~ "kazi approve #{ref}"

      # Nothing ran: the workspace was never touched.
      refute File.exists?(Path.join(work, "fixed.txt"))
    end

    test "a rejected ref names its actual state", %{work: work} do
      ref = plan_proposal("t39-rejected")
      capture_io(fn -> assert Kazi.CLI.run(["reject", ref, "--json"]) == 0 end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"], run_opts(work)) ==
                   1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "rejected, not approved"
    end

    test "an unknown prop- ref is a clear JSON error, exit 1", %{work: work} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", "prop-does-not-exist", "--workspace", work, "--json"],
                   run_opts(work)
                 ) == 1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "no proposal prop-does-not-exist"
    end

    test "the human surface reports the same refusal on stderr", %{work: work} do
      ref = plan_proposal("t39-human-surface")

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert Kazi.CLI.run(["apply", ref, "--workspace", work], run_opts(work)) == 1
          end)
        end)

      assert stderr =~ "proposed, not approved"
    end

    test "an approved row whose stored goal no longer loads is a clear error", %{work: work} do
      ref = plan_proposal("t39-corrupt-goal")

      # Force-approve the row with a goal map the loader refuses, simulating a
      # stored proposal that drifted out from under the loader's validation.
      assert {:ok, _row} = ReadModel.transition_proposed_goal(ref, "approved", %{"nope" => 1})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", ref, "--workspace", work, "--json"], run_opts(work)) ==
                   1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "no longer loads as a runnable goal"
    end
  end

  # ===========================================================================
  # back-compat: a path argument behaves exactly as today
  # ===========================================================================

  describe "apply <goal-file> — the path argument is unchanged" do
    test "a missing goal-file path still errors as a goal-file, not a ref", %{work: work} do
      missing = Path.join(work, "nope.toml")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", missing, "--workspace", work, "--json"], run_opts(work)) ==
                   1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "could not load goal-file"
    end

    test "an EXISTING file named prop-... loads as a path, not a proposal ref", %{work: work} do
      # An invalid goal-file whose NAME collides with the ref shape: the
      # existing file must win the tie (its goal-file load error proves the
      # path branch ran; the ref branch would have said "no proposal").
      File.write!(Path.join(work, "prop-collision.toml"), "not toml at [[[")

      out =
        capture_io(fn ->
          File.cd!(work, fn ->
            assert Kazi.CLI.run(
                     ["apply", "prop-collision.toml", "--workspace", work, "--json"],
                     run_opts(work)
                   ) == 1
          end)
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "could not load goal-file"
      refute message =~ "no proposal"
    end
  end

  # ===========================================================================
  # the Authoring seam the CLI resolves through
  # ===========================================================================

  describe "Kazi.Authoring.load_approved/1" do
    test "returns the runnable goal for an approved ref, and typed errors otherwise" do
      ref = plan_proposal("t39-load-approved")

      # Not yet approved: the state is named.
      assert {:error, {:not_approved, "proposed"}} = Authoring.load_approved(ref)

      approve(ref)
      assert {:ok, %Kazi.Goal{id: "t39-load-approved"} = goal} = Authoring.load_approved(ref)
      assert [%Kazi.Predicate{id: "code"}] = Kazi.Goal.all_predicates(goal)

      # Unknown ref.
      assert {:error, :not_found} = Authoring.load_approved("prop-missing")
    end
  end
end
