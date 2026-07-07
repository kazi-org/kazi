defmodule Kazi.CrashDump do
  @moduledoc """
  Pins `erl_crash.dump` under kazi's own state dir instead of the workspace CWD
  (issue #856). The VM's default crash-dump location is its current working
  directory, which for `kazi apply` is the user's own repo — so an unhandled VM
  crash used to litter a debug dump (one that can embed env vars) into their
  tree. `configure!/0` sets `ERL_CRASH_DUMP` at boot, before any goal or
  workspace is touched, so every entry point (escript, `mix kazi.run`, the
  release `eval` path, the Burrito binary) shares one non-workspace location.
  """

  @doc """
  The crash-dump directory: `Application.get_env(:kazi, :crash_dump_dir)` (the
  test-override seam, mirroring `Kazi.Runtime`'s `:sinks_dir`) > `<state
  dir>/crash`, where the state dir is `KAZI_STATE_DIR` > `<user-home>/.kazi`.
  """
  @spec dir() :: Path.t()
  def dir do
    Application.get_env(:kazi, :crash_dump_dir) || Path.join(state_dir(), "crash")
  end

  defp state_dir do
    System.get_env("KAZI_STATE_DIR") ||
      Path.join([System.user_home!() || File.cwd!(), ".kazi"])
  end

  @doc "The full erl_crash.dump path this run writes to if it crashes."
  @spec path() :: Path.t()
  def path, do: Path.join(dir(), "erl_crash.dump")

  @doc """
  Points `ERL_CRASH_DUMP` at `path/0`, creating the directory if needed. Called
  once from `Kazi.Application.start/2`. A pre-existing `ERL_CRASH_DUMP` (an
  operator's own override) is left untouched.
  """
  @spec configure!() :: :ok
  def configure! do
    if System.get_env("ERL_CRASH_DUMP") in [nil, ""] do
      File.mkdir_p!(dir())
      System.put_env("ERL_CRASH_DUMP", path())
    end

    :ok
  end
end
