defmodule Kazi.RenderedNodeDriftTest do
  @moduledoc """
  T72.6 (ADR-0086 decision 5) acceptance: a run whose worker edits the
  rendered `AGENTS.md` node mid-run terminates in the distinct
  `:rendered_node_drift` hard-FAIL naming the path — never `:converged` —
  while an untampered run converges normally, and the opt-out (an empty
  rendered-node manifest, what an unscoped goal produces) lets the SAME edit
  dispatch converge green (the red->green control proving the freshness
  check is what stops it). Mirrors `Kazi.SealedPredicateTamperTest`'s (ADR-0080)
  shape exactly, at the `Kazi.Loop` level with a directly-supplied
  `rendered_node_manifest` — `Kazi.Plan.Freshness`'s own unit tests
  (`test/kazi/plan/freshness_test.exs`) cover `arm/1`/`verify/1` in
  isolation.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Plan.Freshness, Predicate, PredicateResult}

  # Code passes iff the worker wrote `fixed.txt` into the workspace.
  defmodule MarkerCodeProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, context) do
      if File.exists?(Path.join(context.workspace, "fixed.txt")),
        do: PredicateResult.pass(%{id: id}),
        else: PredicateResult.fail(%{id: id})
    end
  end

  # A worker that fixes the code AND hand-edits the rendered node — the
  # incident this feature exists for (a converging agent could otherwise
  # smuggle acceptance-bar content into the dispatch-context node itself).
  defmodule NodeEditingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, workspace, _opts) do
      File.write!(Path.join(workspace, "fixed.txt"), "done\n")
      File.write!(Path.join([workspace, "pkg", "foo", "AGENTS.md"]), "# hand-edited\n")
      {:ok, %{output: "ok", touched: ["fixed.txt", "pkg/foo/AGENTS.md"]}}
    end
  end

  # A well-behaved worker: fixes the code, never touches the rendered node.
  defmodule CleanFixHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, workspace, _opts) do
      File.write!(Path.join(workspace, "fixed.txt"), "done\n")
      {:ok, %{output: "ok", touched: ["fixed.txt"]}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{}, _context), do: {:ok, %{}}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-node-drift-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "pkg/foo"))
    File.write!(Path.join([dir, "pkg", "foo", "AGENTS.md"]), "# GENERATED\nrendered node\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp start_loop(dir, harness, rendered_node_manifest) do
    goal = Goal.new("scoped", predicates: [Predicate.new(:code, :tests)])

    Kazi.Loop.start_link(
      goal: goal,
      providers: %{tests: MarkerCodeProvider},
      harness: harness,
      integrate: NoopIntegrate,
      deploy: NoopIntegrate,
      workspace: dir,
      reobserve_interval_ms: 1,
      flake_max_retries: 0,
      rendered_node_manifest: rendered_node_manifest
    )
  end

  test "a worker that edits the rendered node mid-run terminates :rendered_node_drift naming the path",
       %{dir: dir} do
    agents_path = Path.join([dir, "pkg", "foo", "AGENTS.md"])
    manifest = Freshness.arm([%{agents_path: agents_path}])
    {:ok, loop} = start_loop(dir, NodeEditingHarness, manifest)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :rendered_node_drift
    refute result.outcome == :converged
    assert result.reason == :rendered_node_drift
    assert result.drifted_node == %{path: agents_path, change: :modified}
  end

  test "an untampered run converges normally", %{dir: dir} do
    agents_path = Path.join([dir, "pkg", "foo", "AGENTS.md"])
    manifest = Freshness.arm([%{agents_path: agents_path}])
    {:ok, loop} = start_loop(dir, CleanFixHarness, manifest)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :converged
    refute Map.has_key?(result, :drifted_node)
  end

  test "opt-out: with nothing rendered, the SAME edit dispatch converges green", %{dir: dir} do
    # The red->green control: an empty manifest (what an unscoped goal
    # produces) leaves the loop free to converge even though the worker
    # edited the file — proving the freshness check is exactly what flips
    # the drifted run.
    {:ok, loop} = start_loop(dir, NodeEditingHarness, %{})

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :converged
  end
end
