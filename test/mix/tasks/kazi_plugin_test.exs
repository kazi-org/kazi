defmodule Mix.Tasks.Kazi.PluginTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  # T61.4 (ADR-0077): the release pipeline runs `mix kazi.plugin --out <dir>
  # --version <tag>` so the PUBLISHED plugin version is the binary release
  # version (lockstep). This pins that the CLI-passed `--version` lands verbatim
  # in the written manifest -- the exact contract the pipeline depends on.
  describe "run/1 -- lockstep --version" do
    test "writes the passed --version into the manifest", %{tmp_dir: tmp} do
      out = Path.join(tmp, "plugin")

      capture_io(fn -> Mix.Tasks.Kazi.Plugin.run(["--out", out, "--version", "9.9.9"]) end)

      manifest = Path.join(out, ".claude-plugin/plugin.json") |> File.read!() |> Jason.decode!()
      assert manifest["version"] == "9.9.9"
    end

    test "re-running the same version is a byte-identical no-op", %{tmp_dir: tmp} do
      out = Path.join(tmp, "plugin")

      run = fn ->
        capture_io(fn -> Mix.Tasks.Kazi.Plugin.run(["--out", out, "--version", "1.2.3"]) end)
      end

      run.()
      first = File.read!(Path.join(out, ".claude-plugin/plugin.json"))
      run.()
      assert File.read!(Path.join(out, ".claude-plugin/plugin.json")) == first
    end

    test "raises without --out" do
      assert_raise Mix.Error, ~r/--out/, fn ->
        Mix.Tasks.Kazi.Plugin.run(["--version", "1.0.0"])
      end
    end

    test "raises on an unknown option", %{tmp_dir: tmp} do
      assert_raise Mix.Error, ~r/unknown option/, fn ->
        Mix.Tasks.Kazi.Plugin.run(["--out", Path.join(tmp, "p"), "--bogus", "x"])
      end
    end
  end
end
