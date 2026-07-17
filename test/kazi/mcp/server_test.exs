defmodule Kazi.MCP.ServerTest do
  @moduledoc """
  T16.5 (ADR-0024 decision 4): the kazi MCP server — self-describing tools over
  JSON-RPC 2.0.

  These tests drive the PURE request→response dispatcher
  (`Kazi.MCP.Server.handle_request/2`) directly, not a real stdio loop, so the
  whole protocol is exercised without spawning the server process. The kazi
  functions the tools dispatch to are reached through their existing injection
  seams:

    * `kazi_plan` drives a STUB `Kazi.HarnessAdapter` (the `:harness` seam) —
      no real `claude`, no network;
    * `kazi_apply` drives a real fixture run against a temp git workspace with a
      noop harness STUB binary (`:adapter_opts` command) and a tight budget, so
      it terminates deterministically with NO network;
    * `kazi_status` / `kazi_list_proposed` / `kazi_approve` read/transition the
      real SQLite read-model in the test sandbox.

  HERMETIC throughout: no real `claude`/`gh`/`gcloud`/network.
  """
  use ExUnit.Case, async: false

  alias Kazi.MCP.Server
  alias Kazi.Repo

  # The injectable stub harness (the seam): hands back a fixed JSON proposal in
  # the result map's `:result` field — the `claude --output-format json` envelope
  # shape (T4.1). No real claude, no network.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @proposal ~s({
      "name": "Health endpoint",
      "predicates": [
        {"id": "health", "provider": "http_probe",
         "description": "GET /healthz returns 200",
         "config": {"url": "https://example.test/healthz"}}
      ]
    })

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{result: @proposal}}
  end

  # ===========================================================================
  # Tier 1 — pure protocol dispatch (no DB, no seams)
  # ===========================================================================

  describe "initialize" do
    test "returns server info + the tools capability" do
      response = Server.handle_request(request("initialize", %{}, 1))

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      result = response["result"]
      assert is_binary(result["protocolVersion"])
      assert result["serverInfo"]["name"] == "kazi"
      assert is_binary(result["serverInfo"]["version"])
      # The tools capability MUST be advertised so a client knows to call tools/list.
      assert Map.has_key?(result["capabilities"], "tools")
    end
  end

  describe "tools/list — self-describing tools" do
    test "returns the primary kazi tools, each with name + description + inputSchema" do
      response = Server.handle_request(request("tools/list", %{}, 2))
      tools = response["result"]["tools"]

      names = Enum.map(tools, & &1["name"]) |> Enum.sort()

      # T27.5/T27.9 (ADR-0032): the tool names match the CLI verbs —
      # `kazi_plan`/`kazi_apply` (was `kazi_propose`/`kazi_run`). The deprecated
      # `kazi_propose`/`kazi_run` tool aliases were REMOVED in v0.6.0 (T27.9).
      # T51.3 (ADR-0067) added the session-bus tools alongside these five;
      # kazi_bus_watch (the no-poll wait, issue #1091) joined them later.
      assert names == [
               "kazi_apply",
               "kazi_approve",
               "kazi_bus_name",
               "kazi_bus_post",
               "kazi_bus_read",
               "kazi_bus_tell",
               "kazi_bus_watch",
               "kazi_bus_who",
               "kazi_list_proposed",
               "kazi_plan",
               "kazi_status"
             ]

      # SELF-DESCRIBING: every tool carries a non-empty description and a JSON
      # Schema inputSchema (an "object" with properties).
      for tool <- tools do
        assert is_binary(tool["name"]) and tool["name"] != ""
        assert is_binary(tool["description"]) and tool["description"] != ""
        assert tool["inputSchema"]["type"] == "object"
        assert is_map(tool["inputSchema"]["properties"])
      end
    end

    test "the plan/approve/status tools declare their required arguments" do
      tools = tools_by_name()

      assert tools["kazi_plan"]["inputSchema"]["required"] == ["idea"]
      assert tools["kazi_approve"]["inputSchema"]["required"] == ["proposal_ref"]
      assert tools["kazi_status"]["inputSchema"]["required"] == ["ref"]
    end

    test "apply and status tools point at the committed result schemas (Kazi.CLI.Schema)" do
      tools = tools_by_name()

      # The result-shape descriptor is REUSED from Kazi.CLI.Schema (T16.1), so the
      # MCP tool docs and the CLI --json contract cannot drift. The descriptor is
      # the atom-keyed schema map Kazi.CLI.Schema emits. T27.4 (ADR-0032) renamed
      # the result-schema command key `run` -> `apply`; T27.5 renames the tool
      # `kazi_run` -> `kazi_apply` so it fetches the `apply` schema by its primary key.
      assert tools["kazi_apply"]["inputSchema"]["resultSchema"].command == "apply"
      assert tools["kazi_status"]["inputSchema"]["resultSchema"].command == "status"

      assert tools["kazi_apply"]["inputSchema"]["resultSchema"].schema_version ==
               Kazi.CLI.Schema.schema_version()
    end
  end

  describe "errors — unknown method / tool / bad params" do
    test "an unknown method is a JSON-RPC method-not-found error" do
      response = Server.handle_request(request("does/not/exist", %{}, 9))

      assert response["id"] == 9
      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "unknown method"
      refute Map.has_key?(response, "result")
    end

    test "an unknown tool is a JSON-RPC error" do
      response =
        Server.handle_request(
          request("tools/call", %{"name" => "kazi_nope", "arguments" => %{}}, 10)
        )

      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "unknown tool"
    end

    test "a tool call missing a required argument is an invalid-params error" do
      response =
        Server.handle_request(
          request("tools/call", %{"name" => "kazi_plan", "arguments" => %{}}, 11)
        )

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] =~ "idea"
    end

    test "a notification (no id) expects no response" do
      assert Server.handle_request(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             }) == :no_reply
    end

    test "a non-request shape is rejected" do
      response = Server.handle_request(%{"jsonrpc" => "2.0", "id" => 12})
      assert response["error"]["code"] == -32_602
    end
  end

  # ===========================================================================
  # Tier 2 — tools/call dispatches to the real kazi functions (hermetic seams)
  # ===========================================================================

  describe "tools/call — kazi_plan (stub harness seam)" do
    setup :checkout_sandbox

    test "dispatches to Kazi.Authoring.propose and returns the drafted goal" do
      response =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_plan", "arguments" => %{"idea" => "a health endpoint"}},
            20
          ),
          harness: StubHarness
        )

      result = response["result"]
      refute result["isError"]

      payload = result["structuredContent"]
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert payload["status"] == "proposed"
      assert is_binary(payload["proposal_ref"])
      assert payload["goal_id"] != nil
      assert [%{"id" => "health", "provider" => "http_probe"}] = payload["predicates"]

      # The same object is mirrored as a text content block (the MCP content shape).
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert {:ok, decoded} = Jason.decode(text)
      assert decoded == payload
    end

    test "the removed `kazi_propose` alias is now an unknown tool (T27.9, ADR-0032)" do
      # The deprecated `kazi_propose` tool alias was removed in v0.6.0: it no longer
      # dispatches to `kazi_plan` and is a JSON-RPC unknown-tool error instead.
      response =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_propose", "arguments" => %{"idea" => "   "}},
            21
          ),
          harness: StubHarness
        )

      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "unknown tool"
    end

    test "caller-drafts mode parses a supplied proposal with no harness" do
      proposal = %{
        "name" => "Caller drafted",
        "predicates" => [%{"id" => "ok", "provider" => "test_runner"}]
      }

      response =
        Server.handle_request(
          request(
            "tools/call",
            %{
              "name" => "kazi_plan",
              "arguments" => %{"idea" => "caller drafts this", "proposal" => proposal}
            },
            22
          )
        )

      payload = response["result"]["structuredContent"]
      assert payload["status"] == "proposed"
      assert [%{"id" => "ok", "provider" => "tests"}] = payload["predicates"]
    end
  end

  describe "tools/call — kazi_approve / kazi_list_proposed / kazi_status (read-model)" do
    setup :checkout_sandbox

    test "approve transitions a proposed goal and status reflects it" do
      # Propose first (stub harness), then approve via the MCP tool.
      proposed =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_plan", "arguments" => %{"idea" => "approve me please"}},
            30
          ),
          harness: StubHarness
        )

      ref = proposed["result"]["structuredContent"]["proposal_ref"]

      # list_proposed shows it in the review queue.
      listed =
        Server.handle_request(
          request("tools/call", %{"name" => "kazi_list_proposed", "arguments" => %{}}, 31)
        )

      refs = Enum.map(listed["result"]["structuredContent"]["proposals"], & &1["proposal_ref"])
      assert ref in refs

      # approve transitions proposed → approved.
      approved =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_approve", "arguments" => %{"proposal_ref" => ref}},
            32
          )
        )

      approve_payload = approved["result"]["structuredContent"]
      refute approved["result"]["isError"]
      assert approve_payload["status"] == "approved"
      assert approve_payload["proposal_ref"] == ref
      assert approve_payload["mode"] == "create"

      # status on the ref resolves to the proposal, now approved.
      status =
        Server.handle_request(
          request("tools/call", %{"name" => "kazi_status", "arguments" => %{"ref" => ref}}, 33)
        )

      status_payload = status["result"]["structuredContent"]
      assert status_payload["kind"] == "proposal"
      assert status_payload["status"] == "approved"
    end

    test "approving an unknown ref is a kazi error tool result (isError)" do
      response =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_approve", "arguments" => %{"proposal_ref" => "prop-nope"}},
            34
          )
        )

      assert response["result"]["isError"]
      assert response["result"]["structuredContent"]["status"] == "error"
    end

    test "status on an unknown ref is a structured not_found result" do
      response =
        Server.handle_request(
          request(
            "tools/call",
            %{"name" => "kazi_status", "arguments" => %{"ref" => "ghost"}},
            35
          )
        )

      payload = response["result"]["structuredContent"]
      assert payload["kind"] == "not_found"
      assert payload["ref"] == "ghost"
    end
  end

  describe "tools/call — kazi_apply (fixture run, noop harness stub)" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "dispatches to Kazi.Runtime.run and returns the terminal result", %{tmp_dir: tmp_dir} do
      work = setup_work(tmp_dir)
      goal_file = write_unfixable_goal_file(tmp_dir, work)

      response =
        Server.handle_request(
          request(
            "tools/call",
            %{
              "name" => "kazi_apply",
              "arguments" => %{"goal_file" => goal_file, "workspace" => work}
            },
            40
          ),
          adapter_opts: [command: write_noop_harness_stub(tmp_dir)],
          run_opts: [
            budget: Kazi.Budget.new(max_iterations: 1),
            flake_max_retries: 0,
            stuck_iterations: 0,
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          ]
        )

      result = response["result"]
      refute result["isError"]

      payload = result["structuredContent"]
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert payload["goal_id"] == "mcp-unfixable"
      # The tight budget stops the never-converging loop with over_budget.
      assert payload["status"] == "over_budget"
      assert payload["next_action"] == "raise_budget"
      assert payload["budget_spent"]["exceeded"] == "max_iterations"

      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector["code"] == "fail"

      # T34.6 (ADR-0046 §5): the MCP run result mirrors the CLI's additive
      # `economy` object so both surfaces stay the SAME shape. An over-budget run
      # never converged ⇒ iterations-to-convergence is OMITTED (unavailable).
      economy = payload["economy"]
      assert is_map(economy)
      assert economy["status"] == "over_budget"
      assert economy["stuck"] == false
      refute Map.has_key?(economy, "iterations_to_convergence")
    end

    test "the removed `kazi_run` alias is now an unknown tool (T27.9, ADR-0032)" do
      # The deprecated `kazi_run` tool alias was removed in v0.6.0: it no longer
      # dispatches to `kazi_apply` and is a JSON-RPC unknown-tool error instead.
      response =
        Server.handle_request(
          request("tools/call", %{"name" => "kazi_run", "arguments" => %{}}, 41)
        )

      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "unknown tool"
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp request(method, params, id) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}
  end

  defp tools_by_name do
    Server.tools() |> Map.new(fn t -> {t["name"], t} end)
  end

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # A minimal git working tree the runtime can operate against (the workspace).
  defp setup_work(tmp_dir) do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work])
    {_, 0} = System.cmd("git", ["config", "user.email", "kazi-test@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "kazi test"], cd: work)
    File.write!(Path.join(work, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work)
    work
  end

  # A single code predicate that NEVER passes (the marker is never created), so the
  # loop cannot converge — the tight budget is what terminates it.
  defp write_unfixable_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "unfixable_goal.toml")

    File.write!(path, """
    id = "mcp-unfixable"
    name = "MCP run never converges"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_created.txt"]
    """)

    path
  end

  # A noop harness stub: runs but never satisfies the code predicate.
  defp write_noop_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_noop_harness_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
