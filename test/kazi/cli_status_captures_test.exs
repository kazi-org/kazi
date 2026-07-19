defmodule Kazi.CLIStatusCapturesTest do
  @moduledoc """
  ADR-0081 (#1521): `kazi status <ref> --json` surfaces the run's retained capture
  evidence per observe iteration from the run-keyed evidence store — additive, so
  a run that declared no captures omits the key (regression pin).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}
  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Sink.Captures

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp record_converged_iteration(goal_ref) do
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: PredicateVector.new(%{render: PredicateResult.new(:pass)}),
        converged: true
      })
  end

  test "status --json lists the evidence artifact paths per iteration", %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)
    run_id = "cap-run-1"
    goal_ref = "cap-goal"

    # Seed a run row whose events sink locates the run dir (its captures/ sibling
    # is the evidence store), exactly as a real persisted run does.
    {:ok, _} =
      RunRegistry.start(%{
        run_id: run_id,
        goal_ref: goal_ref,
        workspace: workspace,
        pid: "#{inspect(self())}",
        events_sink_path: Path.join([sinks, run_id, "events.jsonl"])
      })

    # A real controller capture in the store for observe iteration 0.
    capture =
      Kazi.Capture.new(
        name: "now_screen",
        launch_cmd: "sh",
        launch_args: ["-c", ~s|head -c 2048 /dev/urandom > "$KAZI_CAPTURE_OUTPUT"|],
        output: "now_screen.png"
      )

    dir = Captures.iteration_dir(sinks, run_id, 0)
    File.mkdir_p!(dir)
    Captures.run([capture], dir: dir, workspace: workspace)

    record_converged_iteration(goal_ref)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", goal_ref, "--json"], []) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert [iteration] = payload["captures"]
    assert iteration["iteration"] == 0
    assert [artifact] = iteration["artifacts"]
    assert artifact["name"] == "now_screen"
    assert artifact["ok"] == true
    assert artifact["bytes"] == 2048
    assert artifact["sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert artifact["artifact_path"] =~ "captures/0/now_screen/now_screen.png"
  end

  test "a run with no captures omits the key (regression pin)" do
    record_converged_iteration("cap-none")

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", "cap-none", "--json"], []) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["kind"] == "run"
    refute Map.has_key?(payload, "captures")
  end
end
