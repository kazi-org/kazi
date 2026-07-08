defmodule Kazi.Logging.DashboardLogRotationTest do
  @moduledoc """
  Regression checker for a compile-time-vs-runtime path bug: the module used
  to resolve its default log path via a `@default_log_path` MODULE ATTRIBUTE
  (`Path.join([System.user_home!() ...])`), which Elixir freezes at COMPILE
  TIME. For a Burrito release built in CI, that baked in the CI runner's home
  directory (e.g. `/Users/runner/.kazi`) into the shipped binary -- so every
  fresh `kazi dashboard` boot on an operator's own machine tried to `mkdir_p!`
  a path that doesn't exist there and crashed the whole VM with `:eacces`
  (live-verified 2026-07-08, right after wiring this GenServer into the
  standalone dashboard supervision tree exposed it for the first time -- it
  had never actually been booted fresh under `kazi dashboard` before).

  `default_log_path/0` must be a FUNCTION, re-evaluated on every call, honoring
  `KAZI_STATE_DIR` the same way `Kazi.CrashDump.dir/0` does.
  """

  use ExUnit.Case, async: false

  alias Kazi.Logging.DashboardLogRotation

  test "default_log_path/0 honors KAZI_STATE_DIR at call time, not compile time" do
    original = System.get_env("KAZI_STATE_DIR")

    try do
      System.put_env("KAZI_STATE_DIR", "/tmp/kazi-log-rotation-test-a")

      assert DashboardLogRotation.default_log_path() ==
               "/tmp/kazi-log-rotation-test-a/dashboard.log"

      System.put_env("KAZI_STATE_DIR", "/tmp/kazi-log-rotation-test-b")

      assert DashboardLogRotation.default_log_path() ==
               "/tmp/kazi-log-rotation-test-b/dashboard.log"
    after
      if original,
        do: System.put_env("KAZI_STATE_DIR", original),
        else: System.delete_env("KAZI_STATE_DIR")
    end
  end

  test "init/1 creates the log directory under the current KAZI_STATE_DIR, never a frozen path" do
    original = System.get_env("KAZI_STATE_DIR")

    tmp_dir =
      Path.join(System.tmp_dir!(), "kazi-log-rotation-init-#{System.unique_integer([:positive])}")

    try do
      System.put_env("KAZI_STATE_DIR", tmp_dir)
      refute File.dir?(tmp_dir)

      assert {:ok, state} = DashboardLogRotation.init([])
      assert state.log_path == Path.join(tmp_dir, "dashboard.log")
      assert File.dir?(tmp_dir)
    after
      File.rm_rf!(tmp_dir)

      if original,
        do: System.put_env("KAZI_STATE_DIR", original),
        else: System.delete_env("KAZI_STATE_DIR")
    end
  end

  test "init/1 honors an explicit :log_path override regardless of KAZI_STATE_DIR" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "kazi-log-rotation-override-#{System.unique_integer([:positive])}"
      )

    explicit_path = Path.join(tmp_dir, "explicit.log")

    try do
      assert {:ok, state} = DashboardLogRotation.init(log_path: explicit_path)
      assert state.log_path == explicit_path
      assert File.dir?(tmp_dir)
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
