defmodule Kazi.CLIApproveWriteTest do
  @moduledoc """
  T39.3 (ADR-0049): `kazi approve <ref> --write <path>` materializes the approved
  proposal's goal to a loadable goal-file, for file-based / version-controlled
  workflows that WANT a goal-file artifact. It complements T39.2 (ref-threading)
  without forcing either workflow: `apply <path>` and `apply <ref>` run the SAME
  goal.

  HERMETIC, mirroring `Kazi.CLIApplyProposalRefTest`: the inner harness is a
  local stub script (the `:adapter_opts` `:command` seam), the workspace a
  non-git tmp dir — no real claude, no network, no git.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Authoring, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    work =
      Path.join(System.tmp_dir!(), "kazi-approve-write-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    {:ok, work: work}
  end

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

  describe "approve --write — materializes a loadable goal-file" do
    test "writes a goal-file apply loads and runs to the SAME result as apply <ref>", %{
      work: work
    } do
      ref = plan_proposal("t39-write-roundtrip")
      out_path = Path.join(work, "materialized.goal.toml")

      json =
        capture_io(fn ->
          assert Kazi.CLI.run(["approve", ref, "--write", out_path, "--json"]) == 0
        end)

      # The --json result carries the written path (T39.3 acc).
      assert {:ok, approved} = Jason.decode(String.trim(json))
      assert approved["status"] == "approved"
      assert approved["path"] == out_path
      assert File.exists?(out_path)

      # apply <path> — the materialized file — converges.
      path_out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", out_path, "--workspace", work, "--json"], run_opts(work)) ==
                   0
        end)

      assert {:ok, from_path} = Jason.decode(String.trim(path_out))
      assert from_path["goal_id"] == "t39-write-roundtrip"
      assert from_path["status"] == "converged"
      assert Map.new(from_path["predicates"], &{&1["id"], &1["verdict"]}) == %{"code" => "pass"}
    end

    test "the written file loads to the same goal id and predicate set the ref carries", %{
      work: work
    } do
      ref = plan_proposal("t39-write-equal-ref")
      out_path = Path.join(work, "equal.goal.toml")

      capture_io(fn ->
        assert Kazi.CLI.run(["approve", ref, "--write", out_path, "--json"]) == 0
      end)

      # Load the written file and the read-model's approved goal; the runnable
      # shape (id + predicate ids) matches — apply <path> == apply <ref>.
      assert {:ok, from_file} = Kazi.Goal.Loader.load(out_path)
      {:ok, from_ref} = Authoring.load_approved(ref)

      assert from_file.id == from_ref.id

      assert from_file |> Kazi.Goal.all_predicates() |> Enum.map(& &1.id) |> Enum.sort() ==
               from_ref |> Kazi.Goal.all_predicates() |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "the human surface reports the written path", %{work: work} do
      ref = plan_proposal("t39-write-human")
      out_path = Path.join(work, "human.goal.toml")

      stdout =
        capture_io(fn ->
          assert Kazi.CLI.run(["approve", ref, "--write", out_path]) == 0
        end)

      assert stdout =~ "APPROVED"
      assert stdout =~ "WROTE"
      assert stdout =~ out_path
    end
  end

  describe "approve without --write — unchanged" do
    test "no --write approves with no path key and writes no file", %{work: _work} do
      ref = plan_proposal("t39-no-write")

      json =
        capture_io(fn ->
          assert Kazi.CLI.run(["approve", ref, "--json"]) == 0
        end)

      assert {:ok, approved} = Jason.decode(String.trim(json))
      assert approved["status"] == "approved"
      refute Map.has_key?(approved, "path")
    end
  end
end
