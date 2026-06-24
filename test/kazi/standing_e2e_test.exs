defmodule Kazi.StandingE2ETest do
  @moduledoc """
  End-to-end authoring of STANDING (continuous/maintenance) mode (T3.4d, UC-016).

  T3.4a/b/c built the standing-mode loop (steady observing past convergence,
  re-trigger on drift, graceful stop). This suite proves the LAST piece: a goal
  can DECLARE standing mode — via the goal-file `standing` field OR the CLI
  `--standing` flag — and, driven through the REAL `Kazi.Runtime` wiring (the same
  assembly the CLI uses: the real loader, the real `:tests` provider running a
  command in the workspace, the real `Kazi.Harness.ClaudeAdapter` driving a stub
  harness binary, real read-model persistence), exhibits the full standing ARC:

    * **author + converge** — a standing goal whose code predicate fails at t0 is
      driven green by the harness, then the loop reaches a steady observing state
      (converged once, holding the predicate true) rather than terminating;
    * **drift → re-converge (T3.4b)** — the predicate, green at convergence, is
      regressed mid-run (the marker the predicate checks is removed); the standing
      loop sees the red observation, re-dispatches the harness through the ordinary
      `:dispatch_agent` action, the harness re-creates the marker, and the loop
      re-converges back to steady observing (the satisfied-observation count grows
      past the pre-drift count);
    * **clean stop (T3.4c)** — `stop/1` ends the standing loop; the blocking
      `Kazi.Runtime.run/2` call then returns that terminal `:stopped` result.

  The arc runs through `Kazi.Runtime`, NOT by calling `Kazi.Loop` directly. It is
  hermetic: the predicate is a `test -f <marker>` shell check (the real `:tests`
  provider), the "coding agent" is a stub shell binary the runtime drives through
  its existing `:adapter_opts` `command:` seam (exactly as the CLI/runtime tests
  do), drift is simulated by the test removing the marker, and timing is
  deterministic via a small re-observe interval + snapshot polling and a bounded
  `:await_timeout`. NO Go, NO network, NO real `claude`, NO real browser.

  Authoring back-compat (the additive contract) is also asserted: a goal-file
  WITHOUT `standing` loads as a non-standing converge-and-stop goal, and the CLI
  `--standing` flag OVERRIDES a goal-file/goal that did not declare standing.
  """
  # Real SQLite read-model + real filesystem marker + a stub binary: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, ReadModel, Repo, Runtime}

  @standing_example Path.join([File.cwd!(), "priv", "examples", "standing_maintenance.toml"])

  # ===========================================================================
  # Setup
  # ===========================================================================

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # A clean per-test workspace + a stub harness binary that "lands the fix" by
  # creating the marker file the code predicate checks. The runtime drives this
  # stub through the real ClaudeAdapter via the `:adapter_opts` `command:` seam.
  defp setup_workspace(tmp_dir) do
    work = Path.join(tmp_dir, "ws")
    File.mkdir_p!(work)
    marker = Path.join(work, "fixed.txt")

    harness = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(harness, """
    #!/bin/sh
    # The "coding agent" landing the converged fix: create the marker the code
    # predicate checks. Re-run on drift, it simply re-creates it.
    echo "fixed" > "#{marker}"
    exit 0
    """)

    File.chmod!(harness, 0o755)
    %{work: work, marker: marker, harness: harness}
  end

  defp poll_until(name, fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(name, fun, deadline)
  end

  defp do_poll_until(name, fun, deadline) do
    # The loop is registered ASYNCHRONOUSLY from inside the Task running
    # `Runtime.run/2`, so on early polls its name may not exist yet — a
    # `snapshot/1` on an unregistered name would exit the test process. Tolerate
    # that window (and a snapshot returning nil) until the deadline.
    snap =
      try do
        Kazi.Loop.snapshot(name)
      catch
        :exit, _ -> nil
      end

    cond do
      snap && fun.(snap) ->
        snap

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("poll_until timed out; last snapshot: #{inspect(snap)}")

      true ->
        Process.sleep(2)
        do_poll_until(name, fun, deadline)
    end
  end

  # ===========================================================================
  # Authoring: the goal-file declares standing mode
  # ===========================================================================

  describe "the shipped standing example goal-file" do
    test "loads via the real loader as a standing goal" do
      assert {:ok, %Goal{} = goal} = Kazi.Goal.Loader.load(@standing_example)
      assert goal.id == "standing-maintenance-example"
      assert goal.standing == true
      assert Goal.standing?(goal)
      # Self-describing: a code predicate + a live predicate, the maintenance pair.
      assert Enum.map(goal.predicates, & &1.id) == ["tests-green", "healthz-live"]
    end

    test "a goal-file WITHOUT `standing` loads as a non-standing goal (back-compat)" do
      data = %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]}
      assert {:ok, %Goal{standing: false} = goal} = Kazi.Goal.Loader.from_map(data)
      refute Goal.standing?(goal)
    end

    test "a non-boolean `standing` is a load-time validation error" do
      data = %{
        "id" => "g",
        "standing" => "yes",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Kazi.Goal.Loader.from_map(data)
      assert reason =~ "standing"
    end
  end

  # ===========================================================================
  # The full standing ARC through Kazi.Runtime: a goal that DECLARES standing in
  # its own field (the goal-file path) drives converge → steady → drift →
  # re-converge → clean stop, all through the real runtime wiring.
  # ===========================================================================

  describe "standing arc through Kazi.Runtime" do
    @tag :tmp_dir
    test "author standing goal → converge → drift re-triggers → re-converge → stop",
         %{tmp_dir: tmp_dir} do
      %{work: work, marker: marker, harness: harness} = setup_workspace(tmp_dir)
      goal_id = "standing-e2e-#{System.unique_integer([:positive])}"

      # A standing goal authored via the Goal struct's own `standing` field — the
      # exact in-memory shape the loader produces from a goal-file `standing =
      # true`. One code predicate: `test -f fixed.txt`, FAILING at t0 (the marker
      # does not exist yet → non-vacuous), driven green by the harness stub.
      goal =
        Goal.new(goal_id,
          standing: true,
          predicates: [
            Kazi.Predicate.new(:code, :tests,
              config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]}
            )
          ]
        )

      assert Goal.standing?(goal)
      refute File.exists?(marker)

      atom_name = :"kazi_e2e_loop_#{goal_id}"

      # Drive it through the REAL runtime: it resolves the real `:tests` provider,
      # assembles the loop, drives the real ClaudeAdapter against the stub harness
      # binary, and persists each iteration. We pass NO explicit :standing — the
      # runtime reads `goal.standing` to run standing (the goal-file field path).
      # `run/2` blocks until the loop terminates; a standing loop never converges-
      # and-stops, so we run it in a Task and inspect/stop it by name. The shared
      # SQLite sandbox connection is granted to the loop's process so its
      # persistence callback can write.
      parent = self()

      runner =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          Runtime.run(goal,
            workspace: work,
            adapter_opts: [command: harness],
            reobserve_interval_ms: 5,
            goal_ref: goal_id,
            name: {:local, atom_name},
            await_timeout: 15_000
          )
        end)

      # 1. AUTHORED STANDING + CONVERGE: the harness drives the predicate green and
      #    the loop enters steady observing — it does NOT terminate (the goal's
      #    `standing` field drove the loop's mode).
      pre = poll_until(atom_name, fn s -> s.mode == :standing and s.steady? end)
      assert pre.steady_observations >= 1
      assert File.exists?(marker)
      # It reached convergence by dispatching the agent (the t0 fail was real work).
      assert :dispatch_agent in pre.actions

      # 2. DRIFT (T3.4b): regress the satisfied predicate by removing the marker.
      #    The standing loop sees the red observation on its next tick.
      File.rm!(marker)

      # 3. RE-TRIGGER + RE-CONVERGE: the loop leaves steady, re-dispatches the
      #    harness through the ordinary :dispatch_agent path (which re-creates the
      #    marker), and returns to steady observing — the satisfied count grows
      #    past the pre-drift count, proving it re-converged rather than terminated
      #    or staying red.
      post =
        poll_until(
          atom_name,
          fn s -> s.steady? and s.steady_observations > pre.steady_observations end,
          15_000
        )

      assert post.mode == :standing
      assert post.state == :observing
      assert File.exists?(marker)

      # 4. CLEAN STOP (T3.4c): stop ends the standing loop; run/2 then returns the
      #    terminal :stopped result through the real runtime path.
      :ok = Kazi.Loop.stop(atom_name)
      assert {:ok, %{outcome: :stopped} = result} = Task.await(runner, 15_000)
      assert :dispatch_agent in result.actions

      # 5. PERSISTENCE through the runtime's read-model seam: every iteration is
      #    projected, including converged and not-converged (the t0 fail + drift)
      #    observations.
      iterations = ReadModel.list_iterations(goal_id)
      assert iterations != []
      assert Enum.any?(iterations, & &1.converged)
      assert Enum.any?(iterations, &(not &1.converged))
    end
  end

  # ===========================================================================
  # Authoring: the CLI --standing flag overrides a non-standing goal
  # ===========================================================================

  describe "CLI --standing flag authoring" do
    test "parse/1 carries --standing through the run command" do
      assert {:run, "g.toml", opts} =
               Kazi.CLI.parse(["apply", "g.toml", "--workspace", "/tmp/ws", "--standing"])

      assert opts[:standing] == true

      # Absent flag → nil, so the goal-file's own `standing` decides downstream.
      assert {:run, "g.toml", no_flag} = Kazi.CLI.parse(["apply", "g.toml"])
      assert no_flag[:standing] == nil
    end

    @tag :tmp_dir
    test "--standing forces standing mode on a goal that did NOT declare it",
         %{tmp_dir: tmp_dir} do
      %{work: work, marker: marker, harness: harness} = setup_workspace(tmp_dir)
      goal_id = "cli-standing-#{System.unique_integer([:positive])}"

      # A NON-standing goal (standing defaults to false, mirroring a goal-file with
      # no `standing` key). The flag — passed as an explicit `:standing` opt, which
      # is exactly what the CLI puts into run_opts for `--standing` — must override.
      goal =
        Goal.new(goal_id,
          predicates: [
            Kazi.Predicate.new(:code, :tests,
              config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]}
            )
          ]
        )

      refute Goal.standing?(goal)

      atom_name = :"kazi_cli_loop_#{goal_id}"
      parent = self()

      runner =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          Runtime.run(goal,
            workspace: work,
            adapter_opts: [command: harness],
            # `standing: true` mirrors the CLI putting `--standing` into run_opts;
            # it OVERRIDES the goal's own `standing: false`.
            standing: true,
            reobserve_interval_ms: 5,
            goal_ref: goal_id,
            name: {:local, atom_name},
            await_timeout: 15_000
          )
        end)

      # The flag won: the loop runs standing (steady observing) despite the goal
      # declaring non-standing — it converges then holds, never converge-and-stops.
      snap = poll_until(atom_name, fn s -> s.mode == :standing and s.steady? end)
      assert snap.steady_observations >= 1
      assert File.exists?(marker)

      :ok = Kazi.Loop.stop(atom_name)
      assert {:ok, %{outcome: :stopped}} = Task.await(runner, 15_000)
    end
  end
end
