defmodule Kazi.CLI.DashboardTest do
  @moduledoc """
  T46.4 (ADR-0057): the `kazi dashboard` verb — a standalone fleet-mode boot of
  the web endpoint against the shared read-model + run registry, with NO goal
  loop in the process (ADR-0011 reaffirmed at fleet scope).

  Two tiers:

    * Tier 1 — the argv boundary: `parse/1` dispatches `["dashboard"]` (and
      `--port`/`--bind`) to the `dashboard` command, rejects extra positional
      arguments, and leaves every other command's parse unchanged.
    * Tier 2 — the real entry point: `Kazi.CLI.run(["dashboard"], …)` with a
      stubbed `:serve_forever` (so the test doesn't hang) asserts the verb
      recognizes the endpoint this test process ALREADY supervises (the normal
      `mix test` app boot) and reports it instead of trying to rebind the
      port — the "already running" branch every dev/test/mix-task entry point
      takes.

  HERMETIC: no real socket is opened by this test (the endpoint is already
  supervised by the app under test), no network, no NATS.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # ===========================================================================
  # Tier 1 — the argv boundary
  # ===========================================================================

  describe "parse/1 — the dashboard verb" do
    test "`dashboard` parses to the dashboard command with no flags set" do
      assert {:dashboard, opts} = Kazi.CLI.parse(["dashboard"])
      assert opts[:port] == nil
      assert opts[:bind] == nil
    end

    test "`--port`/`--bind` are threaded through" do
      assert {:dashboard, opts} =
               Kazi.CLI.parse(["dashboard", "--port", "4321", "--bind", "0.0.0.0"])

      assert opts[:port] == 4321
      assert opts[:bind] == "0.0.0.0"
    end

    test "an unexpected positional argument is a usage error" do
      assert {:error, message} = Kazi.CLI.parse(["dashboard", "extra"])
      assert message =~ "unexpected argument"
    end

    test "absent the verb, argv handling for the other commands is unchanged" do
      assert {:run, "g.toml", _} = Kazi.CLI.parse(["apply", "g.toml"])
      assert {:mcp, []} = Kazi.CLI.parse(["mcp"])
      assert {:error, _} = Kazi.CLI.parse(["not-a-command"])
    end
  end

  describe "help --json" do
    test "the dashboard command is listed in the generated command surface" do
      json_output = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"], []) == 0 end)

      decoded = Jason.decode!(json_output)
      names = Enum.map(decoded["commands"], & &1["name"])
      assert "dashboard" in names
    end
  end

  # ===========================================================================
  # Tier 2 — the real `kazi dashboard` entry point
  # ===========================================================================

  describe "standalone_endpoint_config/3 — the fresh-boot endpoint config" do
    test "pins check_origin to :conn so the LV socket connects on any host" do
      config = Kazi.CLI.standalone_endpoint_config([], "127.0.0.1", 4321)

      # Regression: the compiled prod config cannot know the browsing host
      # (localhost / 127.0.0.1 / a LAN IP), and Phoenix's default origin check
      # rejected the websocket on any non-default host/port -- the page
      # rendered but every phx-click interaction was silently dead.
      assert config[:check_origin] == :conn
      assert config[:server] == true
      assert config[:http][:port] == 4321
      assert is_binary(config[:secret_key_base])
    end

    test "keeps a configured secret_key_base instead of generating one" do
      config =
        Kazi.CLI.standalone_endpoint_config([secret_key_base: "keep-me"], "0.0.0.0", 4050)

      assert config[:secret_key_base] == "keep-me"
      assert config[:check_origin] == :conn
    end
  end

  describe "kazi dashboard — standalone fleet-mode boot" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
      :ok
    end

    test "recognizes the endpoint this process already supervises and reports it" do
      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["dashboard"], serve_forever: fn -> :ok end) == 0
        end)

      assert output =~ "kazi dashboard"
      assert output =~ "mission control"
      assert output =~ "already"
    end

    test "does not start a second endpoint (no port conflict) when run twice" do
      capture_io(fn ->
        assert Kazi.CLI.run(["dashboard"], serve_forever: fn -> :ok end) == 0
        assert Kazi.CLI.run(["dashboard"], serve_forever: fn -> :ok end) == 0
      end)
    end

    test "returns after the injected serve_forever seam completes (does not hang)" do
      parent = self()

      capture_io(fn ->
        assert Kazi.CLI.run(["dashboard"],
                 serve_forever: fn -> send(parent, :served) end
               ) == 0
      end)

      assert_received :served
    end
  end
end
