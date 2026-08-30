defmodule Kazi.Bus.HookGateTest do
  @moduledoc """
  ADR-0084 (issue #1705): the opt-in gate `kazi bus hook <event>` checks
  before doing any work -- installing the Claude Code plugin declares the
  hooks (ADR-0077), but no longer arms them by itself.

  HERMETIC: every test injects `:marker_path` (a tmp file) and/or `:getenv`
  so the real `~/.config/kazi/bus-hooks-enabled` and process environment are
  never touched.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.HookGate

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "kazi-hook-gate-#{System.unique_integer([:positive])}/bus-hooks-enabled"
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    {:ok, marker_path: path}
  end

  describe "enabled?/1 defaults OFF" do
    test "neither env nor marker present -> disabled", %{marker_path: path} do
      refute HookGate.enabled?(marker_path: path, getenv: fn _ -> nil end)
    end

    test "with no opts at all and a getenv stub returning nil, still disabled" do
      refute HookGate.enabled?(
               getenv: fn _ -> nil end,
               marker_path: "/nonexistent/-#{System.unique_integer([:positive])}"
             )
    end
  end

  describe "enabled?/1 via the KAZI_BUS_HOOKS env var" do
    test "\"1\" enables", %{marker_path: path} do
      assert HookGate.enabled?(marker_path: path, getenv: fn "KAZI_BUS_HOOKS" -> "1" end)
    end

    test "\"true\" enables", %{marker_path: path} do
      assert HookGate.enabled?(marker_path: path, getenv: fn "KAZI_BUS_HOOKS" -> "true" end)
    end

    test "any other value stays disabled", %{marker_path: path} do
      refute HookGate.enabled?(marker_path: path, getenv: fn "KAZI_BUS_HOOKS" -> "0" end)
      refute HookGate.enabled?(marker_path: path, getenv: fn "KAZI_BUS_HOOKS" -> "yes" end)
      refute HookGate.enabled?(marker_path: path, getenv: fn "KAZI_BUS_HOOKS" -> "" end)
    end
  end

  describe "enabled?/1 via the marker file" do
    test "a present marker enables even with no env var", %{marker_path: path} do
      assert :ok = HookGate.enable(marker_path: path)
      assert HookGate.enabled?(marker_path: path, getenv: fn _ -> nil end)
    end

    test "disable/1 removes the marker and enabled?/1 flips back to false", %{marker_path: path} do
      assert :ok = HookGate.enable(marker_path: path)
      assert HookGate.enabled?(marker_path: path, getenv: fn _ -> nil end)

      assert :ok = HookGate.disable(marker_path: path)
      refute HookGate.enabled?(marker_path: path, getenv: fn _ -> nil end)
    end

    test "disable/1 on an absent marker is a no-op :ok", %{marker_path: path} do
      refute File.exists?(path)
      assert :ok = HookGate.disable(marker_path: path)
    end

    test "enable/1 creates parent directories", %{marker_path: path} do
      refute File.exists?(Path.dirname(path))
      assert :ok = HookGate.enable(marker_path: path)
      assert File.exists?(path)
    end
  end

  describe "enabled?/1 explicit override wins outright" do
    test "true overrides an absent env/marker", %{marker_path: path} do
      assert HookGate.enabled?(
               bus_hooks_enabled: true,
               marker_path: path,
               getenv: fn _ -> nil end
             )
    end

    test "false overrides a present marker AND a truthy env var", %{marker_path: path} do
      assert :ok = HookGate.enable(marker_path: path)

      refute HookGate.enabled?(
               bus_hooks_enabled: false,
               marker_path: path,
               getenv: fn "KAZI_BUS_HOOKS" -> "1" end
             )
    end
  end

  describe "marker_path/1" do
    test "an explicit :marker_path is expanded and returned verbatim (already absolute)" do
      assert HookGate.marker_path(marker_path: "/tmp/x/bus-hooks-enabled") ==
               "/tmp/x/bus-hooks-enabled"
    end

    test "with no override, resolves under the real home directory" do
      home = System.user_home!()
      assert HookGate.marker_path([]) == Path.join([home, ".config", "kazi", "bus-hooks-enabled"])
    end
  end
end
