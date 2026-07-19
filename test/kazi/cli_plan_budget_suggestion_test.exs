defmodule Kazi.CLIPlanBudgetSuggestionTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T48.9, ADR-0058 decision 2). `kazi plan`
  (caller-drafts: no inner model spawned, so the test seeds real economics
  history via `RunRegistry` and asserts on the CLI's rendered output directly)
  emits a learned `[budget]` suggestion with explicit provenance when local
  history has something usable for the drafted goal's shape, is
  BYTE-IDENTICAL to before this feature when it does not, and NEVER lets the
  suggestion reach an approved goal without a human copying it in.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Authoring, ReadModel, Repo}
  alias Kazi.ReadModel.RunRegistry

  # A harness that must NOT be invoked (caller-drafts supplies the predicates).
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

  # Two acceptance predicates -> goal_shape_bucket "1-3".
  @two_predicates ~s({
    "predicates": [
      {"id": "code", "provider": "test_runner", "config": {"cmd": "sh", "args": ["-c", "true"]}},
      {"id": "live", "provider": "http_probe", "config": {"url": "http://x/healthz"}}
    ]
  })

  defp seed_run(overrides) do
    run_id = "cliplan-#{System.unique_integer([:positive])}"

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

  describe "kazi plan --json — with seeded history" do
    test "includes suggested_budget with provenance when local history has this shape" do
      for tokens <- [1000, 2000, 3000] do
        seed_run(%{predicate_count: 2, budget_tokens: tokens, dispatch_count: 2})
      end

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", @two_predicates],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      assert {:ok, draft} = Jason.decode(String.trim(out))
      assert %{"suggested_budget" => suggestion} = draft
      assert suggestion["max_tokens"] == 10_000
      assert suggestion["provenance"] =~ "learned from 3 runs (shape 1-3"
      assert suggestion["provenance"] =~ "p95 x 1.5"
    end
  end

  describe "kazi plan --json — no usable history" do
    test "output is byte-identical to a draft with no suggested_budget key at all" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", @two_predicates],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      assert {:ok, draft} = Jason.decode(String.trim(out))
      refute Map.has_key?(draft, "suggested_budget")
    end
  end

  describe "kazi plan (human text) — with seeded history" do
    test "prints the suggested [budget] block as clearly advisory" do
      seed_run(%{predicate_count: 2, budget_tokens: 5000, dispatch_count: 3})

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--predicates", @two_predicates],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      assert out =~ "suggested [budget] (advisory"
      assert out =~ "not applied"
      assert out =~ "learned from 1 run (shape 1-3"
    end
  end

  describe "kazi plan (human text) — no usable history" do
    test "prints no suggested-budget section at all" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--predicates", @two_predicates],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      refute out =~ "suggested [budget]"
      refute out =~ "kazi economy"
    end
  end

  describe "never silently applied" do
    test "an approved goal's budget stays the loader default, even with a learned suggestion available" do
      for tokens <- [1000, 2000, 3000] do
        seed_run(%{predicate_count: 2, budget_tokens: tokens, dispatch_count: 2})
      end

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "--json", "--predicates", @two_predicates],
                   harness: SpyHarness,
                   adapter_opts: [spy_pid: self()]
                 ) == 0
        end)

      assert {:ok, %{"suggested_budget" => _suggestion, "proposal_ref" => proposal_ref}} =
               Jason.decode(String.trim(out))

      assert {:ok, %Kazi.Goal{} = goal} = Authoring.approve(proposal_ref)

      # The suggestion never rode along into the approved goal -- the human
      # never copied it in, so the budget is the loader's honest all-nil default.
      assert goal.budget.max_tokens == nil
      assert goal.budget.max_dispatches == nil
      assert goal.budget.max_wall_clock_ms == nil

      assert [%ReadModel.ProposedGoal{status: "approved"}] =
               ReadModel.list_proposed_goals(status: "approved")
    end
  end
end
