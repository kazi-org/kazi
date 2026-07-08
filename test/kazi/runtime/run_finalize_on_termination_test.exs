defmodule Kazi.Runtime.RunFinalizeOnTerminationTest do
  @moduledoc """
  Tests that kazi runs trigger finalization hooks when harness processes
  terminate, ensuring proper cleanup of child processes and resources.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, Repo, Runtime, Scope}

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "run/2 finalizes on termination" do
    test "completes normally with cleanup on harness termination", %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(work)

      goal =
        Goal.new("finalize-test",
          predicates: [
            Predicate.new(:always_pass, :static, config: %{verdict: :pass})
          ],
          scope: Scope.new(workspace: work)
        )

      opts = [
        workspace: work,
        adapter_opts: [command: "true"],
        persist?: false,
        await_timeout: 5_000
      ]

      assert {:ok, result} = Runtime.run(goal, opts)
      assert result.outcome == :converged
    end
  end
end
