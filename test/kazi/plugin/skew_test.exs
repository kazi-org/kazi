defmodule Kazi.Plugin.SkewTest do
  @moduledoc """
  T61.5 (ADR-0077 decision 2): the binary-vs-plugin version-skew check.

  Every path is exercised without a live Claude Code install by writing a fixture
  plugin tree (`installed_plugins.json` + `.claude-plugin/plugin.json`) under a
  `tmp_dir` and pointing `:claude_home` at it, plus the direct `:plugin_version`
  and `:local_version` seams for the pure comparison logic.
  """
  use ExUnit.Case, async: true

  alias Kazi.Plugin.Skew

  describe "check/1 comparison (seams)" do
    test "matching binary and plugin versions emit nothing" do
      assert Skew.check(local_version: "1.250.0", plugin_version: "1.250.0") == :silent
    end

    test "a mismatch emits exactly one line naming both versions and the channel" do
      assert {:emit, line} =
               Skew.check(local_version: "1.251.0", plugin_version: "1.250.0")

      # exactly one line
      assert String.trim_trailing(line, "\n") == String.trim(line)
      refute String.contains?(String.trim_trailing(line, "\n"), "\n")

      # names BOTH versions
      assert line =~ "1.251.0"
      assert line =~ "1.250.0"
    end

    test "binary ahead -> tells the operator to update the plugin channel" do
      assert {:emit, line} =
               Skew.check(local_version: "1.251.0", plugin_version: "1.250.0")

      assert line =~ "update the plugin"
      assert line =~ "claude plugin update kazi"
    end

    test "plugin ahead -> tells the operator to upgrade the binary channel" do
      assert {:emit, line} =
               Skew.check(local_version: "1.250.0", plugin_version: "1.251.0")

      assert line =~ "upgrade the kazi binary"
      assert line =~ "brew upgrade kazi"
    end

    test "non-semver versions still warn with both versions and a neutral hint" do
      assert {:emit, line} =
               Skew.check(local_version: "dev", plugin_version: "1.250.0")

      assert line =~ "dev"
      assert line =~ "1.250.0"
      assert line =~ "reconcile the two channels"
    end
  end

  describe "check/1 fail-silent" do
    test "a missing plugin manifest path is silent (plugin absent)" do
      assert Skew.check(
               local_version: "1.250.0",
               plugin_manifest_path: "/nonexistent/plugin.json"
             ) == :silent
    end

    test "an empty claude_home (no plugin installed) is silent" do
      assert Skew.check(local_version: "1.250.0", claude_home: unique_tmp()) == :silent
    end

    test "a malformed plugin.json is silent, not a crash" do
      path = Path.join(unique_tmp(), "plugin.json")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{ not json")

      assert Skew.check(local_version: "1.250.0", plugin_manifest_path: path) == :silent
    end
  end

  describe "check/1 on-disk discovery" do
    @tag :tmp_dir
    test "reads the version from a fixture plugin.json via installed_plugins.json", %{
      tmp_dir: home
    } do
      install_kazi_plugin(home, "1.240.0")

      assert {:emit, line} = Skew.check(local_version: "1.250.0", claude_home: home)
      assert line =~ "1.250.0"
      assert line =~ "1.240.0"
    end

    @tag :tmp_dir
    test "matching disk version emits nothing", %{tmp_dir: home} do
      install_kazi_plugin(home, "1.250.0")

      assert Skew.check(local_version: "1.250.0", claude_home: home) == :silent
    end

    @tag :tmp_dir
    test "falls back to scanning the plugin tree when the index lacks a kazi entry", %{
      tmp_dir: home
    } do
      # No installed_plugins.json entry -- only a manifest on disk.
      manifest = Path.join([home, "plugins", "cache", "some-mp", "kazi", "1.240.0"])
      write_manifest(manifest, "1.240.0")

      assert {:emit, line} = Skew.check(local_version: "1.250.0", claude_home: home)
      assert line =~ "1.240.0"
    end
  end

  # --- fixtures --------------------------------------------------------------

  # Writes a `.claude-plugin/plugin.json` under `dir` declaring `version`.
  defp write_manifest(dir, version) do
    path = Path.join([dir, ".claude-plugin", "plugin.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"name" => "kazi", "version" => version}))
    path
  end

  # Simulates a Claude Code install of the kazi plugin under `home`: the manifest
  # plus an `installed_plugins.json` index entry pointing at it.
  defp install_kazi_plugin(home, version) do
    install_path = Path.join([home, "plugins", "cache", "kazi-org", "kazi", version])
    write_manifest(install_path, version)

    index = Path.join([home, "plugins", "installed_plugins.json"])

    File.write!(
      index,
      Jason.encode!(%{
        "version" => 2,
        "plugins" => %{
          "kazi@kazi-org-marketplace" => [
            %{"scope" => "user", "installPath" => install_path, "version" => version}
          ]
        }
      })
    )
  end

  defp unique_tmp do
    dir = Path.join(System.tmp_dir!(), "skew-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
