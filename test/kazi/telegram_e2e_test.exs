defmodule Kazi.TelegramE2ETest do
  @moduledoc """
  T3.7c (UC-019): the Telegram bridge wired end to end — ingress → approval →
  run → egress — through `Kazi.Telegram.handle/2`.

  Tier 2 (e2e across boundaries via doubles). One round-trip is driven the way a
  human would: a fixture inbound Telegram message (via the in-memory client
  double) becomes a `proposed` goal through `Kazi.Authoring.propose/2`, is
  approved into a runnable `Kazi.Goal` (`Kazi.Authoring.approve/2`), driven to a
  terminal outcome by `Kazi.Runtime.run/2` through the same injectable seams
  `Kazi.RuntimeTest`/`Kazi.CLIAuthoringTest` use, and EXACTLY ONE outbound ping
  carrying the terminal status is pinged back to the originating chat — captured
  by the in-memory double.

  HERMETIC: the Telegram client is the in-memory double (no bot token, no
  network); the harness that drafts the proposal is an injected stub (no real
  `claude`); the runtime's integrate/deploy are local stubs over a bare git
  origin + a local HTTP probe; the read-model is the test SQLite Sandbox. No
  NATS, no real claude, no network beyond loopback.

  This proves ADR-0011 decoupling held: the bridge only calls the public
  `Kazi.Authoring`/`Kazi.Runtime` APIs (§2/§4) and consumes the loop's terminal
  *result* (§1) — it never reaches into `Kazi.Loop` or `Kazi.Harness.*`.
  """
  # Real git + real loopback HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.Repo
  alias Kazi.Telegram
  alias Kazi.Telegram.InMemoryClient
  alias Kazi.Telegram.Message

  @chat_id 4242

  # An injected stub harness (the authoring seam): returns a fixed JSON proposal
  # in the result map's `:result` field — the shape a `claude --output-format
  # json` envelope carries (T4.1). No real claude, no network. It drafts a goal of
  # the same SHAPE the runtime e2e converges: a test_runner code predicate + an
  # http_probe live predicate, whose config the local stubs satisfy. The live
  # predicate's URL is staged per-test (a random port) via __URL__.
  @proposal ~s({
    "name": "Telegram authoring e2e",
    "predicates": [
      {"id": "code", "provider": "test_runner",
       "description": "the fix lands",
       "config": {"cmd": "sh", "args": ["-c", "test -f fixed.txt"]}},
      {"id": "live", "provider": "http_probe",
       "description": "the endpoint serves 200",
       "config": {"url": "__URL__", "expect_status": 200, "expect_body": "ok"}}
    ]
  })

  setup do
    # The runtime's persistence seam writes through Kazi.ReadModel on the loop's
    # process. Share this checked-out Sandbox connection with any process so the
    # loop's writes land in the same transaction the test reads from.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "handle/2 — the full bridge round-trip via doubles" do
    @describetag :tmp_dir

    test "inbound message → proposed → approve → run → terminal event → one outbound ping",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A local HTTP server the live probe really requests, starting "down" so the
      # live predicate fails pre-deploy (the goal is NOT vacuous at t0); the deploy
      # stub flips it to "ok" so the probe passes only against the deployed service.
      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # Bake this server's URL into the stub harness's drafted live-predicate.
      harness = url_stub(url)

      # The harness binary the runtime shells out to "fixes" the code by writing
      # the marker file the :tests predicate checks; the deploy stub "ships" the
      # service by flipping the live body to "ok"; a real local rebase-merge stands
      # in for `gh pr merge --rebase`.
      harness_stub = write_harness_stub(tmp_dir)
      deploy_stub = write_deploy_stub(tmp_dir, url, body_file)
      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch, request.base})
        {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      # The inbound chat message — the human's prose idea-in. The in-memory client
      # double is the egress sink the terminal ping rides back out through.
      client = InMemoryClient.start()
      message = %Message{chat_id: @chat_id, text: "ship a healthz endpoint"}

      # Drive the WHOLE bridge: ingress → approval → run → egress, all in one call,
      # every boundary a double or local stub.
      assert {:ok, %{draft: draft, result: result, sent: _sent}} =
               Telegram.handle(message,
                 client: client,
                 authoring: [harness: harness, workspace: work],
                 run: [
                   workspace: work,
                   adapter_opts: [command: harness_stub],
                   integrator: integrator,
                   deploy_cmd: deploy_stub,
                   deploy_params: %{
                     service: "kazi-telegram-e2e",
                     project: "kazi-test",
                     region: "us-central1",
                     source: work
                   },
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ]
               )

      # Ingress + approval happened: a draft was proposed and then approved, and
      # the goal ran to convergence through the full reconcile sequence.
      assert draft.idea == "ship a healthz endpoint"
      assert result.outcome == :converged
      assert result.iterations >= 1

      # The real reconcile ran on the approved goal: code dispatch → integrate →
      # deploy → converge once the live probe passed against the deployed service.
      assert_received {:integrated, _branch, "main"}
      assert File.exists?(Path.join(work, "fixed.txt"))

      # EGRESS: EXACTLY ONE outbound ping, routed back to the originating chat,
      # carrying the converged terminal status. One idea-in → one outcome-out.
      assert [{@chat_id, text, []}] = InMemoryClient.sent()
      assert length(InMemoryClient.sent()) == 1
      assert text =~ "converged"
    end

    test "an over-budget run pings the budget status back (terminal ≠ converged)",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      # A code predicate that NEVER passes (`false` always exits non-zero), with a
      # hard iteration ceiling, so the run can only terminate over-budget — a
      # terminal event that is NOT convergence. The drafted goal here needs no live
      # predicate, so the bridge proves it ferries any terminal outcome out.
      proposal =
        ~s({"name": "never converges",
            "predicates": [{"id": "code", "provider": "test_runner",
              "description": "never green",
              "config": {"cmd": "sh", "args": ["-c", "false"]}}]})

      harness = json_stub(proposal)

      client = InMemoryClient.start()
      message = %Message{chat_id: 7, text: "a goal that cannot converge"}

      assert {:ok, %{result: result}} =
               Telegram.handle(message,
                 client: client,
                 authoring: [harness: harness, workspace: work],
                 run: [
                   workspace: work,
                   adapter_opts: [command: "true"],
                   reobserve_interval_ms: 5,
                   await_timeout: 10_000,
                   # The goal carries no budget of its own; cap it here (forwarded
                   # verbatim to the loop) so the run terminates over-budget rather
                   # than spinning on the never-green predicate.
                   budget: Kazi.Budget.new(max_iterations: 1)
                 ]
               )

      assert result.outcome == :over_budget

      # Exactly one ping, naming the exceeded budget dimension — a distinct status
      # from the converged path.
      assert [{7, text, []}] = InMemoryClient.sent()
      assert length(InMemoryClient.sent()) == 1
      assert text =~ "budget"
      refute text =~ "converged"
    end

    test "an empty inbound message short-circuits before any run or ping",
         %{tmp_dir: _tmp_dir} do
      client = InMemoryClient.start()

      # A blank idea is a no-op error at ingress: nothing is proposed, no run is
      # started, and crucially NO ping is sent (the failed step halts the chain).
      assert {:error, :empty_message} =
               Telegram.handle(%Message{chat_id: 1, text: "   "},
                 client: client,
                 authoring: [harness: json_stub(@proposal)]
               )

      assert InMemoryClient.sent() == []
      assert Repo.aggregate(Kazi.ReadModel.ProposedGoal, :count) == 0
    end
  end

  # ===========================================================================
  # helpers — the same hermetic seams Kazi.RuntimeTest / Kazi.CLIAuthoringTest use
  # ===========================================================================

  # A stub harness module returning a fixed JSON proposal. Built per call so a
  # module name does not collide across tests.
  defp json_stub(json) do
    module = Module.concat(__MODULE__, :"Stub#{System.unique_integer([:positive])}")

    Module.create(
      module,
      quote do
        @behaviour Kazi.HarnessAdapter
        @impl true
        def run(_prompt, _workspace, _opts), do: {:ok, %{result: unquote(json)}}
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  # A stub harness whose drafted live predicate targets `url` (a random port).
  defp url_stub(url), do: json_stub(String.replace(@proposal, "__URL__", url))

  # A local bare "origin" with an initial commit on `main`, plus a working clone.
  defp setup_repo(tmp_dir) do
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: work, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: bare)

    %{bare: bare, work: work}
  end

  defp git_config(repo) do
    {_, 0} = System.cmd("git", ["config", "user.email", "kazi-test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "kazi test"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: repo)
  end

  # The harness binary the ClaudeAdapter shells out to: writes the marker file the
  # :tests predicate checks into the workspace, proving the run dispatched.
  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Stub emulating `gcloud run deploy`: "ship" the service by flipping the live
  # body to "ok", then print the service URL.
  defp write_deploy_stub(tmp_dir, url, body_file) do
    path = Path.join(tmp_dir, "stub_deploy_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    printf 'ok' > "#{body_file}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal local HTTP server answering GET /healthz with the served body file,
  # so the live http_probe makes a real loopback request that tracks the file.
  defp start_http_server(body) do
    docroot =
      Path.join(
        System.tmp_dir!(),
        "kazi_telegram_e2e_httpd_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-telegram-e2e-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"healthz", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/healthz", body_file}
  end

  # Stand-in for `gh pr merge --rebase`: rebase the pushed branch onto base in a
  # fresh clone of the bare origin and push the result. Returns the new base tip.
  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "telegram-e2e-merge-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", bare, tmp], stderr_to_stdout: true)
    git_config(tmp)

    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["rebase", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["merge", "--ff-only", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["push", "origin", base], cd: tmp, stderr_to_stdout: true)

    {sha, 0} = System.cmd("git", ["rev-parse", base], cd: tmp)
    File.rm_rf!(tmp)
    String.trim(sha)
  end
end
