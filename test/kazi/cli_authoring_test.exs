defmodule Kazi.CLIAuthoringTest do
  @moduledoc """
  T3.5c (UC-017): the CLI authoring surface end-to-end.

  Tier 1 pins the argv boundary for the new authoring subcommands
  (`Kazi.CLI.parse/1`): `propose`, `list-proposed`, `approve`, `reject`.

  Tier 2 drives the full authoring path through the REAL CLI exec core
  (`Kazi.CLI.run/2`): `kazi propose "<idea>"` → `kazi list-proposed` →
  `kazi approve <proposal-ref>` → the approved goal is runnable by
  `Kazi.Runtime`, converging through the same injectable seams `Kazi.RuntimeTest`
  uses. HERMETIC: the harness that drafts the proposal is an injected stub (no
  real `claude`, no network); the runtime's edit/integrate/deploy are local stubs;
  the read-model is the test SQLite Sandbox.

  The CLI never names a concrete harness/action — the stub is threaded through the
  `inject_opts` seam (`:harness`/`:adapter_opts`), exactly as production passes
  none and the real adapter is the default.
  """
  # Real git + the shared SQLite Sandbox connection + a local HTTP probe: serial.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Goal, ReadModel, Repo, Runtime}
  alias Kazi.ReadModel.ProposedGoal

  # An injectable stub harness (the seam): returns a fixed JSON proposal in the
  # result map's `:result` field — the shape a `claude --output-format json`
  # envelope carries (T4.1). No real claude, no network. It drafts a goal of the
  # same SHAPE the runtime e2e converges: a test_runner code predicate + an
  # http_probe live predicate, whose config the local stubs satisfy.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({
           "name": "CLI authoring e2e",
           "predicates": [
             {"id": "code", "provider": "test_runner",
              "description": "the fix lands",
              "config": {"cmd": "sh", "args": ["-c", "test -f fixed.txt"]}},
             {"id": "live", "provider": "http_probe",
              "description": "the endpoint serves 200",
              "config": {"url": "__URL__", "expect_status": 200, "expect_body": "ok"}}
           ]
         })
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — argv parsing for the authoring subcommands
  # ===========================================================================

  describe "parse/1 — authoring commands" do
    test "parses `propose \"<idea>\"`" do
      assert {:propose, "a health endpoint", opts} =
               Kazi.CLI.parse(["plan", "a health endpoint"])

      assert opts[:workspace] == nil
    end

    test "propose carries --workspace" do
      assert {:propose, "an idea", opts} =
               Kazi.CLI.parse(["plan", "an idea", "--workspace", "/tmp/ws"])

      assert opts[:workspace] == "/tmp/ws"
    end

    test "a missing idea for propose is an error" do
      assert {:error, message} = Kazi.CLI.parse(["plan"])
      assert message =~ "requires an <idea>"
    end

    test "parses `list-proposed` with and without --status" do
      assert {:list_proposed, opts} = Kazi.CLI.parse(["list-proposed"])
      assert opts[:status] == nil

      assert {:list_proposed, opts} = Kazi.CLI.parse(["list-proposed", "--status", "approved"])
      assert opts[:status] == "approved"
    end

    test "parses `approve <ref>` and `reject <ref>`" do
      # T15.6 (ADR-0023): approve/reject carry an opts keyword (the --json flag).
      assert {:approve, "prop-x", approve_opts} = Kazi.CLI.parse(["approve", "prop-x"])
      assert approve_opts[:json] == false
      assert {:reject, "prop-y", reject_opts} = Kazi.CLI.parse(["reject", "prop-y"])
      assert reject_opts[:json] == false
    end

    test "approve/reject without a ref is an error" do
      assert {:error, m1} = Kazi.CLI.parse(["approve"])
      assert m1 =~ "requires a <proposal-ref>"
      assert {:error, m2} = Kazi.CLI.parse(["reject"])
      assert m2 =~ "requires a <proposal-ref>"
    end

    test "an extra positional after a single-arg command is an error" do
      assert {:error, message} = Kazi.CLI.parse(["approve", "prop-x", "junk"])
      assert message =~ "unexpected argument"
    end

    test "an unknown command names the authoring commands in its hint" do
      # T27.9 (ADR-0032): the hint points at the verb `plan`; the removed `propose`
      # alias is gone entirely.
      assert {:error, message} = Kazi.CLI.parse(["frobnicate"])
      assert message =~ "plan"
      assert message =~ "list-proposed"
    end
  end

  # ===========================================================================
  # Tier 2 — propose / list-proposed / approve through the CLI exec core
  # ===========================================================================

  describe "propose — Tier 2 (drafts + persists via the CLI)" do
    test "drafts a goal from an idea, prints the proposal-ref, persists proposed" do
      {code, out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", "ship a healthz endpoint"], harness: StubHarness)
        end)

      assert code == 0
      assert out =~ "PROPOSED"
      assert out =~ "proposal:"
      assert out =~ "code (tests)"
      assert out =~ "live (http_probe)"
      assert out =~ "kazi approve"

      # Persisted as `proposed` and queryable.
      assert [%ProposedGoal{status: "proposed"} = row] =
               ReadModel.list_proposed_goals(status: "proposed")

      assert row.idea == "ship a healthz endpoint"
    end

    test "a blank idea is refused with a clear message and exit 1" do
      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["plan", "   "], harness: StubHarness)
        end)

      assert code == 1
      assert stderr =~ "blank"
    end
  end

  # ===========================================================================
  # Tier 2 — interactive clarify phase (T11.6/T11.8, ADR-0019)
  # ===========================================================================

  # A stub that records the draft prompt and varies the live predicate by whether
  # the folded answer ("Production logs") reached it -- so a test can confirm the
  # injected answer shaped the draft. The candidate-question call returns no extra
  # questions, so the deterministic floor is what gets asked.
  defmodule ClarifyCliStub do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, _opts) do
      cond do
        prompt =~ "clarifying questions" ->
          {:ok, %{result: "[]"}}

        prompt =~ "Production logs" ->
          {:ok,
           %{
             result:
               ~s({"name":"G","predicates":[{"id":"p","provider":"prod_log","config":{}}],"rationale":"probe the runtime; tests-only is out of scope"})
           }}

        true ->
          {:ok, %{result: ~s({"name":"G","predicates":[{"id":"h","provider":"http_probe"}]})}}
      end
    end
  end

  describe "propose — interactive clarify phase (T11.6/T11.8)" do
    test "an injected :ask is invoked with the floor and folds answers into the draft" do
      test_pid = self()

      ask = fn questions ->
        send(test_pid, {:asked, Enum.map(questions, & &1.id)})
        %{"live-target" => "prod_log", "scope" => "core"}
      end

      {code, out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", "add a widgets feature"], harness: ClarifyCliStub, ask: ask)
        end)

      assert code == 0
      assert_received {:asked, ids}
      assert "live-target" in ids
      assert out =~ "PROPOSED"
      assert out =~ "prod_log"
      assert out =~ "rationale: probe the runtime"
    end

    test "--strict refuses an underspecified idea non-interactively (exit 1)" do
      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["plan", "add a widgets feature", "--strict"],
            harness: ClarifyCliStub,
            tty: false
          )
        end)

      assert code == 1
      assert stderr =~ "underspecified"
      assert stderr =~ "live-target"
    end

    test "--strict allows a fully-specified idea through" do
      idea = "GET /healthz returns 200 with no auth on https://app.example.com; scope: that only"

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", idea, "--strict"], harness: ClarifyCliStub, tty: false)
        end)

      assert code == 0
    end

    test "--adr writes an ADR-lite doc to the injected dir" do
      dir = Path.join(System.tmp_dir!(), "kazi-cli-adr-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      ask = fn _q -> %{"live-target" => "prod_log"} end

      {code, out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", "add a widgets feature", "--adr"],
            harness: ClarifyCliStub,
            ask: ask,
            adr_dir: dir
          )
        end)

      assert code == 0
      assert out =~ "ADR written:"
      assert [adr] = Path.wildcard(Path.join(dir, "*.md"))
      assert File.read!(adr) =~ "Goal proposal"
    end

    test "an injected :review that refines re-drafts and upserts the same proposal" do
      test_pid = self()
      # Refine once (with a sharper sentence), then accept.
      review = fn _draft ->
        receive_count = Process.get(:reviews, 0)
        Process.put(:reviews, receive_count + 1)

        case receive_count do
          0 -> {:refine, "GET /healthz returns 200 on https://app.example.com; scope: only that"}
          _ -> :accept
        end
      end

      ask = fn _q -> %{"live-target" => "prod_log"} end

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", "add a widgets feature"],
            harness: ClarifyCliStub,
            ask: ask,
            review: review
          )
        end)

      assert code == 0
      send(test_pid, :done)
      assert_received :done
      # Exactly one proposal row -- the refine UPSERTED rather than duplicating.
      assert [%ProposedGoal{}] = ReadModel.list_proposed_goals(status: "proposed")
    end
  end

  describe "list-proposed — Tier 2" do
    test "renders the queue and the empty state" do
      # Empty queue.
      {code, out} = with_io(fn -> Kazi.CLI.run(["list-proposed"]) end)
      assert code == 0
      assert out =~ "no"

      # After a proposal, it shows up; filtering by a foreign status hides it.
      {0, _} = with_io(fn -> Kazi.CLI.run(["plan", "a listed idea"], harness: StubHarness) end)

      {0, listed} = with_io(fn -> Kazi.CLI.run(["list-proposed", "--status", "proposed"]) end)
      assert listed =~ "a listed idea"
      assert listed =~ "proposed"

      {0, approved_only} =
        with_io(fn -> Kazi.CLI.run(["list-proposed", "--status", "approved"]) end)

      assert approved_only =~ "no"
    end
  end

  describe "approve — Tier 2 error paths" do
    test "approving an unknown ref is a clear error, exit 1" do
      {code, stderr} =
        with_io(:stderr, fn -> Kazi.CLI.run(["approve", "prop-does-not-exist"]) end)

      assert code == 1
      assert stderr =~ "could not approve"
      assert stderr =~ "no proposal carries that ref"
    end
  end

  # ===========================================================================
  # Tier 2 — the FULL e2e: idea → proposed → approved → runnable & converged
  # ===========================================================================

  describe "end-to-end: propose → list → approve → run" do
    @describetag :tmp_dir

    test "an approved goal is runnable by Kazi.Runtime and converges", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A local HTTP server the live probe really requests, starting "down" so the
      # live predicate fails pre-deploy; the deploy stub flips it to "ok".
      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # Stage the URL into the stub harness's drafted live-predicate config so the
      # approved goal's probe targets this server.
      stub = url_stub(url)

      # 1) propose — drive the CLI; the stub harness drafts the goal, persisted
      #    `proposed`. Capture the printed proposal-ref to pipe to approve.
      {0, propose_out} =
        with_io(fn ->
          Kazi.CLI.run(["plan", "ship a healthz endpoint", "--workspace", work], harness: stub)
        end)

      proposal_ref = parse_proposal_ref(propose_out)
      assert proposal_ref =~ "prop-"

      # 2) list-proposed — the proposal is in the review queue.
      {0, listed} = with_io(fn -> Kazi.CLI.run(["list-proposed"]) end)
      assert listed =~ proposal_ref

      # 3) approve — proposed → approved; the CLI prints the next step.
      {0, approve_out} = with_io(fn -> Kazi.CLI.run(["approve", proposal_ref]) end)
      assert approve_out =~ "APPROVED"
      assert approve_out =~ "kazi apply"

      assert %ProposedGoal{status: "approved"} = row = ReadModel.get_proposed_goal(proposal_ref)

      # 4) run — the approved goal rehydrates into a runnable `Kazi.Goal` (the same
      #    loader the CLI/approval use) and `Kazi.Runtime` drives it to convergence
      #    through the injectable seams. This is the "runnable goal" the task asks
      #    the e2e to prove.
      {:ok, %Goal{} = goal} = Kazi.Goal.Loader.from_map(row.goal)

      harness_stub = write_harness_stub(tmp_dir)
      deploy_stub = write_deploy_stub(tmp_dir, url, body_file)
      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch, request.base})
        {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      assert {:ok, %{outcome: :converged} = result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: %{
                   service: "kazi-authoring-e2e",
                   project: "kazi-test",
                   region: "us-central1",
                   source: work
                 },
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # The full reconcile sequence ran on the approved goal: code dispatch →
      # integrate → deploy → converge once the live probe passed.
      assert result.iterations >= 1
      assert_received {:integrated, _branch, "main"}
      assert File.exists?(Path.join(work, "fixed.txt"))
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  # A stub harness module whose drafted live predicate targets `url`. Built per
  # test so the URL (a random port) is baked into the proposal the CLI persists.
  defp url_stub(url) do
    json =
      StubHarness.run("", "", [])
      |> elem(1)
      |> Map.fetch!(:result)
      |> String.replace("__URL__", url)

    module = Module.concat(StubHarness, :"Bound#{System.unique_integer([:positive])}")

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

  # Pull the `proposal:` line's ref out of the propose command's stdout.
  defp parse_proposal_ref(out) do
    out
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "proposal:", parts: 2) do
        [_, ref] -> String.trim(ref)
        _ -> nil
      end
    end)
  end

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

  defp start_http_server(body) do
    docroot =
      Path.join(System.tmp_dir!(), "kazi_cli_auth_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-cli-authoring-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"healthz", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/healthz", body_file}
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "cli-auth-merge-#{System.unique_integer([:positive])}")
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
