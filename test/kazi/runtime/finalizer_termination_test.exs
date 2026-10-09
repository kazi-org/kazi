defmodule Kazi.Runtime.FinalizerTerminationTest do
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

  test "recording a termination updates local evidence without publishing a message" do
    run = start_run()

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "terminated"

    refute_receive {:posted, _, _, _}
  end

  test "a run that already finished normally is not re-labelled" do
    run = start_run()
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "converged"

    refute_receive {:posted, "fact", "terminated" <> _, _}
  end

  test "termination ignores the retired messaging poster" do
    Application.put_env(:kazi, :run_mirror_poster, fn _k, _t, _o -> raise "boom" end)
    run = start_run()

    assert Finalizer.record_termination(run.run_id, :killed) == :ok
    assert Repo.get_by(Run, run_id: run.run_id).status == "terminated"
  end
end
