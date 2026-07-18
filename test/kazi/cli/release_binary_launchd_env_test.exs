defmodule Kazi.CLI.ReleaseBinaryLaunchdEnvTest do
  @moduledoc """
  T66.2 (#1484): `run.kazi.bushost`, a macOS launchd LaunchAgent, invokes the
  released binary with a MINIMAL environment (just `PATH` -- no `HOME`, no
  `USER`, none of the other vars an interactive shell always carries). The
  reported symptom was `kazi daemon start` exiting 78 with ZERO log output --
  worse than a failure, an unexplainable one.

  This suite pins the plan's acceptance bar directly (docs/plans/E66.md,
  T66.2): under an `env -i`-minimal invocation, the release binary must
  either serve, or exit non-zero WITH a specific error line naming the
  missing precondition. As of the burrito fork pin in mix.lock at the time
  this test was written, an absent `HOME` (and thus an unresolvable default
  install directory) already produces exactly that -- a full diagnostic
  naming `KAZI_INSTALL_DIR` as the fix, on both stdout and exit code 1 -- so
  this suite is a REGRESSION PIN, not a fix for new behavior: if a future
  burrito bump or `Kazi.CLI` change regresses back to a silent/blank exit,
  this goes red.

  ## Honest skip (NEVER a fake pass)

  NON-hermetic (tagged `:release_binary_live`, excluded by default): it runs
  the real released `kazi` binary (`KAZI_RELEASE_BIN`, else `kazi` on
  `$PATH`) with a fully cleared environment via `env -i`. Skips honestly
  when no burrito-built binary is available. Never starts a real daemon
  against `~/.kazi` -- the minimal env is exactly what makes it fail before
  touching any real state.

      mix test --only release_binary_live test/kazi/cli/release_binary_launchd_env_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :release_binary_live

  test "a launchd-minimal env (`env -i PATH=...`) either serves or fails loud, never silent" do
    case preflight() do
      {:skip, reason} ->
        IO.puts("\n[release_binary_live] SKIPPED (no launchd-env claim): #{reason}")
        :skipped

      {:ok, bin} ->
        {output, status} =
          System.cmd(
            "env",
            [
              "-i",
              "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
              bin,
              "daemon",
              "start",
              "--nats-bin",
              System.find_executable("nats-server") || "/opt/homebrew/bin/nats-server",
              "--nats-port",
              "0"
            ],
            stderr_to_stdout: true
          )

        refute output == "",
               "launchd-minimal invocation produced ZERO output (the exact #1484 symptom) " <>
                 "-- exit status was #{status}"

        if status != 0 do
          assert output =~ "KAZI_INSTALL_DIR" or output =~ "HOME",
                 "launchd-minimal invocation failed (status #{status}) without naming its " <>
                   "missing precondition: #{inspect(output)}"
        end
    end
  end

  @spec preflight() :: {:ok, binary()} | {:skip, String.t()}
  defp preflight do
    bin = System.get_env("KAZI_RELEASE_BIN") || System.find_executable("kazi")

    cond do
      is_nil(bin) ->
        {:skip, "no `kazi` release binary (set KAZI_RELEASE_BIN or put one on $PATH)"}

      is_nil(System.find_executable("env")) ->
        {:skip, "no `env` on $PATH to construct a minimal-env invocation"}

      true ->
        {:ok, bin}
    end
  end
end
