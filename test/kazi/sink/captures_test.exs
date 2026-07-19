defmodule Kazi.Sink.CapturesTest do
  @moduledoc """
  ADR-0081 (#1521): the per-run evidence store + controller-side capture executor.
  Hermetic — recipes are `sh -c` commands writing to `$KAZI_CAPTURE_OUTPUT`, no
  browser/simulator (the live capture path is the same `CommandRunner` seam,
  proven outside `mix test`).
  """
  use ExUnit.Case, async: true

  alias Kazi.Sink.Captures

  @moduletag :tmp_dir

  defp recipe(overrides) do
    Kazi.Capture.new(
      Keyword.merge(
        [name: "now_screen", launch_cmd: "sh", output: "now_screen.png"],
        overrides
      )
    )
  end

  test "a successful recipe lands its artifact in the run-keyed store with provenance",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)
    run_id = "run-abc"

    dir = Captures.iteration_dir(sinks, run_id, 3)

    # A recipe that writes a non-blank, high-entropy artifact to the destination
    # the CONTROLLER chose ($KAZI_CAPTURE_OUTPUT), not a path it picked itself.
    capture =
      recipe(launch_args: ["-c", ~s|head -c 4096 /dev/urandom > "$KAZI_CAPTURE_OUTPUT"|])

    results = Captures.run([capture], dir: dir, workspace: workspace)

    assert %{"now_screen" => result} = results
    assert result.ok == true
    assert result.exit == 0
    assert result.bytes == 4096
    assert result.sha256 =~ ~r/^[0-9a-f]{64}$/

    # Keyed to the run + iteration under the sinks tree.
    assert result.artifact_path ==
             Path.join([sinks, run_id, "captures", "3", "now_screen", "now_screen.png"])

    assert File.regular?(result.artifact_path)

    # Provenance sidecar records who produced which bytes (never the bytes).
    sidecar = Path.join([sinks, run_id, "captures", "3", "now_screen", "capture.json"])
    assert File.regular?(sidecar)
    prov = sidecar |> File.read!() |> Jason.decode!()
    assert prov["name"] == "now_screen"
    assert prov["ok"] == true
    assert prov["sha256"] == result.sha256
    assert prov["launch"] =~ "sh"
  end

  test "the evidence store is OUTSIDE the workspace (worker write-protection)",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)

    capture = recipe(launch_args: ["-c", ~s|printf xxxx > "$KAZI_CAPTURE_OUTPUT"|])
    dir = Captures.iteration_dir(sinks, "run-1", 0)
    %{"now_screen" => result} = Captures.run([capture], dir: dir, workspace: workspace)

    # The artifact the controller produced is under the sinks tree, and the
    # workspace the worker edits does NOT contain it — the separation IS the
    # write-protection (ADR-0081 §3).
    refute String.starts_with?(Path.expand(result.artifact_path), Path.expand(workspace) <> "/")
    assert String.starts_with?(Path.expand(result.artifact_path), Path.expand(sinks) <> "/")
    assert File.ls!(workspace) == []
  end

  test "a recipe that writes no artifact is ok:false (a crash/blank capture, not a raise)",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")

    # Exits 0 but writes nothing to the destination — a launch that "ran" but
    # produced no frame.
    capture = recipe(launch_args: ["-c", "true"])
    dir = Captures.iteration_dir(sinks, "run-2", 0)
    %{"now_screen" => result} = Captures.run([capture], dir: dir, workspace: sinks)

    assert result.ok == false
    assert result.reason == :no_artifact
    assert result.sha256 == nil
  end

  test "a launch command that cannot run is ok:false with an unavailable reason",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    capture = recipe(launch_cmd: "this-binary-does-not-exist-9f3a", launch_args: [])
    dir = Captures.iteration_dir(sinks, "run-3", 0)
    %{"now_screen" => result} = Captures.run([capture], dir: dir, workspace: sinks)

    assert result.ok == false
    assert result.reason == :launch_unavailable
  end

  test "a reset command runs before launch; a failing reset fails the capture",
       %{tmp_dir: tmp_dir} do
    sinks = Path.join(tmp_dir, "runs")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)

    capture =
      recipe(
        reset_cmd: "sh",
        reset_args: ["-c", "exit 3"],
        launch_args: ["-c", ~s|printf data > "$KAZI_CAPTURE_OUTPUT"|]
      )

    dir = Captures.iteration_dir(sinks, "run-4", 0)
    %{"now_screen" => result} = Captures.run([capture], dir: dir, workspace: workspace)

    assert result.ok == false
    assert result.reason == :reset_failed
    # The launch never ran, so no artifact was produced.
    refute File.regular?(Path.join([dir, "now_screen", "now_screen.png"]))
  end
end
