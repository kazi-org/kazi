defmodule Kazi.CLIStatusLandedTest do
  @moduledoc """
  T62.6 (issue #1241 part 2): the per-group `landed: {branch, pr, merge_commit}`
  refs a `--parallel` run computes are PERSISTED into the read-model, so `kazi
  status <run-ref> --json` shows the same per-group landing detail AFTER the run
  has exited that the immediate `apply --parallel` output carried.

  Two tiers:

    * a REAL `apply --parallel --json` run (recording integrator, hermetic
      seams) persists its landed refs; `kazi status <goal-id> --json` then
      surfaces them, matching the immediate collective output's `landed` exactly;
    * a single-goal run's status is UNAFFECTED — no `landed` key (regression
      pin) — and the read-model store round-trips a multi-group upsert.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}

  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  @moduletag :tmp_dir

  defp base_inject do
    [
      graph_source: TermSource.new(%{"a" => ["lib/a.ex"]}),
      reconciler: fn _partition, _worktree_path -> :converged end,
      reconcile_timeout: 5_000
    ]
  end

  defp write_goal(tmp_dir) do
    path = Path.join(tmp_dir, "parallel_goal.toml")

    File.write!(path, """
    id = "cli-status-landed"
    name = "CLI status landed"

    [scope]
    workspace = "#{tmp_dir}"

    [metadata]
    partition_terms = ["a"]

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "true"]
    """)

    path
  end

  # Stand in for the run's own Runtime.run persistence (the injected stub
  # reconciler bypasses it): a converged iteration so `kazi status` resolves the
  # ref to a run and then joins the persisted landed refs onto it.
  defp record_converged_iteration(goal_ref) do
    vector = PredicateVector.new(%{code: PredicateResult.new(:pass)})

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: vector,
        converged: true
      })
  end

  test "a completed --parallel run's per-group landed refs are queryable via status --json, matching the immediate output",
       %{tmp_dir: tmp_dir} do
    goal_file = write_goal(tmp_dir)

    integrator = fn request, _opts ->
      {:ok, %{pr: "pr-#{request.key}", merge_commit: "sha-#{request.key}"}}
    end

    inject = base_inject() ++ [integrate: [integrator: integrator, branch_prefix: "kazi"]]

    # The run's own immediate collective output.
    apply_out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                 inject
               ) == 0
      end)

    assert {:ok, apply_payload} = Jason.decode(String.trim(apply_out))
    assert [immediate_partition] = apply_payload["partitions"]
    immediate_landed = immediate_partition["landed"]
    assert %{"branch" => _, "pr" => _, "merge_commit" => _} = immediate_landed

    # The run has exited; only the persisted read-model remains. Its status must
    # carry the SAME per-group landing detail.
    record_converged_iteration("cli-status-landed")

    status_out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", "cli-status-landed", "--json"], inject) == 0
      end)

    assert {:ok, status_payload} = Jason.decode(String.trim(status_out))
    assert status_payload["kind"] == "run"
    assert [status_landed] = status_payload["landed"]

    # The branch/pr/merge_commit persisted and read back match the run's own
    # immediate output exactly (partition_id is the extra status-side key).
    assert status_landed["branch"] == immediate_landed["branch"]
    assert status_landed["pr"] == immediate_landed["pr"]
    assert status_landed["merge_commit"] == immediate_landed["merge_commit"]
    assert status_landed["partition_id"] == immediate_partition["partition_id"]
  end

  test "the human status block shows the persisted landed refs", %{tmp_dir: tmp_dir} do
    goal_file = write_goal(tmp_dir)

    integrator = fn request, _opts ->
      {:ok, %{pr: "pr-#{request.key}", merge_commit: "sha-#{request.key}"}}
    end

    inject = base_inject() ++ [integrate: [integrator: integrator, branch_prefix: "kazi"]]

    capture_io(fn ->
      assert Kazi.CLI.run(
               ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
               inject
             ) == 0
    end)

    record_converged_iteration("cli-status-landed")

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", "cli-status-landed"], inject) == 0
      end)

    assert out =~ "landed:"
    assert out =~ "landed=kazi/"
    assert out =~ "pr=pr-"
    assert out =~ "merge=sha-"
  end

  test "a single-goal (non-parallel) run's status omits the landed key (regression pin)" do
    # A serial run records no landed_refs → the status --json shape is
    # byte-identical to the pre-T62.6 surface (no `landed` key).
    record_converged_iteration("cli-serial-nolanded")

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", "cli-serial-nolanded", "--json"], []) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["kind"] == "run"
    refute Map.has_key?(payload, "landed")
  end

  test "the landed-ref store round-trips a multi-group upsert (schema reuses the T44.3 shape)" do
    run_ref = "multi-group-run"

    entries = [
      %{partition_id: "grp-a", branch: "kazi/grp-a", pr: "11", merge_commit: "aaa"},
      %{partition_id: "grp-b", branch: "kazi/grp-b", pr: "12", merge_commit: "bbb"}
    ]

    assert {:ok, 2} = ReadModel.record_landed_refs(run_ref, entries)

    rows = ReadModel.landed_refs(run_ref)
    assert length(rows) == 2
    assert Enum.map(rows, & &1.partition_id) == ["grp-a", "grp-b"]
    grp_a = Enum.find(rows, &(&1.partition_id == "grp-a"))
    assert grp_a.branch == "kazi/grp-a"
    assert grp_a.pr == "11"
    assert grp_a.merge_commit == "aaa"

    # A re-run UPSERTS on (run_ref, partition_id) — no duplicate rows, refs replaced.
    assert {:ok, 1} =
             ReadModel.record_landed_refs(run_ref, [
               %{partition_id: "grp-a", branch: "kazi/grp-a", pr: "99", merge_commit: "zzz"}
             ])

    rows2 = ReadModel.landed_refs(run_ref)
    assert length(rows2) == 2
    grp_a2 = Enum.find(rows2, &(&1.partition_id == "grp-a"))
    assert grp_a2.pr == "99"
    assert grp_a2.merge_commit == "zzz"
  end
end
