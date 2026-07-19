defmodule Kazi.CLIApplyJsonErrorTest do
  @moduledoc """
  M9 (deep-review-001): `kazi apply <goal> --json` on a GOAL-LOAD failure (a
  missing file, or a file that fails to parse/validate) emits a single JSON
  error object on STDOUT with a non-zero exit -- the SAME `emit_json_error`
  convention every other `--json` command follows (`export`/`lint`/`status`/
  `plan`). Before the fix this path wrote a human line to stderr and NOTHING to
  stdout, so an orchestrator parsing stdout under `--json` saw an empty stream.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "a missing goal-file emits a JSON error object on stdout, not a human stderr line" do
    missing = "/tmp/kazi-m9-does-not-exist-#{System.unique_integer([:positive])}.toml"
    test_pid = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            assert Kazi.CLI.run(["apply", missing, "--workspace", "/tmp", "--json"]) == 1
          end)

        send(test_pid, {:stdout, out})
      end)

    assert_received {:stdout, out}

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert is_binary(payload["error"])
    assert payload["error"] =~ missing
    assert payload["schema_version"]

    # Nothing human-oriented leaked to stderr under --json.
    refute err =~ "error: could not load goal-file"
  end

  test "a malformed (unparseable TOML) goal-file emits a JSON error object on stdout" do
    dir = Path.join(System.tmp_dir!(), "kazi-m9-bad-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    goal_file = Path.join(dir, "bad.goal.toml")
    File.write!(goal_file, "this is not [ valid toml")
    on_exit(fn -> File.rm_rf(dir) end)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["apply", goal_file, "--workspace", dir, "--json"]) == 1
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert is_binary(payload["error"])
  end

  test "without --json a load failure still writes the human stderr line (unchanged default)" do
    missing = "/tmp/kazi-m9-does-not-exist-#{System.unique_integer([:positive])}.toml"

    err =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run(["apply", missing, "--workspace", "/tmp"]) == 1
      end)

    assert err =~ "error: could not load goal-file"
  end
end
