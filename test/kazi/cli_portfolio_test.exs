defmodule Kazi.CLIPortfolioTest do
  @moduledoc """
  E64/T64.3: `kazi portfolio` renders the sitrep — a headline percentage line,
  each bucket's top-3 one-liners + "+N more" (`--full` restores the complete
  ledger), and the honest fleet-wide rate (never a projected date, ADR-0046).
  Drives the real `Kazi.CLI.run/2` entry point against a real read-model; the
  bus fetch is injected so no daemon is needed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.{ProposedGoal, RunRegistry}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:kazi, :remote_run_facts_fetcher)
      Application.delete_env(:kazi, :starmap_roadmap_goal)
    end)

    :ok
  end

  defp start_run(overrides) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.123.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
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

  # The T64.1 acc fixture: 1 proposed, 2 approved-unrun, 3 running, 1 stuck (the
  # DAG ancestor `a`), 5 converged -> base 13; percentages
  # done 39% (5) | in-progress 23% (3) | blocked 15% (2) | todo 15% (2) | planned 8% (1).
  defp seed_acc_fixture do
    a = Kazi.Goal.Group.new("a", "A")
    b = Kazi.Goal.Group.new("b", "B", needs: ["a"])
    Application.put_env(:kazi, :starmap_roadmap_goal, Kazi.Goal.new("roadmap", groups: [a, b]))

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
  end

  test "the headline renders first with the fixture's exact percentages" do
    seed_acc_fixture()

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)

    [headline | _rest] = String.split(out, "\n")

    assert headline ==
             "done 39% (5) | in-progress 23% (3) | blocked 15% (2) | todo 15% (2) | planned 8% (1)"
  end

  test "an empty read-model renders the honest empty headline" do
    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)
    assert String.starts_with?(out, "nothing tracked yet")
  end

  test "a bucket with 5 entries shows 3 + '+2 more'; --full shows all 5" do
    for i <- 1..5 do
      r = start_run(%{goal_ref: "done-#{i}"})
      {:ok, _} = RunRegistry.finish(r.run_id, "converged")
    end

    bounded = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)
    assert bounded =~ "DONE (5):"
    assert bounded =~ "+2 more"
    assert length(for line <- String.split(bounded, "\n"), line =~ ~r/^  done-\d/, do: line) == 3

    full = capture_io(fn -> assert Kazi.CLI.run(["portfolio", "--full"], []) == 0 end)
    refute full =~ "more"
    assert length(for line <- String.split(full, "\n"), line =~ ~r/^  done-\d/, do: line) == 5
  end

  test "an in-progress goal renders its honest predicates-green rate (4/8 -> 5/8 => +1)" do
    start_run(%{goal_ref: "rate-goal"})

    pass = Kazi.PredicateResult.pass()
    fail = Kazi.PredicateResult.fail()
    v1 = Map.new(1..8, fn i -> {"p#{i}", if(i <= 4, do: pass, else: fail)} end)
    v2 = Map.put(v1, "p5", pass)

    {:ok, _} =
      Kazi.ReadModel.record_iteration(%{
        goal_ref: "rate-goal",
        iteration_index: 1,
        predicate_vector: v1
      })

    {:ok, _} =
      Kazi.ReadModel.record_iteration(%{
        goal_ref: "rate-goal",
        iteration_index: 2,
        predicate_vector: v2
      })

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)

    assert out =~ "preds 5/8, +1 this run"
    assert out =~ "fleet rate: 5/8 preds green, +1 this run"
  end

  test "a blocked entry names its blocker via T64.2's blocker_label" do
    run = start_run(%{goal_ref: "stuck-probe"})
    record_red("stuck-probe", "probe", 3)
    {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)

    assert out =~ "BLOCKED (1):"
    assert out =~ "blocked: probe red 3 iterations"
  end

  test "the output contains no date/ETA token (ADR-0046 no-projection pin)" do
    seed_acc_fixture()
    start_run(%{goal_ref: "rate-goal"})
    record_red("rate-goal", "probe", 2)

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio"], []) == 0 end)

    refute out =~ ~r/\d{4}-\d{2}-\d{2}/
    refute out =~ ~r/\beta\b/i
    refute out =~ ~r/\bestimated?\b/i
    refute out =~ ~r/\bby [A-Z][a-z]+ \d/
    refute out =~ ~r/\bprojected\b/i
  end

  test "v1 --json keys are byte-identical and new keys are additive" do
    seed_acc_fixture()

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio", "--json"], []) == 0 end)
    decoded = Jason.decode!(String.trim(out))

    # v1 conformance pin: the T60.4 keys are present and unchanged in shape.
    assert decoded["schema_version"] == 2
    assert decoded["kind"] == "portfolio"
    assert is_list(decoded["planned"])
    assert is_map(decoded["by_repo"])
    assert is_list(decoded["fleet_remote"])

    # E64/T64.3 additive keys.
    assert decoded["totals"]["base"] == 13
    assert Enum.sum(Enum.map(decoded["totals"]["rows"], & &1["pct"])) == 100
    assert length(decoded["todo"]) == 2
    assert length(decoded["blocked"]) == 2
    assert Enum.all?(decoded["blocked"], &is_binary(&1["blocker"]))
    assert Map.has_key?(decoded, "rate")
  end

  test "kazi help --json lists --full among portfolio's flags" do
    out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"], []) == 0 end)
    decoded = Jason.decode!(String.trim(out))

    portfolio = Enum.find(decoded["commands"], &(&1["name"] == "portfolio"))
    flag_names = Enum.map(portfolio["flags"], & &1["name"])

    assert "--full" in flag_names
  end
end
