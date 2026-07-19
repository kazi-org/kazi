defmodule Kazi.Runtime.FinalizerTerminationMirrorTest do
  @moduledoc """
  T60.1 (#1154): the abnormal-termination transition (`Finalizer.record_termination/2`)
  mirrors a `terminated` fact onto the bus so the fleet sees a run's honest final
  state. Tier 2 — real read-model boundary for the registry write, with the
  `:run_mirror_poster` seam capturing the mirrored fact (no live daemon).
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo
  alias Kazi.Runtime.Finalizer

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    test = self()

    Application.put_env(:kazi, :run_mirror_poster, fn kind, text, opts ->
      send(test, {:posted, kind, text, opts})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:kazi, :run_mirror_poster) end)
    :ok
  end

  defp start_run(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.123.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-a"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  test "recording a termination marks the run terminated AND mirrors a terminated fact" do
    run = start_run()

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "terminated"

    assert_receive {:posted, "fact", "terminated goal-a (killed)", opts}
    assert opts[:topic] == "run:" <> String.slice(run.run_id, 0, 8)
  end

  test "a run that already finished normally is not re-labelled or mirrored as terminated" do
    run = start_run()
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "converged"

    refute_receive {:posted, "fact", "terminated" <> _, _}
  end

  test "best-effort: a poster that raises never fails the termination record" do
    Application.put_env(:kazi, :run_mirror_poster, fn _k, _t, _o -> raise "boom" end)
    run = start_run()

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "terminated"
  end
end
