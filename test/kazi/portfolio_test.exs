defmodule Kazi.PortfolioTest do
  @moduledoc """
  T60.4 (#1160): the fleet's portfolio state, composed purely from the run
  registry, proposed goals, the attention queue, and the cross-machine bus
  facts T60.1 posts. `Kazi.Portfolio.build/0` is exercised against a real
  read-model (Tier 2, ADR-0057 conventions) with the bus fetch injected so no
  daemon is needed.
  """
  use ExUnit.Case, async: false

  alias Kazi.Portfolio
  alias Kazi.ReadModel.{ProposedGoal, RunRegistry}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)
    on_exit(fn -> Application.delete_env(:kazi, :remote_run_facts_fetcher) end)
  end

  defp run_attrs(overrides) do
    Map.merge(
      %{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.123.0>",
        workspace: "/tmp/ws",
        goal_ref: "goal-#{System.unique_integer([:positive])}",
        harness: "claude",
        model: "claude-sonnet-5"
      },
      overrides
    )
  end

  defp start_run(overrides) do
    {:ok, run} = RunRegistry.start(run_attrs(overrides))
    run
  end

  defp propose(overrides) do
    attrs =
      Map.merge(
        %{
          proposal_ref: "prop-#{System.unique_integer([:positive])}",
          idea: "an idea",
          goal_id: "goal-#{System.unique_integer([:positive])}",
          status: "proposed",
          goal: %{}
        },
        overrides
      )

    {:ok, row} = %ProposedGoal{} |> ProposedGoal.changeset(attrs) |> Repo.insert()
    row
  end

  describe "planned" do
    test "includes proposed and approved proposals, excludes rejected" do
      p = propose(%{status: "proposed"})
      a = propose(%{status: "approved"})
      _r = propose(%{status: "rejected"})

      portfolio = Portfolio.build()
      refs = Enum.map(portfolio.planned, & &1.proposal_ref)

      assert p.proposal_ref in refs
      assert a.proposal_ref in refs
      assert length(portfolio.planned) == 2
    end
  end

  describe "by_repo" do
    test "a fresh running run is in_progress" do
      run = start_run(%{workspace: "/tmp/org-a/repo-a", goal_ref: "in-progress-goal"})

      portfolio = Portfolio.build()

      assert run.goal_ref in Enum.map(
               portfolio.by_repo["org-a/repo-a"][:in_progress],
               & &1.goal_ref
             )
    end

    test "a converged run is complete" do
      run = start_run(%{workspace: "/tmp/org-b/repo-b", goal_ref: "done-goal"})
      {:ok, _} = RunRegistry.finish(run.run_id, "converged")

      portfolio = Portfolio.build()

      assert run.goal_ref in Enum.map(portfolio.by_repo["org-b/repo-b"][:complete], & &1.goal_ref)
      refute Map.has_key?(portfolio.by_repo["org-b/repo-b"], :in_progress)
    end

    test "a stuck-status run is stuck" do
      run = start_run(%{workspace: "/tmp/org-c/repo-c", goal_ref: "stuck-goal"})
      {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

      portfolio = Portfolio.build()

      assert run.goal_ref in Enum.map(portfolio.by_repo["org-c/repo-c"][:stuck], & &1.goal_ref)
    end

    test "bucket/2 classifies a live run the attention queue flagged as stuck" do
      run = start_run(%{workspace: "/tmp/ws"})
      flagged = MapSet.new([run.goal_ref])

      assert Portfolio.bucket(run, flagged) == :stuck
      assert Portfolio.bucket(run, MapSet.new()) == :in_progress
    end

    test "runs from different workspaces group under different repo keys" do
      start_run(%{workspace: "/tmp/org-x/repo-x", goal_ref: "gx"})
      start_run(%{workspace: "/tmp/org-y/repo-y", goal_ref: "gy"})

      portfolio = Portfolio.build()

      assert Map.has_key?(portfolio.by_repo, "org-x/repo-x")
      assert Map.has_key?(portfolio.by_repo, "org-y/repo-y")
    end
  end

  describe "five-bucket model + totals (T64.1)" do
    setup do
      on_exit(fn -> Application.delete_env(:kazi, :starmap_roadmap_goal) end)
    end

    # A roadmap goal `b needs a`: when `a` is stuck, `b` is DAG-blocked (poisoned
    # by its ancestor) — the SAME `DagSnapshot`/`DepGraph` reachability mission
    # control's roadmap fold uses. The stuck run for `a` also seeds the blocked
    # bucket's OTHER cause.
    defp seed_roadmap_ab do
      a = Kazi.Goal.Group.new("a", "A")
      b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
      Application.put_env(:kazi, :starmap_roadmap_goal, Kazi.Goal.new("roadmap", groups: [a, b]))
    end

    test "classifies the acc fixture exactly into the five buckets" do
      seed_roadmap_ab()

      # 1 proposed, 2 approved-unrun.
      propose(%{status: "proposed"})
      propose(%{status: "approved", goal_id: "todo-1"})
      propose(%{status: "approved", goal_id: "todo-2"})

      # 3 running.
      for i <- 1..3, do: start_run(%{goal_ref: "running-#{i}"})

      # 1 stuck — the DAG ancestor `a`.
      stuck = start_run(%{goal_ref: "a"})
      {:ok, _} = RunRegistry.finish(stuck.run_id, "stuck")

      # 5 converged.
      for i <- 1..5 do
        r = start_run(%{goal_ref: "done-#{i}"})
        {:ok, _} = RunRegistry.finish(r.run_id, "converged")
      end

      %{buckets: b} = Portfolio.build()

      assert length(b.planned) == 1
      assert length(b.todo) == 2
      assert length(b.running) == 3
      assert length(b.done) == 5

      # todo goals are NOT also counted as planned.
      todo_goals = Enum.map(b.todo, & &1.goal_id)
      assert "todo-1" in todo_goals and "todo-2" in todo_goals
      refute Enum.any?(b.planned, &(&1.goal_id in todo_goals))

      # blocked = the stuck run (`a`) + the DAG-blocked group (`b`), distinct causes.
      assert length(b.blocked) == 2
      causes = b.blocked |> Enum.map(& &1.cause) |> Enum.sort()
      assert causes == [:dag, :stuck]

      dag_entry = Enum.find(b.blocked, &(&1.cause == :dag))
      assert dag_entry.goal_ref == "b"
      assert dag_entry.blocked_by == "a"
    end

    test "totals are integer percentages summing to 100" do
      seed_roadmap_ab()

      propose(%{status: "proposed"})
      propose(%{status: "approved", goal_id: "todo-1"})
      propose(%{status: "approved", goal_id: "todo-2"})
      for i <- 1..3, do: start_run(%{goal_ref: "running-#{i}"})
      stuck = start_run(%{goal_ref: "a"})
      {:ok, _} = RunRegistry.finish(stuck.run_id, "stuck")

      for i <- 1..5 do
        r = start_run(%{goal_ref: "done-#{i}"})
        {:ok, _} = RunRegistry.finish(r.run_id, "converged")
      end

      %{totals: totals} = Portfolio.build()

      refute totals.empty?
      assert totals.base == 13
      assert Enum.all?(totals.rows, &is_integer(&1.pct))
      assert totals.rows |> Enum.map(& &1.pct) |> Enum.sum() == 100

      counts = Map.new(totals.rows, &{&1.bucket, &1.count})
      assert counts == %{done: 5, running: 3, blocked: 2, todo: 2, planned: 1}
    end

    test "an empty read-model yields the empty message flag, no divide-by-zero" do
      %{totals: totals, buckets: buckets} = Portfolio.build()

      assert totals.empty?
      assert totals.base == 0
      assert Enum.all?(totals.rows, &(&1.count == 0 and &1.pct == 0))
      assert Enum.all?(Map.values(buckets), &(&1 == []))
    end
  end

  describe "fleet_remote (cross-machine, T60.1)" do
    test "a remote fact for a goal not present locally renders as a fleet_remote entry" do
      Application.put_env(:kazi, :remote_run_facts_fetcher, fn ->
        [%{"topic" => "run:abcdef12", "machine" => "mini", "text" => "started remote-goal"}]
      end)

      portfolio = Portfolio.build()

      assert [%{goal_ref: "remote-goal", bucket: :in_progress, machine: "mini"}] =
               portfolio.fleet_remote
    end

    test "a remote fact for a goal ALSO present locally is not duplicated" do
      start_run(%{goal_ref: "shared-goal"})

      Application.put_env(:kazi, :remote_run_facts_fetcher, fn ->
        [%{"topic" => "run:abcdef12", "machine" => "mini", "text" => "started shared-goal"}]
      end)

      portfolio = Portfolio.build()

      assert portfolio.fleet_remote == []
    end

    test "a fact from this machine is excluded" do
      Application.put_env(:kazi, :remote_run_facts_fetcher, fn ->
        [
          %{
            "topic" => "run:abcdef12",
            "machine" => Kazi.Bus.hostname(),
            "text" => "started local-goal"
          }
        ]
      end)

      portfolio = Portfolio.build()

      assert portfolio.fleet_remote == []
    end

    test "a bus fetch failure degrades to zero remote entries, local portfolio unaffected" do
      run = start_run(%{workspace: "/tmp/ws"})
      Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> raise "no daemon" end)

      portfolio = Portfolio.build()

      assert portfolio.fleet_remote == []
      assert run.goal_ref in Enum.map(portfolio.by_repo["tmp/ws"][:in_progress], & &1.goal_ref)
    end
  end
end
