defmodule Kazi.CLI.JsonStdoutPurityTest do
  @moduledoc """
  Issue #804: kazi is a CLI (ADR-0023's `--json` machine surface) -- stdout must
  carry ONLY the program's own output (prose, or a single JSON object under
  `--json`); OTP/Ecto log lines (the "Migrations already up" repro) must never
  land there ahead of it, or a `jq`-based parse of the promised single JSON
  object breaks. See `docs/adr/0023-*.md` and the issue for the full repro.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  require Logger

  test "the default :logger handler is configured to write to stderr, not stdout" do
    assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
  end

  test "a Logger call lands on stderr, never on stdout" do
    out =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          Logger.warning("json_stdout_purity_test marker")
          Logger.flush()
        end)
      end)

    refute out =~ "json_stdout_purity_test marker"
  end

  test "a Logger call emitted mid-run does not corrupt a --json stdout capture" do
    out =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          Logger.warning("noise before the JSON object")
          Logger.flush()
          IO.puts(Jason.encode!(%{schema_version: 2, ok: true}))
        end)
      end)

    assert {:ok, %{"ok" => true}} = Jason.decode(out)
  end
end
