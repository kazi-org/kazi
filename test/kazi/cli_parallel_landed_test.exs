defmodule Kazi.CLIParallelLandedTest do
  @moduledoc """
  T44.10 (ADR-0055): the collective `apply --parallel --json` object carries a
  per-partition `landed: {branch, pr, merge_commit}` when the run landed converged
  work, and the human collective block shows it. A run WITHOUT landing (mode :none
  / no integration) omits the field entirely — byte-identical to the pre-T44.10
  partition entry (regression pin).

  Tier-2 boundary: drives the REAL CLI exec core against a goal-file on disk with
  the scheduler's injectable seams pointed at hermetic stubs (graph source +
  reconciler + a RECORDING integrator — no harness, gh, or network).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Repo

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
    id = "cli-parallel"
    name = "CLI parallel landed"

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

  test "an integrated parallel run surfaces per-partition landed refs in the JSON",
       %{tmp_dir: tmp_dir} do
    goal_file = write_goal(tmp_dir)

    integrator = fn request, _opts ->
      {:ok, %{pr: "pr-#{request.key}", merge_commit: "sha-#{request.key}"}}
    end

    inject = base_inject() ++ [integrate: [integrator: integrator, branch_prefix: "kazi"]]

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                 inject
               ) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["collective"] == "converged"
    assert [partition] = payload["partitions"]

    assert %{"branch" => branch, "pr" => pr, "merge_commit" => merge} = partition["landed"]
    assert String.starts_with?(branch, "kazi/")
    assert is_binary(pr) and pr != ""
    assert is_binary(merge) and merge != ""
  end

  test "the human collective block shows the landed branch + pr", %{tmp_dir: tmp_dir} do
    goal_file = write_goal(tmp_dir)

    integrator = fn request, _opts ->
      {:ok, %{pr: "pr-#{request.key}", merge_commit: "sha-#{request.key}"}}
    end

    inject = base_inject() ++ [integrate: [integrator: integrator, branch_prefix: "kazi"]]

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir, "--parallel"], inject) ==
                 0
      end)

    assert out =~ "COLLECTIVE CONVERGED"
    assert out =~ "landed=kazi/"
    assert out =~ "pr=pr-"
  end

  test "a run WITHOUT integration omits the landed field (mode :none regression pin)",
       %{tmp_dir: tmp_dir} do
    goal_file = write_goal(tmp_dir)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                 base_inject()
               ) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert [partition] = payload["partitions"]
    # No landing was performed → the partition entry is byte-identical to pre-T44.10.
    refute Map.has_key?(partition, "landed")
    assert Map.keys(partition) |> Enum.sort() == ["goal_ids", "partition_id", "status"]
  end
end
