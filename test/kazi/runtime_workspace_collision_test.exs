defmodule Kazi.RuntimeWorkspaceCollisionTest do
  @moduledoc """
  The workspace-collision guard (T59.7, #937 Gap G): an executing apply refuses
  to start when the run registry already holds a LIVE run (status "running",
  fresh heartbeat) for a DIFFERENT goal that holds the SAME resolved workspace,
  unless `--allow-workspace-collision`.

  The incident this pins against: N different goals dispatched against one shared
  `--workspace` cross-contaminate each other's commits (the commit-bleed reports
  in #937). The duplicate-run guard (#942/#944) only catches a second run of the
  SAME goal; this one catches a different goal on the same directory. It reuses
  the SAME fresh-heartbeat liveness the duplicate-run guard trusts, so a
  stale/dead holder never blocks -- it ages out (~90s) on its own.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  @moduletag :tmp_dir

  @goal_id "workspace-collision-guard-fixture"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a FRESH live run for a DIFFERENT goal on the same workspace is refused, naming the holder",
       %{tmp_dir: tmp_dir} do
    {goal_file, work} = fixture(tmp_dir)

    insert_running_row(work,
      heartbeat_at: DateTime.utc_now(:microsecond),
      goal_ref: "some-other-goal",
      session_name: "holder-run"
    )

    {code, out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)]
        )
      end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "DIFFERENT goal"
    assert message =~ "some-other-goal"
    assert message =~ "holder-run"
    assert message =~ "--allow-workspace-collision"
  end

  test "--allow-workspace-collision starts the run anyway", %{tmp_dir: tmp_dir} do
    {goal_file, work} = fixture(tmp_dir)

    insert_running_row(work,
      heartbeat_at: DateTime.utc_now(:microsecond),
      goal_ref: "some-other-goal"
    )

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--allow-workspace-collision", "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "a STALE (zombie) holder of the same workspace never blocks", %{tmp_dir: tmp_dir} do
    {goal_file, work} = fixture(tmp_dir)
    two_hours_ago = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)

    insert_running_row(work, heartbeat_at: two_hours_ago, goal_ref: "some-other-goal")

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

  test "a DIFFERENT workspace never blocks (only the shared directory does)", %{tmp_dir: tmp_dir} do
    {goal_file, work} = fixture(tmp_dir)

    insert_running_row("/tmp/some-other-work",
      heartbeat_at: DateTime.utc_now(:microsecond),
      goal_ref: "some-other-goal"
    )

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

  test "a second run of the SAME goal still hits the duplicate-run guard unchanged (#942/#944)",
       %{tmp_dir: tmp_dir} do
    {goal_file, work} = fixture(tmp_dir)

    # Same goal_ref AND same workspace: the duplicate-run guard runs first and
    # owns this case; the workspace guard deliberately skips same-goal rows.
    insert_running_row(work,
      heartbeat_at: DateTime.utc_now(:microsecond),
      goal_ref: @goal_id,
      session_name: "first-run"
    )

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
    refute message =~ "--allow-workspace-collision"
  end

  # --- fixtures --------------------------------------------------------------

  defp insert_running_row(workspace, attrs) do
    now = DateTime.utc_now(:microsecond)

    base = [
      run_id: "prior-#{System.unique_integer([:positive])}",
      pid: "#{System.unique_integer([:positive])}",
      workspace: to_string(workspace),
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
    name = "workspace-collision guard fixture"

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
