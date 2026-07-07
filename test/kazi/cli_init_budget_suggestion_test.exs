defmodule Kazi.CLIInitBudgetSuggestionTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T48.9, ADR-0058 decision 2). `kazi init`
  (`Kazi.Adopt`) has never required the read-model (ADR-0013: pure filesystem
  detection); this pins that a SEEDED read-model makes a learned `[budget]`
  suggestion appear as a COMMENTED block in the generated goal-file, and that
  the existing hermetic, DB-free `kazi init` behavior (`Kazi.AdoptE2ETest`)
  stays byte-identical when history has nothing usable -- the two tests
  together prove `suggest/2`'s best-effort read-model access degrades
  gracefully rather than becoming a new hard dependency.
  """
  use ExUnit.Case, async: false

  alias Kazi.Goal.Loader
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  @fixture_repo "fixtures/deploy-target"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp seed_run(overrides) do
    run_id = "cliinit-#{System.unique_integer([:positive])}"

    base = %{
      run_id: run_id,
      pid: "#PID<0.1.0>",
      workspace: "/tmp/ws",
      goal_ref: "goal-#{run_id}",
      harness: "claude",
      model: "claude-sonnet-5"
    }

    attrs = Map.merge(base, Map.take(overrides, [:goal_ref, :harness, :model]))
    {:ok, _run} = RunRegistry.start(attrs)

    economics =
      Map.take(overrides, [:budget_tokens, :budget_cost_usd, :dispatch_count, :predicate_count])

    {:ok, finished} =
      RunRegistry.finish(run_id, Map.get(overrides, :status, "converged"), economics)

    finished
  end

  describe "kazi init — with seeded history matching the adopted shape" do
    @describetag :tmp_dir

    test "writes a COMMENTED [budget] suggestion with provenance", %{tmp_dir: tmp_dir} do
      # `fixtures/deploy-target` (go.mod, no coverage marker) adopts to exactly
      # 2 predicates (1 acceptance + 1 baseline guard) -> bucket "1-3".
      for tokens <- [1000, 2000, 3000] do
        seed_run(%{predicate_count: 2, budget_tokens: tokens, dispatch_count: 2})
      end

      out = Path.join(tmp_dir, "deploy-target.goal.toml")

      {code, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      assert code == 0

      toml = File.read!(out)
      assert toml =~ "# suggested by kazi economy: learned from 3 runs (shape 1-3"
      assert toml =~ "# [budget]"
      assert toml =~ "# max_tokens = 10000"

      # Still a comment: the generated goal-file loads with the loader's
      # honest all-nil budget default, never the suggested ceilings.
      assert {:ok, goal} = Loader.load(out)
      assert goal.budget.max_tokens == nil
    end
  end

  describe "kazi init — no matching history" do
    @describetag :tmp_dir

    test "output carries no suggested-budget comment at all", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "deploy-target.goal.toml")

      {code, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      assert code == 0

      toml = File.read!(out)
      refute toml =~ "suggested by kazi economy"
      refute toml =~ "[budget]"
    end
  end
end
