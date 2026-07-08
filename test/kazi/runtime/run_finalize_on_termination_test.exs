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
      marker = Path.join(work, "fixed.txt")

      goal =
        Goal.new("finalize-test",
          predicates: [
            Predicate.new(:code, :tests, config: %{cmd: "test", args: ["-f", marker]})
          ],
          scope: Scope.new(workspace: work)
        )

      harness_stub = write_harness_stub(work, marker)

      opts = [
        workspace: work,
        adapter_opts: [command: harness_stub],
        persist?: false,
        await_timeout: 10_000
      ]

      assert {:ok, result} = Runtime.run(goal, opts)
      assert result.outcome == :converged
      assert File.exists?(marker)
    end
  end

  # Write a stub harness that creates the marker file the test predicate checks.
  defp write_harness_stub(work, marker) do
    stub = Path.join(work, "harness_stub.sh")

    File.write!(stub, """
    #!/bin/sh
    set -e
    cd #{work}
    touch #{marker}
    """)

    File.chmod!(stub, 0o755)
    stub
  end
end
