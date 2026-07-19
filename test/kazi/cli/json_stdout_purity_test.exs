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

  # ---------------------------------------------------------------------------
  # T39.4 (ADR-0049 decision 4): the noisy dev-logger path. `config/config.exs`
  # routes the default handler to stderr, but a dev/`mix run` environment can
  # point it back at stdout; the CLI's `--json` guard must restore the invariant
  # BEFORE any command output, and must NOT touch logging on non-`--json` runs.
  # ---------------------------------------------------------------------------

  describe "the --json guard under a noisy (stdout) dev logger" do
    setup do
      {:ok, original} = :logger.get_handler_config(:default)

      on_exit(fn ->
        _ = :logger.remove_handler(:default)
        _ = :logger.add_handler(:default, original.module, Map.delete(original, :id))
      end)

      :ok
    end

    test "a --json run reroutes logging to stderr and stdout decodes as one object" do
      point_default_handler_at(:standard_io)

      out = capture_io(fn -> assert Kazi.CLI.run(["version", "--json"]) == 0 end)

      # The guard rerouted the noisy handler before printing …
      assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
      # … and the whole stdout capture is exactly one JSON object.
      assert {:ok, %{"kazi" => _, "schema_version" => _}} = Jason.decode(out)
    end

    test "a non---json run leaves the logger configuration untouched" do
      point_default_handler_at(:standard_io)

      out = capture_io(fn -> assert Kazi.CLI.run(["version"]) == 0 end)

      assert {:ok, %{config: %{type: :standard_io}}} = :logger.get_handler_config(:default)
      assert out =~ "kazi "
    end
  end

  # The `mix run` path that exhibited the issue #804 leak, end to end at the
  # file-descriptor level: a child `mix run` simulates the noisy dev logger
  # (default handler pointed back at stdout, level :info), then invokes the CLI
  # entry with `--json` on a read-model command — so Ecto's migrator fires the
  # ORIGINAL leaking line ("Migrations already up", :info) mid-run. The child's
  # real stdout must decode as exactly one JSON object; logs may go to stderr.
  @tag timeout: 240_000
  test "mix run: --json stdout decodes as exactly one object despite a mid-run Ecto log" do
    project_root = Path.expand("../../..", __DIR__)

    eval = """
    {:ok, handler} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        handler.module,
        handler
        |> Map.delete(:id)
        |> Map.put(:config, %{handler.config | type: :standard_io})
      )

    Logger.configure(level: :info)
    System.halt(Kazi.CLI.run(["list-proposed", "--json"]))
    """

    {out, status} =
      System.cmd("mix", ["run", "-e", eval],
        cd: project_root,
        env: [{"MIX_ENV", "test"}, {"TEST_SERVER", "false"}]
      )

    assert status == 0
    assert {:ok, %{"schema_version" => _, "proposals" => _}} = Jason.decode(out)
  end

  defp point_default_handler_at(type) do
    {:ok, handler} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        handler.module,
        handler
        |> Map.delete(:id)
        |> Map.put(:config, %{handler.config | type: type})
      )
  end
end
