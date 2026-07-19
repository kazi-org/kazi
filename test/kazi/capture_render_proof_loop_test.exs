defmodule Kazi.CaptureRenderProofLoopTest do
  @moduledoc """
  ADR-0081 (#1521) acceptance: the CONTROLLER runs the capture recipe each observe
  pass into the run-keyed evidence store, and a `render_proof` predicate consuming
  that controller capture goes RED when the app renders a blank/crash frame (so the
  run cannot converge) and GREEN when it renders — the red->green control proving
  the capture is what gates convergence.

  Hermetic: the recipe is an `sh -c` command writing to `$KAZI_CAPTURE_OUTPUT`
  (no browser/simulator). The capture_fn is built exactly as `Kazi.Runtime`
  builds it, so the artifact lands keyed to the run id + observe iteration.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Capture, Goal, Predicate}
  alias Kazi.Sink.Captures

  @moduletag :tmp_dir

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    # The worker cannot influence the capture — it is controller-produced. A no-op
    # dispatch that writes nothing, so a blank capture never becomes non-blank.
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "noop", touched: []}}
  end

  defmodule NoopAction do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{}, _context), do: {:ok, %{}}
  end

  # A capture_fn built the SAME way Kazi.Runtime.build_capture_fn/4 does: keyed to
  # a run id under a sinks tree, executing the recipe into the run-keyed store.
  defp capture_fn(sinks, run_id, workspace, launch) do
    capture =
      Capture.new(
        name: "now_screen",
        launch_cmd: "sh",
        launch_args: ["-c", launch],
        output: "now_screen.png"
      )

    fn iteration ->
      dir = Captures.iteration_dir(sinks, run_id, iteration)
      File.mkdir_p!(dir)
      Captures.run([capture], dir: dir, workspace: workspace)
    end
  end

  defp start_loop(workspace, capture_fn, budget) do
    goal =
      Goal.new("ui",
        predicates: [Predicate.new(:render, :render_proof, config: %{capture: "now_screen"})],
        budget: budget
      )

    Kazi.Loop.start_link(
      goal: goal,
      providers: %{render_proof: Kazi.Providers.RenderProof},
      harness: NoopHarness,
      integrate: NoopAction,
      deploy: NoopAction,
      workspace: workspace,
      reobserve_interval_ms: 1,
      flake_max_retries: 0,
      capture_fn: capture_fn
    )
  end

  test "a blank render cannot converge; the controller capture landed keyed to the run",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)
    run_id = "run-blank"

    # A "crash/blank screen": 4 KiB of a single byte — over the size floor, one
    # distinct byte, so render_proof fails the entropy floor.
    blank =
      capture_fn(sinks, run_id, workspace, ~s|head -c 4096 /dev/zero > "$KAZI_CAPTURE_OUTPUT"|)

    {:ok, loop} = start_loop(workspace, blank, max_iterations: 2)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    # Code that never renders CANNOT converge (ADR-0081 acceptance).
    refute result.outcome == :converged

    # The controller produced the capture, keyed to the run + iteration 0, in the
    # evidence store OUTSIDE the workspace.
    artifact = Path.join([sinks, run_id, "captures", "0", "now_screen", "now_screen.png"])
    assert File.regular?(artifact)

    assert File.regular?(
             Path.join([sinks, run_id, "captures", "0", "now_screen", "capture.json"])
           )

    # Write-protection: the controller-produced capture is under the sinks tree,
    # never in the workspace the worker edits (ADR-0081 §3).
    assert String.starts_with?(Path.expand(artifact), Path.expand(sinks) <> "/")
    refute File.regular?(Path.join(workspace, "now_screen.png"))
  end

  test "control: a real render converges green (render_proof passes on the controller capture)",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)
    run_id = "run-good"

    good =
      capture_fn(sinks, run_id, workspace, ~s|head -c 4096 /dev/urandom > "$KAZI_CAPTURE_OUTPUT"|)

    {:ok, loop} = start_loop(workspace, good, max_iterations: 5)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    artifact = Path.join([sinks, run_id, "captures", "0", "now_screen", "now_screen.png"])
    assert File.regular?(artifact)
  end
end
