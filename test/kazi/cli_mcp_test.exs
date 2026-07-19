defmodule Kazi.CLIMcpTest do
  @moduledoc """
  T33.1 (ADR-0044): the installed `kazi mcp` verb starts the SAME
  `Kazi.MCP.Server` over stdio that `mix kazi.mcp` starts — shared via
  `Kazi.MCP.Stdio`, so the two launch paths cannot drift.

  Two tiers:

    * Tier 1 — the argv boundary: `parse/1` dispatches `["mcp"]` to the `mcp`
      command (not the unknown-command error), rejects extra arguments, and leaves
      every OTHER command's parse unchanged when the verb is absent.
    * Tier 2 — the real entry point over stdio: we drive `Kazi.CLI.run(["mcp"],
      …)` with `ExUnit.CaptureIO` feeding line-delimited JSON-RPC on stdin and
      capturing stdout, and assert the verb (1) lists the SAME tools as
      `Kazi.MCP.Server.tools()` (the tools `mix kazi.mcp` would list) and (2)
      answers a `kazi_status` call against the real read-model. This is the
      launch-parity smoke ADR-0044 calls sufficient.

  HERMETIC: the boundary test passes `boot: false` (the app + read-model are
  already running in the test env) and `redirect_logging: false` (do not mutate
  the global logger), and reads/writes through the captured stdio against the test
  SQLite Sandbox — no real `claude`, git, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}
  alias Kazi.MCP.Server

  # ===========================================================================
  # Tier 1 — the argv boundary
  # ===========================================================================

  describe "parse/1 — the mcp verb" do
    test "`mcp` parses to the mcp command (it is dispatchable, ADR-0044 decision 3)" do
      assert {:mcp, []} = Kazi.CLI.parse(["mcp"])
    end

    test "`mcp` takes no positional arguments (a stdio server, not a --json command)" do
      assert {:error, message} = Kazi.CLI.parse(["mcp", "extra"])
      assert message =~ "unexpected argument"
    end

    test "absent the verb, argv handling is unchanged" do
      # The new clause sits BEFORE the catch-all, so every other command still
      # parses exactly as it did, and an unknown command still errors.
      assert {:run, "g.toml", _} = Kazi.CLI.parse(["apply", "g.toml"])
      assert {:status, "ref", _} = Kazi.CLI.parse(["status", "ref"])
      assert {:install_skill, _} = Kazi.CLI.parse(["install-skill"])
      assert {:error, _} = Kazi.CLI.parse(["not-a-command"])
    end
  end

  # ===========================================================================
  # Tier 2 — the real `kazi mcp` entry point over stdio
  # ===========================================================================

  describe "kazi mcp — the stdio server (launch parity, ADR-0044)" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      :ok
    end

    test "starts the server, lists the same tools as `mix kazi.mcp`, and answers kazi_status" do
      # A persisted run the read-model status tool resolves — proving the verb
      # serves real state, not a stub (the same read-model `mix kazi.mcp` reads).
      vector =
        PredicateVector.new(%{code: PredicateResult.pass(), live: PredicateResult.fail()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "cli-mcp-run",
          iteration_index: 3,
          predicate_vector: vector,
          converged: false
        })

      # Two line-delimited JSON-RPC requests on stdin: list the tools, then call
      # kazi_status for the persisted ref. EOF after them ends the serve loop.
      stdin =
        [
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{"name" => "kazi_status", "arguments" => %{"ref" => "cli-mcp-run"}}
          }
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      output =
        capture_io(stdin, fn ->
          # The REAL CLI dispatch over a non-TTY, stdio-framed transport. `boot:
          # false` / `redirect_logging: false` keep the test hermetic (the app is
          # already up; the global logger is left untouched).
          assert Kazi.CLI.run(["mcp"], boot: false, redirect_logging: false) == 0
        end)

      responses =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert length(responses) == 2

      [tools_resp, status_resp] = responses

      # tools/list returns EXACTLY the tools `Kazi.MCP.Server.tools()` defines —
      # the same set `mix kazi.mcp` would list (shared server module, no fork).
      assert tools_resp["id"] == 1
      listed = Enum.map(tools_resp["result"]["tools"], & &1["name"]) |> Enum.sort()
      canonical = Enum.map(Server.tools(), & &1["name"]) |> Enum.sort()
      assert listed == canonical

      # kazi_status answers against the real read-model: the persisted run resolves.
      assert status_resp["id"] == 2
      refute status_resp["result"]["isError"]
      payload = status_resp["result"]["structuredContent"]
      assert payload["kind"] == "run"
      assert payload["ref"] == "cli-mcp-run"
      assert payload["iteration"] == 3
    end

    test "stdout carries ONLY JSON-RPC — every emitted line decodes as a JSON object" do
      stdin = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"}) <> "\n"

      output =
        capture_io(stdin, fn ->
          assert Kazi.CLI.run(["mcp"], boot: false, redirect_logging: false) == 0
        end)

      # No human prose may leak onto the transport: each non-blank stdout line is
      # itself a valid JSON object (the MCP stdio framing).
      for line <- String.split(output, "\n"), String.trim(line) != "" do
        assert match?({:ok, %{}}, Jason.decode(line)),
               "a non-JSON line leaked onto the MCP transport: #{inspect(line)}"
      end
    end
  end
end
