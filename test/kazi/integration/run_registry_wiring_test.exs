defmodule Kazi.Integration.RunRegistryWiringTest do
  @moduledoc """
  Tier 2 — the integration proof T46.1's reopen demanded (ADR-0057): a real
  `kazi apply` run through the SAME entry point every real user hits
  (`Kazi.CLI.run/2`, shared by the escript and `mix kazi.apply`) leaves a `runs`
  row in the shared read-model. `Kazi.ReadModel.RunRegistryTest` already pinned
  the registry module in isolation — that passed even while the live apply path
  never called it (PR #789, v1.73.0 shipped with an empty `runs` table on a real
  converged run). This test goes through `Kazi.CLI.run/2` instead of calling
  `Kazi.Runtime.run/2` directly, so a regression that re-severs the wiring at
  the CLI layer (not just inside `Kazi.Runtime`) fails here too.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a converging `kazi apply` run registers, heartbeats, and finishes its runs row",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work],
          adapter_opts: [command: harness_stub],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

    assert run.status == "converged"
    assert run.workspace == work
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.heartbeat_at
    assert %DateTime{} = run.finished_at
    refute RunRegistry.stale?(run)
  end

  defp write_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "run-registry-wiring-fixture"
    name = "T46.1 run-registry wiring fixture"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
