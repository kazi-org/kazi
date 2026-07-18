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

  describe "blocker attribution (T64.2, UC-033/UC-061)" do
    setup do
      on_exit(fn -> Application.delete_env(:kazi, :starmap_roadmap_goal) end)
    end

    defp record_red(goal_ref, id, iterations) do
      for i <- 1..iterations do
        {:ok, _} =
          Kazi.ReadModel.record_iteration(%{
            goal_ref: goal_ref,
            iteration_index: i,
            predicate_vector: %{id => Kazi.PredicateResult.fail()}
          })
      end
    end

    defp blocked_entry(goal_ref) do
      %{buckets: %{blocked: blocked}} = Portfolio.build()
      Enum.find(blocked, &(&1.goal_ref == goal_ref))
    end

    test "a stuck run names its persistently-red predicate slice" do
      run = start_run(%{goal_ref: "stuck-probe"})
      record_red("stuck-probe", "probe", 3)
      {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

      entry = blocked_entry("stuck-probe")

      assert entry.cause == :stuck
      assert entry.red_predicates == [%{id: "probe", red_iterations: 3}]
      assert Portfolio.blocker_label(entry) == "blocked: probe red 3 iterations"
    end

    test "a DAG-blocked goal names the dep it waits on" do
      b = Kazi.Goal.Group.new("b", "B")
      d = Kazi.Goal.Group.new("d", "D", needs: ["b"])
      Application.put_env(:kazi, :starmap_roadmap_goal, Kazi.Goal.new("roadmap", groups: [b, d]))

      stuck = start_run(%{goal_ref: "b"})
      {:ok, _} = RunRegistry.finish(stuck.run_id, "stuck")

      entry = blocked_entry("d")

      assert entry.cause == :dag
      assert entry.blocked_by == "b"
      assert Portfolio.blocker_label(entry) == "blocked by: b"
    end

    test "an over_budget run names iterations over its cap" do
      run = start_run(%{goal_ref: "ob", max_iterations: 8})
      record_red("ob", "probe", 8)
      {:ok, _} = RunRegistry.finish(run.run_id, "over_budget")

      entry = blocked_entry("ob")

      assert entry.cause == :over_budget
      assert entry.iterations == 8
      assert entry.cap == 8
      assert Portfolio.blocker_label(entry) == "blocked: 8/8 iterations"
    end

    test "no blocked entry renders without a cause" do
      b = Kazi.Goal.Group.new("b", "B")
      d = Kazi.Goal.Group.new("d", "D", needs: ["b"])
      Application.put_env(:kazi, :starmap_roadmap_goal, Kazi.Goal.new("roadmap", groups: [b, d]))

      stuck = start_run(%{goal_ref: "b"})
      record_red("b", "probe", 2)
      {:ok, _} = RunRegistry.finish(stuck.run_id, "stuck")

      ob = start_run(%{goal_ref: "ob", max_iterations: 4})
      {:ok, _} = RunRegistry.finish(ob.run_id, "over_budget")

      %{buckets: %{blocked: blocked}} = Portfolio.build()

      assert blocked != []

      Enum.each(blocked, fn entry ->
        assert Map.has_key?(entry, :cause)
        assert is_binary(Portfolio.blocker_label(entry))
      end)
    end
  end

  describe "honest rate (T64.3, UC-061/UC-033)" do
    defp record_vector(goal_ref, index, vector) do
      {:ok, _} =
        Kazi.ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: index,
          predicate_vector: vector
        })
    end

    test "a running goal's rate is green/total from the last vector + red->green movement" do
      start_run(%{goal_ref: "rate-goal"})

      # iteration 1: 4/8 green; iteration 2: 5/8 green (one predicate flipped
      # red->green) -> preds 5/8, +1.
      pass = Kazi.PredicateResult.pass()
      fail = Kazi.PredicateResult.fail()

      v1 = Map.new(1..8, fn i -> {"p#{i}", if(i <= 4, do: pass, else: fail)} end)
      v2 = Map.put(v1, "p5", pass)

      record_vector("rate-goal", 1, v1)
      record_vector("rate-goal", 2, v2)

      %{buckets: %{running: running}, rate: fleet} = Portfolio.build()
      entry = Enum.find(running, &(&1.goal_ref == "rate-goal"))

      assert entry.rate == %{green: 5, total: 8, delta: 1}
      assert Portfolio.rate_label(entry.rate) == "preds 5/8, +1 this run"

      refute fleet.empty?
      assert fleet.green == 5 and fleet.total == 8 and fleet.delta == 1
    end

    test "a running goal with no recorded iterations has a nil rate (honest-unknown)" do
      start_run(%{goal_ref: "no-iters"})

      %{buckets: %{running: running}} = Portfolio.build()
      entry = Enum.find(running, &(&1.goal_ref == "no-iters"))

      assert entry.rate == nil
      assert Portfolio.rate_label(nil) == "no iterations yet"
    end

    test "the fleet rate is empty when no running goal has a recorded rate" do
      %{rate: fleet} = Portfolio.build()
      assert fleet.empty?
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
