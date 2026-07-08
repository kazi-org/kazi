defmodule Kazi.RuntimeDuplicateRunTest do
  @moduledoc """
  The duplicate-run guard: an executing apply refuses to start when the run
  registry already holds a LIVE run (status "running", fresh heartbeat) for
  the same goal_ref, unless `--allow-duplicate-run`.

  The incident this pins against: a fresh process picked up and started
  applying a goal another process had been converging for 1.5 hours -- a
  second full budget burned, racing the first's edits. Zombie rows must NEVER
  block: a dead run stops heartbeating, so it goes stale (~90s) and ages out
  of the guard on its own -- the same staleness window the dashboard and the
  reaper use.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a FRESH live run for the same goal_ref refuses a second apply: JSON error, exit 1",
       %{tmp_dir: tmp_dir} do
    insert_running_row(heartbeat_at: DateTime.utc_now(:microsecond), session_name: "first-run")
    {goal_file, work} = fixture(tmp_dir)

    {code, out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)]
        )
      end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "already in flight"
    assert message =~ "--allow-duplicate-run"
    assert message =~ "first-run"
  end

  test "--allow-duplicate-run starts the second apply anyway", %{tmp_dir: tmp_dir} do
    insert_running_row(heartbeat_at: DateTime.utc_now(:microsecond))
    {goal_file, work} = fixture(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--allow-duplicate-run", "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "a STALE running row (zombie) never blocks", %{tmp_dir: tmp_dir} do
    two_hours_ago = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
    insert_running_row(heartbeat_at: two_hours_ago)
    {goal_file, work} = fixture(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "a TERMINAL row (converged) for the same goal_ref never blocks", %{tmp_dir: tmp_dir} do
    insert_running_row(heartbeat_at: DateTime.utc_now(:microsecond), status: "converged")
    {goal_file, work} = fixture(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  # --- fixtures --------------------------------------------------------------

  @goal_id "duplicate-run-guard-fixture"

  defp insert_running_row(attrs) do
    now = DateTime.utc_now(:microsecond)

    base = [
      run_id: "prior-#{System.unique_integer([:positive])}",
      pid: "#{System.unique_integer([:positive])}",
      workspace: "/tmp/prior-work",
      goal_ref: @goal_id,
      status: "running",
      started_at: now,
      heartbeat_at: now
    ]

    {:ok, run} = Repo.insert(Run.changeset(%Run{}, Map.new(Keyword.merge(base, attrs))))
    run
  end

  defp fixture(tmp_dir) do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    goal_file = Path.join(tmp_dir, "goal.toml")

    File.write!(goal_file, """
    id = "#{@goal_id}"
    name = "duplicate-run guard fixture"

    [scope]
    workspace = "#{work}"

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    {goal_file, work}
  end

  defp passing_harness(tmp_dir) do
    path = Path.join(tmp_dir, "stub.sh")
    File.write!(path, "#!/bin/sh\necho \"the converged fix\" > fixed.txt\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
