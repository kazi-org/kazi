defmodule Kazi.Fleet.ExecutionTest do
  @moduledoc """
  T50.5 (ADR-0065 decision 3): `kazi apply --fleet` EXECUTES the T50.4 goal-DAG
  through the partition scheduler one level up. Pinned contract:

    1. pipelined frontier advancement — a member dispatches the instant its
       deps settle (a still-running sibling does not gate it);
    2. REAL isolation — each member runs in its own kazi-owned task worktree;
       the base checkout is byte-identical after; worktrees are cleaned up
       (their during-run existence observed via the registry rows' workspace
       fields);
    3. `--fleet-concurrency 1` serializes member execution;
    4. the terminal object carries the collective verdict, per-member
       statuses, and the honest-unknown economy rollup;
    5. a registry row exists PER member while it executes (list_live during
       the run) and reaches a terminal status after;
    6. fleet frontier_complete events emit at frontier boundaries through the
       `:on_frontier_complete` stream seam;
    7. a converged member's COMMITTED work lands on the base (the T50.2 path).

  Hermetic tests drive `Kazi.Fleet.Execution.run/2` with a gated stub member
  runner (mirroring `pause_between_waves_test.exs`); real-path tests drive the
  CLI against fixture git repos with a stub harness command. No network.
  """

  # Registry rows + landing are written from the scheduler's reconciler tasks
  # (not the test process) — shared sandbox mode so those writes are visible.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.CLI
  alias Kazi.Fleet
  alias Kazi.ReadModel.Run
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo
  alias Kazi.Scheduler.PartitionSupervisor

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  # ---------------------------------------------------------------------------
  # 1. pipelined frontier advancement
  # ---------------------------------------------------------------------------

  test "pipelined: A and B dispatch first; C dispatches the instant A settles, while B is still running",
       %{tmp_dir: tmp_dir, sup: sup} do
    fleet = load_fleet!(fleet_dir(tmp_dir))
    test_pid = self()

    task =
      Task.async(fn ->
        Kazi.Fleet.Execution.run(fleet,
          workspace: tmp_dir,
          supervisor: sup,
          member_runner: gated_runner(test_pid)
        )
      end)

    assert_receive {:member_started, "a", a_pid}, 2_000
    assert_receive {:member_started, "b", b_pid}, 2_000
    refute_receive {:member_started, "c", _}, 50

    # A settles; B is STILL RUNNING (unreleased) — C must dispatch anyway.
    send(a_pid, {:release, "a", %{status: :converged}})
    assert_receive {:member_started, "c", c_pid}, 2_000

    release_all([{"b", b_pid}, {"c", c_pid}], :converged)

    assert {:ok, result} = Task.await(task, 10_000)
    assert result.collective == :converged
    assert result.members == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
  end

  # ---------------------------------------------------------------------------
  # 3. --fleet-concurrency 1 serializes
  # ---------------------------------------------------------------------------

  test "fleet_concurrency 1: at no point do two members run concurrently", %{
    tmp_dir: tmp_dir,
    sup: sup
  } do
    fleet = load_fleet!(fleet_dir(tmp_dir))
    test_pid = self()

    task =
      Task.async(fn ->
        Kazi.Fleet.Execution.run(fleet,
          workspace: tmp_dir,
          supervisor: sup,
          fleet_concurrency: 1,
          member_runner: gated_runner(test_pid)
        )
      end)

    # Frontier 0 dispatches BOTH a and b, but the gate admits exactly one
    # runner at a time: a second :member_started must not arrive until the
    # first member is released.
    assert_receive {:member_started, first, first_pid}, 2_000
    refute_receive {:member_started, _other, _}, 50

    send(first_pid, {:release, first, %{status: :converged}})
    assert_receive {:member_started, second, second_pid}, 2_000
    assert second != first
    refute_receive {:member_started, _another, _}, 50

    send(second_pid, {:release, second, %{status: :converged}})
    assert_receive {:member_started, "c", c_pid}, 2_000
    send(c_pid, {:release, "c", %{status: :converged}})

    assert {:ok, result} = Task.await(task, 10_000)
    assert result.collective == :converged
  end

  # ---------------------------------------------------------------------------
  # 4. terminal object: collective + per-member statuses + honest-unknown economy
  # ---------------------------------------------------------------------------

  test "economy rollup sums reporting members dimension-wise; an unreporting member contributes nil, never zeros",
       %{tmp_dir: tmp_dir, sup: sup} do
    fleet = load_fleet!(fleet_dir(tmp_dir))

    economies = %{
      "a" => %{iterations: 2, elapsed_ms: 10, tokens: 100},
      "b" => %{iterations: 1, elapsed_ms: 5, tokens: 50},
      # honest-unknown: c's run reported no usage envelope.
      "c" => nil
    }

    runner = fn %Fleet.Node{id: id} ->
      %{status: :converged, economy: Map.fetch!(economies, id)}
    end

    assert {:ok, result} =
             Kazi.Fleet.Execution.run(fleet,
               workspace: tmp_dir,
               supervisor: sup,
               member_runner: runner
             )

    assert result.collective == :converged
    assert result.members == [{"a", :converged}, {"b", :converged}, {"c", :converged}]

    assert result.economy == %{
             members_total: 3,
             members_reported: 2,
             totals: %{iterations: 3, elapsed_ms: 15, tokens: 150}
           }
  end

  test "economy rollup with NO reporting member: totals is nil, never fabricated zeros", %{
    tmp_dir: tmp_dir,
    sup: sup
  } do
    fleet = load_fleet!(fleet_dir(tmp_dir))

    assert {:ok, result} =
             Kazi.Fleet.Execution.run(fleet,
               workspace: tmp_dir,
               supervisor: sup,
               member_runner: fn _node -> %{status: :converged} end
             )

    assert result.economy == %{members_total: 3, members_reported: 0, totals: nil}
  end

  # ---------------------------------------------------------------------------
  # 6. fleet frontier_complete events
  # ---------------------------------------------------------------------------

  test "frontier_complete events emit at each fleet frontier boundary", %{
    tmp_dir: tmp_dir,
    sup: sup
  } do
    fleet = load_fleet!(fleet_dir(tmp_dir))
    test_pid = self()

    assert {:ok, _result} =
             Kazi.Fleet.Execution.run(fleet,
               workspace: tmp_dir,
               supervisor: sup,
               member_runner: fn _node -> %{status: :converged} end,
               on_frontier_complete: fn payload -> send(test_pid, {:frontier, payload}) end
             )

    assert_receive {:frontier, %{event: "frontier_complete", frontier: 0, groups: frontier0}}
    assert_receive {:frontier, %{event: "frontier_complete", frontier: 1, groups: frontier1}}

    assert Enum.sort_by(frontier0, & &1.id) == [
             %{id: "a", status: :converged},
             %{id: "b", status: :converged}
           ]

    assert frontier1 == [%{id: "c", status: :converged}]
  end

  # ---------------------------------------------------------------------------
  # 2. + 4. real path via the CLI: isolation, cleanup, terminal JSON
  # ---------------------------------------------------------------------------

  test "CLI --fleet: each member runs in its own worktree; the base stays byte-identical; the terminal JSON mirrors the DAG collective shape",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    untracked = Path.join(work, "untracked.txt")
    File.write!(untracked, "keep me\n")
    {status_before, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)

    fleet_path = fleet_dir(tmp_dir)

    {out, code} =
      run_cli(
        ["apply", fleet_path, "--fleet", "--workspace", work, "--json"],
        adapter_opts: [command: passing_harness(tmp_dir)],
        reobserve_interval_ms: 5,
        await_timeout: 60_000
      )

    assert code == 0
    payload = Jason.decode!(out)

    assert payload["mode"] == "fleet"
    assert payload["collective"] == "converged"
    assert payload["schema_version"] == 2

    members = payload["members"]
    assert Enum.map(members, & &1["id"]) == ["a", "b", "c"]
    assert Enum.all?(members, &(&1["status"] == "converged"))

    # The schedule mirrors the DAG collective shape (frontier + per-member state).
    assert [%{"frontier" => 0, "groups" => f0}, %{"frontier" => 1, "groups" => f1}] =
             payload["schedule"]

    assert f0 |> Enum.map(& &1["group"]) |> Enum.sort() == ["a", "b"]
    assert Enum.map(f1, & &1["group"]) == ["c"]

    # Economy rollup present with honest-unknown counts (the stub harness may
    # or may not report usage; the SHAPE is the contract here).
    assert %{"members_total" => 3, "members_reported" => _} = payload["economy"]
    assert payload["blocked"] == []

    # ISOLATION: the harness's edit never landed in the base checkout...
    refute File.exists?(Path.join(work, "fixed.txt"))
    assert File.read!(untracked) == "keep me\n"
    {status_after, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
    assert status_after == status_before

    # ...the per-member worktrees are gone...
    assert linked_worktrees(work) == []

    # ...and each member's registry row recorded a workspace that was NOT the
    # base (its own worktree) — the during-run isolation evidence.
    rows = member_rows(~w(a b c))
    assert length(rows) == 3

    for row <- rows do
      assert row.status == "converged"
      refute Path.expand(row.workspace) == Path.expand(work)
      assert row.workspace =~ "kazi-worktrees"
    end

    # Three DISTINCT worktrees, not one shared.
    assert rows |> Enum.map(& &1.workspace) |> Enum.uniq() |> length() == 3
  end

  # ---------------------------------------------------------------------------
  # T60.5 (#1070): the fleet human report gains a per-member cost/token table,
  # sourced from each member's `:human_cost` (never `--json`-serialized).
  # ---------------------------------------------------------------------------

  test "CLI --fleet (human report): prints a per-member cost/token breakdown table",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    fleet_path = two_member_fleet_dir(tmp_dir)

    {out, code} =
      run_cli(
        ["apply", fleet_path, "--fleet", "--workspace", work],
        adapter_opts: [command: json_usage_harness(tmp_dir)],
        reobserve_interval_ms: 5,
        await_timeout: 60_000
      )

    assert code == 0
    assert out =~ "FLEET CONVERGED"

    # One row per member, same table shape the single-goal report renders.
    assert out =~ "│ Goal"
    assert out =~ "│ m1"
    assert out =~ "│ m2"
    assert out =~ ~r/│ \$0\.01\s+│/
    assert out =~ ~r/tokens: input=100 output=250 cached=5000 cache_write=0/

    # `--json` on the SAME fleet is unaffected by the human_cost plumbing —
    # only the documented economy/member fields are present.
    {json_out, 0} =
      run_cli(
        [
          "apply",
          two_member_fleet_dir(Path.join(tmp_dir, "json")),
          "--fleet",
          "--workspace",
          git_repo(Path.join(tmp_dir, "json")),
          "--json"
        ],
        adapter_opts: [command: json_usage_harness(tmp_dir)],
        reobserve_interval_ms: 5,
        await_timeout: 60_000
      )

    payload = Jason.decode!(json_out)
    member = Enum.find(payload["members"], &(&1["id"] == "m1"))
    refute Map.has_key?(member["economy"] || %{}, "human_cost")
    refute Map.has_key?(member["economy"] || %{}, "token_breakdown")
  end

  # ---------------------------------------------------------------------------
  # 5. registry rows are LIVE during execution
  # ---------------------------------------------------------------------------

  test "a registry row exists per member while it executes, and reaches a terminal status after",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    fleet_path = two_member_fleet_dir(tmp_dir)
    go_file = Path.join(tmp_dir, "go")

    task =
      Task.async(fn ->
        run_cli(
          ["apply", fleet_path, "--fleet", "--workspace", work, "--json"],
          adapter_opts: [command: gated_harness(tmp_dir, go_file)],
          reobserve_interval_ms: 5,
          await_timeout: 60_000
        )
      end)

    # Both members are independent (frontier 0) — while their harnesses block
    # on the go-file, both registry rows must be visible as LIVE runs.
    live =
      poll_until(fn ->
        rows = Enum.filter(RunRegistry.list_live(), &(&1.goal_ref in ["m1", "m2"]))
        if length(rows) == 2, do: rows
      end)

    assert Enum.all?(live, &(&1.status == "running"))

    File.write!(go_file, "go\n")

    {_out, code} = Task.await(task, 60_000)
    assert code == 0

    rows = member_rows(~w(m1 m2))
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.status == "converged"))
  end

  # ---------------------------------------------------------------------------
  # 7. landing (T50.2 one level up): committed member work lands on the base
  # ---------------------------------------------------------------------------

  test "a converged member's COMMITTED work lands on the base via the serial landing path", %{
    tmp_dir: tmp_dir
  } do
    work = git_repo(tmp_dir)
    {head_before, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)

    fleet_path = Path.join(tmp_dir, "landing-fleet")
    File.mkdir_p!(fleet_path)
    write_member_goal(fleet_path, "0001-lander.goal.toml", "lander")

    {out, code} =
      run_cli(
        ["apply", fleet_path, "--fleet", "--workspace", work, "--json"],
        adapter_opts: [command: committing_harness(tmp_dir)],
        reobserve_interval_ms: 5,
        await_timeout: 60_000
      )

    assert code == 0
    payload = Jason.decode!(out)
    assert payload["collective"] == "converged"

    assert [%{"id" => "lander", "integration" => %{"landed" => true}}] = payload["members"]

    # The commit landed on the base checkout (local rebase-merge, no remote).
    {head_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
    refute head_after == head_before
    assert File.exists?(Path.join(work, "fixed.txt"))
    assert linked_worktrees(work) == []
  end

  # ===========================================================================
  # fixtures + helpers
  # ===========================================================================

  # The canonical 3-member fixture: A and B independent (no scopes → no
  # inferred edges), C with an explicit depends_on = ["a"].
  defp fleet_dir(tmp_dir) do
    dir = Path.join(tmp_dir, "fleet")
    File.mkdir_p!(dir)
    write_member_goal(dir, "0001-a.goal.toml", "a")
    write_member_goal(dir, "0002-b.goal.toml", "b")

    write_member_goal(dir, "0003-c.goal.toml", "c", """
    [metadata]
    depends_on = ["a"]
    """)

    dir
  end

  defp two_member_fleet_dir(tmp_dir) do
    dir = Path.join(tmp_dir, "fleet2")
    File.mkdir_p!(dir)
    write_member_goal(dir, "0001-m1.goal.toml", "m1")
    write_member_goal(dir, "0002-m2.goal.toml", "m2")
    dir
  end

  # A member goal whose predicate FAILS at t0 (`test -f fixed.txt` in a fresh
  # worktree) so the run is never vacuous — the proven serial-fixture shape.
  defp write_member_goal(dir, filename, id, extra \\ "") do
    File.write!(Path.join(dir, filename), """
    id = "#{id}"
    name = "fleet member #{id}"

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    #{extra}
    """)
  end

  defp load_fleet!(dir) do
    {:ok, fleet} = Fleet.load(dir)
    fleet
  end

  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  # The gated member-runner stub (mirrors pause_between_waves_test): announces
  # each member's start and blocks until the test releases it, so the test
  # controls exactly when each member terminates.
  defp gated_runner(test_pid) do
    fn %Fleet.Node{id: id} ->
      send(test_pid, {:member_started, id, self()})

      receive do
        {:release, ^id, member} -> member
      end
    end
  end

  defp release_all(entries, status) do
    Enum.each(entries, fn {id, pid} -> send(pid, {:release, id, %{status: status}}) end)
  end

  defp run_cli(argv, runtime_opts) do
    ref = make_ref()
    me = self()

    out =
      capture_io(fn ->
        send(me, {ref, CLI.run(argv, runtime_opts)})
      end)

    receive do
      {^ref, code} -> {out, code}
    after
      0 -> flunk("expected an exit code")
    end
  end

  # Writes fixed.txt into the process's OWN cwd — the member's worktree
  # (workspace threading), never the base checkout.
  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  # T60.5 (#1070): like passing_harness/1, but also emits a Claude JSON
  # result envelope (usage + total_cost_usd) so the run reports real cost/
  # token data for the human report's cost table to render.
  defp json_usage_harness(tmp_dir) do
    write_stub(tmp_dir, "json_usage", """
    echo "the converged fix" > fixed.txt
    cat <<'JSON'
    {"type":"result","subtype":"success","is_error":false,"result":"fixed","total_cost_usd":0.0123,"usage":{"input_tokens":100,"output_tokens":250,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000}}
    JSON
    exit 0
    """)
  end

  # Blocks until the test writes the go-file, then converges — keeps the
  # member's registry row observably LIVE from the test process.
  defp gated_harness(tmp_dir, go_file) do
    write_stub(tmp_dir, "gated", """
    while [ ! -f #{go_file} ]; do sleep 0.05; done
    echo "the converged fix" > fixed.txt
    exit 0
    """)
  end

  # Writes AND COMMITS the fix on the member's task branch, so the landing has
  # committed work to rebase-merge onto the base.
  defp committing_harness(tmp_dir) do
    write_stub(tmp_dir, "committing", """
    echo "the converged fix" > fixed.txt
    git add fixed.txt
    git commit -q -m "fix: converge the member goal"
    exit 0
    """)
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp member_rows(goal_refs) do
    import Ecto.Query
    Repo.all(from(r in Run, where: r.goal_ref in ^goal_refs))
  end

  defp linked_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&List.first(String.split(&1, "\n", trim: true)))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.reject(&(Path.expand(&1) == Path.expand(repo)))
  end

  defp poll_until(fun, deadline_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("poll_until: condition not met within the deadline")
        else
          Process.sleep(50)
          do_poll(fun, deadline)
        end

      value ->
        value
    end
  end
end
