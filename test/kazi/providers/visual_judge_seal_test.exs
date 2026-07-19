defmodule Kazi.Providers.VisualJudgeSealTest do
  @moduledoc """
  T68.8 (#1522) x ADR-0080: a visual_judge predicate's BAR is tamper-evident.
  The rubric + pinned model live in the goal-file (implicitly sealed) and the
  reference image is a declared `sealed_input`, so a worker that edits either
  mid-run flips the run `tampered`, never green. This pins that integration end
  to end through the real `Kazi.Seal` primitive and the real goal loader.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Seal

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-vj-seal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "checks/reference"))
    reference = Path.join(dir, "checks/reference/mockup.png")
    File.write!(reference, "APPROVED_MOCKUP pixels")

    goal_file = Path.join(dir, "goal.toml")
    File.write!(goal_file, goal_toml("no stock tab bar; raised circular center control"))

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, goal_file: goal_file, reference: reference}
  end

  defp goal_toml(criterion) do
    """
    id = "looks-right"

    [seal]
    sealed_inputs = ["checks/reference/mockup.png"]

    [[capture]]
    name = "now_screen"
    launch_cmd = "sh"
    output = "now_screen.png"

    [[predicate]]
    id = "looks_right"
    provider = "visual_judge"
    capture = "now_screen"
    model = "claude-opus-4-8"
    rubric = ["#{criterion}"]
    """
  end

  test "the goal parses the [seal] block onto Goal.seal", %{goal_file: goal_file} do
    assert {:ok, %Goal{seal: %Seal{sealed_inputs: ["checks/reference/mockup.png"]}}} =
             Loader.load(goal_file)
  end

  test "editing the rubric mid-run is tampered (goal-file implicitly sealed)", %{
    dir: dir,
    goal_file: goal_file
  } do
    {:ok, %Goal{seal: seal}} = Loader.load(goal_file)
    manifest = Seal.arm(seal, goal_file, dir)
    assert Seal.verify(manifest) == :ok

    # A converging worker loosens the rubric to reach green.
    File.write!(goal_file, goal_toml("anything goes"))

    assert {:tampered, %{path: ^goal_file, change: :modified}} = Seal.verify(manifest)
  end

  test "editing the sealed reference image mid-run is tampered", %{
    dir: dir,
    goal_file: goal_file,
    reference: reference
  } do
    {:ok, %Goal{seal: seal}} = Loader.load(goal_file)
    manifest = Seal.arm(seal, goal_file, dir)
    assert Seal.verify(manifest) == :ok

    # A worker swaps the approved mockup for one that matches its build.
    File.write!(reference, "DIFFERENT reference to game the judge")

    assert {:tampered, %{path: "checks/reference/mockup.png", change: :modified}} =
             Seal.verify(manifest)
  end

  test "an untouched contract verifies clean", %{dir: dir, goal_file: goal_file} do
    {:ok, %Goal{seal: seal}} = Loader.load(goal_file)
    manifest = Seal.arm(seal, goal_file, dir)
    assert Seal.verify(manifest) == :ok
  end
end
