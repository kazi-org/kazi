defmodule Kazi.Runtime.BusMirrorIntegrationTest do
  @moduledoc """
  T51.5 (ADR-0067 point 1): the run-lifecycle mirror driven through the REAL
  `Kazi.Runtime.run/2`. The goal is a single `:code`/`:tests` predicate that
  FAILS at t0 (no marker file) and a stub harness that writes the marker, so the
  loop runs the full observe -> dispatch -> reobserve -> converge sequence
  (integration mode `:none`, so no git/land step). Session identity threads
  through as `--session-name` would.

  Pins the two acceptance invariants:

    * with the daemon "up" (a capturing poster standing in for it) a run mirrors
      BOTH the started and the terminal-verdict facts, with their real content;
    * with the daemon DOWN (the real `Kazi.Bus.post/3`, no daemon) the run's
      result is identical to a run with the bus absent entirely, and NO error
      surfaces -- the bus is a mirror, never a dependency.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kazi.{Goal, Predicate, Runtime, Scope}

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:kazi, :run_mirror_poster) end)
    :ok
  end

  # A workspace whose `fixed.txt` marker is absent at t0 (predicate fails) and a
  # stub harness that creates it (predicate passes on reobserve).
  defp workspace(tmp, name) do
    work = Path.join(tmp, name)
    File.mkdir_p!(work)
    work
  end

  defp harness_stub(tmp) do
    path = Path.join(tmp, "stub_harness.sh")
    File.write!(path, "#!/bin/sh\necho fixed > fixed.txt\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp run(work, stub, opts) do
    goal =
      Goal.new("mirror-#{System.unique_integer([:positive])}",
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
        ],
        scope: Scope.new(workspace: work)
      )

    Runtime.run(
      goal,
      [
        workspace: work,
        persist?: false,
        adapter_opts: [command: stub],
        reobserve_interval_ms: 5,
        await_timeout: 15_000
      ] ++ opts
    )
  end

  test "a run with the daemon up mirrors BOTH the started and terminal facts", %{tmp_dir: tmp} do
    test = self()

    Application.put_env(:kazi, :run_mirror_poster, fn kind, text, opts ->
      send(test, {:posted, kind, text, opts})
      :ok
    end)

    assert {:ok, %{outcome: :converged}} =
             run(workspace(tmp, "up"), harness_stub(tmp), session_name: "supervisor-1")

    assert_receive {:posted, "fact", "started mirror-" <> _, started_opts}
    assert started_opts[:session_name] == "supervisor-1"
    assert String.starts_with?(started_opts[:topic], "run:")

    assert_receive {:posted, "fact", "converged mirror-" <> rest, _terminal_opts}
    assert rest =~ ~r{\(\d+/\d+ passing, \d+ iters\)}
  end

  test "with the daemon DOWN the run result is identical to a bus-absent control, no error",
       %{tmp_dir: tmp} do
    stub = harness_stub(tmp)

    # Real &Kazi.Bus.post/3, no daemon in the test env -> {:error, :no_daemon},
    # which the mirror must swallow.
    Application.delete_env(:kazi, :run_mirror_poster)

    {daemon_down, log} =
      with_log(fn -> run(workspace(tmp, "down"), stub, session_name: "s") end)

    # Control: the bus is absent from the path entirely (a no-op poster).
    Application.put_env(:kazi, :run_mirror_poster, fn _k, _t, _o -> :ok end)
    control = run(workspace(tmp, "control"), stub, session_name: "s")

    assert {:ok, down_result} = daemon_down
    assert {:ok, control_result} = control

    # The reconcile outcome does not turn on whether the daemon is up. (The
    # vector's evidence embeds each run's own workspace path, so compare the
    # predicate STATUSES, not the byte-identical evidence.)
    statuses = fn %{results: results} ->
      Map.new(results, fn {id, r} -> {id, r.status} end)
    end

    assert down_result.outcome == :converged
    assert control_result.outcome == :converged
    assert down_result.iterations == control_result.iterations
    assert statuses.(down_result.vector) == statuses.(control_result.vector)

    refute log =~ "[error]"
  end
end
