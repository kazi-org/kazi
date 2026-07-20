defmodule Kazi.SealTest do
  @moduledoc """
  ADR-0080 (#1520): unit coverage for the seal primitive — `arm/3` builds the t0
  manifest, `verify/1` re-hashes and returns the first tamper, and the opt-outs
  (`enabled = false`, `mutable_inputs`) carve the seal set exactly.
  """
  use ExUnit.Case, async: true

  alias Kazi.Seal

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-seal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "checks/reference"))
    File.write!(Path.join(dir, "checks/manifest.toml"), "threshold = 0.99\n")
    File.write!(Path.join(dir, "checks/reference/a.png"), "AAA")
    File.write!(Path.join(dir, "checks/reference/b.png"), "BBB")
    goal_file = Path.join(dir, "goal.toml")
    File.write!(goal_file, "id = \"g\"\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, goal_file: goal_file}
  end

  describe "arm/3" do
    test "seals the goal-file and every declared input, glob-expanded", %{
      dir: dir,
      goal_file: goal_file
    } do
      seal = %Seal{sealed_inputs: ["checks/manifest.toml", "checks/reference/**/*.png"]}
      manifest = Seal.arm(seal, goal_file, dir)

      assert Map.has_key?(manifest, goal_file)
      assert Map.has_key?(manifest, "checks/manifest.toml")
      assert Map.has_key?(manifest, "checks/reference/a.png")
      assert Map.has_key?(manifest, "checks/reference/b.png")
    end

    test "enabled = false seals nothing, including the goal-file", %{
      dir: dir,
      goal_file: goal_file
    } do
      seal = %Seal{enabled: false, sealed_inputs: ["checks/manifest.toml"]}
      assert Seal.arm(seal, goal_file, dir) == %{}
    end

    test "a nil seal config (no [seal] block) seals NOTHING — sealing is opt-in", %{
      dir: dir,
      goal_file: goal_file
    } do
      # A goal that declares no `[seal]` block behaves exactly as it did before
      # ADR-0080: nothing is sealed, not even the goal-file. This is what keeps the
      # #1415 goal-drift guard's observational contract intact (a goal-file
      # rewritten mid-run must still reach `:over_budget` + `goal_drifted`, NOT a
      # `:tampered` hard stop). Declaring `[seal]` is the explicit opt-in.
      assert Seal.arm(nil, goal_file, dir) == %{}
    end

    test "declaring [seal] opts the goal-file itself in, alongside the inputs", %{
      dir: dir,
      goal_file: goal_file
    } do
      manifest = Seal.arm(%Seal{sealed_inputs: ["checks/manifest.toml"]}, goal_file, dir)
      assert Map.has_key?(manifest, goal_file)
      assert Map.has_key?(manifest, "checks/manifest.toml")
    end

    test "mutable_inputs subtracts a legitimately-regenerated path from the seal", %{
      dir: dir,
      goal_file: goal_file
    } do
      seal = %Seal{
        sealed_inputs: ["checks/reference/**/*.png"],
        mutable_inputs: ["checks/reference/b.png"]
      }

      manifest = Seal.arm(seal, goal_file, dir)
      assert Map.has_key?(manifest, "checks/reference/a.png")
      refute Map.has_key?(manifest, "checks/reference/b.png")
    end
  end

  describe "verify/1" do
    test "an untampered manifest verifies :ok", %{dir: dir, goal_file: goal_file} do
      manifest = Seal.arm(%Seal{sealed_inputs: ["checks/manifest.toml"]}, goal_file, dir)
      assert Seal.verify(manifest) == :ok
    end

    test "a modified sealed input is detected, naming the file", %{dir: dir, goal_file: goal_file} do
      manifest = Seal.arm(%Seal{sealed_inputs: ["checks/manifest.toml"]}, goal_file, dir)
      File.write!(Path.join(dir, "checks/manifest.toml"), "threshold = 0.50\n")

      assert Seal.verify(manifest) ==
               {:tampered, %{path: "checks/manifest.toml", change: :modified}}
    end

    test "a modified goal-file is detected once [seal] is declared", %{
      dir: dir,
      goal_file: goal_file
    } do
      # An empty-but-present `[seal]` block is the opt-in; it seals the goal-file.
      manifest = Seal.arm(%Seal{}, goal_file, dir)
      File.write!(goal_file, "id = \"g\"\n# tampered\n")

      assert {:tampered, %{path: ^goal_file, change: :modified}} = Seal.verify(manifest)
    end

    test "a removed sealed input is detected as :removed", %{dir: dir, goal_file: goal_file} do
      manifest = Seal.arm(%Seal{sealed_inputs: ["checks/manifest.toml"]}, goal_file, dir)
      File.rm!(Path.join(dir, "checks/manifest.toml"))

      assert Seal.verify(manifest) ==
               {:tampered, %{path: "checks/manifest.toml", change: :removed}}
    end

    test "a file that appears where a sealed path was absent is :added", %{
      dir: dir,
      goal_file: goal_file
    } do
      manifest = Seal.arm(%Seal{sealed_inputs: ["checks/not_yet.toml"]}, goal_file, dir)
      assert Seal.verify(manifest) == :ok
      File.write!(Path.join(dir, "checks/not_yet.toml"), "surprise\n")

      assert Seal.verify(manifest) == {:tampered, %{path: "checks/not_yet.toml", change: :added}}
    end

    test "an empty manifest is always :ok" do
      assert Seal.verify(%{}) == :ok
    end
  end
end
