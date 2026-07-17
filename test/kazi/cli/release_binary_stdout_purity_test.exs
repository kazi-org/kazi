defmodule Kazi.CLI.ReleaseBinaryStdoutPurityTest do
  @moduledoc """
  T54.10 (UC-033): the burrito wrapper's maintenance pass runs BEFORE the BEAM
  boots, so no in-app code (the ADR-0023 `--json` logger guard included) can
  protect stdout from it -- only the released binary itself can be tested. On
  a machine where a long-lived process still holds an older payload version,
  the wrapper skips deleting it (ADR-0066) and announces the skip; this suite
  pins, ON THE RELEASE BINARY, that:

    1. `--json` stdout stays a single JSON object with an in-use older payload
       staged (the notice lives on stderr -- true since the ADR-0066 fork ref
       `084e1e3` every fork-built release ships with), and
    2. the notice appears at most ONCE per installed version, not on every
       invocation (kazi-org/burrito PR #1; this assertion goes green only
       once that PR merges, mix.exs bumps the fork pin, and a release built
       from the new pin is installed locally).

  ## Honest skip (NEVER a fake pass)

  NON-hermetic (tagged `:release_binary_live`, excluded by default): it runs
  the real released `kazi` binary (`KAZI_RELEASE_BIN`, else `kazi` on `$PATH`)
  and stages a fake older install -- never touching the real ones -- inside
  that binary's own burrito install prefix, removing it afterwards. The staged
  install carries a `.burrito_live` pidfile for PID 1 (alive-via-EPERM, the
  same trick the fork's own zig tests use), so the wrapper can never delete it
  mid-test. Skips honestly when no burrito-built binary is available.

      mix test --only release_binary_live test/kazi/cli/release_binary_stdout_purity_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :release_binary_live

  @fake_version "0.0.1-t5410-test"
  @notice_fragment "Skipped cleanup of older version (v#{@fake_version})"

  test "--json stdout is a single JSON object with an in-use older payload staged" do
    case preflight() do
      {:skip, reason} ->
        IO.puts("\n[release_binary_live] SKIPPED (no purity claimed): #{reason}")
        :skipped

      {:ok, bin, install_dir} ->
        with_staged_older_install(install_dir, fn ->
          {{stdout, stderr}, 0} = run_split(bin, ["version", "--json"])

          assert {:ok, %{"kazi" => _, "schema_version" => _}} = Jason.decode(stdout)

          refute stdout =~ "Skipped cleanup",
                 "wrapper maintenance chatter leaked onto --json stdout (stderr was: #{inspect(stderr)})"
        end)
    end
  end

  test "the skip notice appears at most once per installed version, on stderr" do
    case preflight() do
      {:skip, reason} ->
        IO.puts("\n[release_binary_live] SKIPPED (no once-per-boot claim): #{reason}")
        :skipped

      {:ok, bin, install_dir} ->
        with_staged_older_install(install_dir, fn ->
          {{out1, err1}, 0} = run_split(bin, ["version"])
          {{out2, err2}, 0} = run_split(bin, ["version"])

          refute out1 =~ @notice_fragment
          refute out2 =~ @notice_fragment

          occurrences =
            [err1, err2]
            |> Enum.map(&(length(String.split(&1, @notice_fragment)) - 1))
            |> Enum.sum()

          assert occurrences <= 1,
                 "skip notice announced #{occurrences} times across two invocations " <>
                   "(expected at most once per installed version; needs the fork pin " <>
                   "bump from kazi-org/burrito PR #1 in the installed release)"
        end)
    end
  end

  # --- preflight: probe the real binary, skip honestly otherwise -------------

  @spec preflight() :: {:ok, binary(), binary()} | {:skip, String.t()}
  defp preflight do
    bin = System.get_env("KAZI_RELEASE_BIN") || System.find_executable("kazi")

    cond do
      is_nil(bin) ->
        {:skip, "no `kazi` release binary (set KAZI_RELEASE_BIN or put one on $PATH)"}

      true ->
        # `maintenance directory` is answered by the burrito wrapper itself,
        # before extraction or cleanup: it both proves the binary is
        # burrito-built and tells us where its install prefix lives.
        case run_split(bin, ["maintenance", "directory"]) do
          {{stdout, _stderr}, 0} ->
            install_dir = String.trim(stdout)

            if File.dir?(install_dir) do
              {:ok, bin, install_dir}
            else
              {:skip, "#{bin} reported a non-existent install dir: #{inspect(install_dir)}"}
            end

          _ ->
            {:skip, "#{bin} does not answer `maintenance directory` (not a burrito build?)"}
        end
    end
  end

  # --- staging ----------------------------------------------------------------

  # Stages a fake OLDER install of the same app, runs `fun`, and cleans up.
  # Burrito's install discovery reads `_metadata.json` (app_name + semver
  # app_version), not the dir name. The `.burrito_live/1` pidfile (PID 1 =
  # alive via EPERM) makes the wrapper SKIP deleting it -- the exact fleet
  # condition under test -- and guarantees the wrapper cannot delete anything
  # real either way. The announced-skips marker is scrubbed of OUR version
  # before and after, so the test is re-runnable and leaves no trace.
  defp with_staged_older_install(install_dir, fun) do
    fake_dir = Path.join(Path.dirname(install_dir), "kazi_t5410_fake_older_install")
    marker = Path.join(install_dir, ".burrito_announced_skips")

    metadata =
      install_dir
      |> Path.join("_metadata.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("app_version", @fake_version)

    File.mkdir_p!(Path.join(fake_dir, ".burrito_live"))
    File.write!(Path.join(fake_dir, "_metadata.json"), Jason.encode!(metadata))
    File.write!(Path.join(fake_dir, ".burrito_live/1"), "")
    drop_marker_line(marker, @fake_version)

    try do
      fun.()
    after
      File.rm_rf!(fake_dir)
      drop_marker_line(marker, @fake_version)
    end
  end

  # Removes only OUR fake version's line from the announced-skips marker (a
  # real fleet machine may hold real entries there; never clobber those).
  defp drop_marker_line(marker_path, version) do
    case File.read(marker_path) do
      {:ok, content} ->
        kept =
          content
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == version or &1 == ""))

        case kept do
          [] -> File.rm(marker_path)
          _ -> File.write!(marker_path, Enum.join(kept, "\n") <> "\n")
        end

      {:error, _} ->
        :ok
    end
  end

  # --- process running --------------------------------------------------------

  # Runs the binary capturing stdout and stderr SEPARATELY (System.cmd merges
  # or passes stderr through; the whole point here is which stream carries what).
  defp run_split(bin, args) do
    err_file = Path.join(System.tmp_dir!(), "t5410-stderr-#{System.unique_integer([:positive])}")

    try do
      {stdout, status} =
        System.cmd(
          "sh",
          ["-c", ~s(exec "$0" "$@" 2>) <> shell_quote(err_file), bin | args]
        )

      stderr =
        case File.read(err_file) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      {{stdout, stderr}, status}
    after
      File.rm(err_file)
    end
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
