defmodule Kazi.SealedPredicateTamperTest do
  @moduledoc """
  ADR-0080 (#1520) acceptance: a run whose worker edits a SEALED input mid-run
  terminates in the distinct `:tampered` hard-FAIL naming the file — never
  `:converged` — while an untampered run converges normally, and the opt-out
  (an empty seal manifest) lets the SAME tampering dispatch converge green (the
  red->green control proving the seal is what stops it).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult, Seal}

  # Code passes iff the worker wrote `fixed.txt` into the workspace. Reads the
  # per-observation `context.workspace` the loop threads in.
  defmodule MarkerCodeProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, context) do
      if File.exists?(Path.join(context.workspace, "fixed.txt")),
        do: PredicateResult.pass(%{id: id}),
        else: PredicateResult.fail(%{id: id})
    end
  end

  # A worker that fixes the code AND edits the sealed manifest to reach green —
  # the incident this feature exists for.
  defmodule TamperingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, workspace, _opts) do
      File.write!(Path.join(workspace, "fixed.txt"), "done\n")
      File.write!(Path.join(workspace, "manifest.toml"), "threshold = 0.10\n")
      {:ok, %{output: "ok", touched: ["fixed.txt", "manifest.toml"]}}
    end
  end

  # A well-behaved worker: fixes the code, never touches the sealed manifest.
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
    dir = Path.join(System.tmp_dir!(), "kazi-tamper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.toml"), "threshold = 0.99\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp start_loop(dir, harness, seal_manifest) do
    goal = Goal.new("sealed", predicates: [Predicate.new(:code, :tests)])

    Kazi.Loop.start_link(
      goal: goal,
      providers: %{tests: MarkerCodeProvider},
      harness: harness,
      integrate: NoopIntegrate,
      deploy: NoopIntegrate,
      workspace: dir,
      reobserve_interval_ms: 1,
      flake_max_retries: 0,
      seal_manifest: seal_manifest
    )
  end

  test "a worker that edits a sealed input mid-run terminates :tampered naming the file", %{
    dir: dir
  } do
    seal_manifest = Seal.arm(%Seal{sealed_inputs: ["manifest.toml"]}, nil, dir)
    {:ok, loop} = start_loop(dir, TamperingHarness, seal_manifest)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :tampered
    refute result.outcome == :converged
    assert result.reason == :tampered
    assert result.tampered_file == %{path: "manifest.toml", change: :modified}
  end

  test "an untampered run converges normally", %{dir: dir} do
    seal_manifest = Seal.arm(%Seal{sealed_inputs: ["manifest.toml"]}, nil, dir)
    {:ok, loop} = start_loop(dir, CleanFixHarness, seal_manifest)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :converged
    refute Map.has_key?(result, :tampered_file)
  end

  test "opt-out: with nothing sealed, the SAME tampering dispatch converges green", %{dir: dir} do
    # The red->green control: an empty seal manifest (what `[seal] enabled = false`
    # or no seal produces) leaves the loop free to converge even though the worker
    # edited the manifest — proving sealing is exactly what flips the tampered run.
    {:ok, loop} = start_loop(dir, TamperingHarness, %{})

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :converged
  end
end
