defmodule Kazi.CLITest do
  @moduledoc """
  Tier 1 + Tier 2 for the `kazi` CLI entry (T0.10, UC-004).

  Tier 1 (`Kazi.CLI.parse/1`) pins the argv boundary: the `run` subcommand, the
  positional goal-file, `--workspace`, and `--help`.

  Tier 2 drives `Kazi.CLI.run/2` end-to-end through the REAL path — loader →
  `Kazi.Runtime` → loop → providers/harness/actions → the test SQLite read-model
  — against a goal-file on disk pointed at a TEMP target workspace (a real git
  repo). It substitutes nothing in `lib/`; it only points the runtime's existing
  injectable seams at local stubs (the harness binary via `:adapter_opts`, the
  integrate `:integrator`, the deploy `:deploy_cmd`), exactly as
  `Kazi.RuntimeTest` does. It asserts argv parsing, the goal-load error path (bad
  file → non-zero), that the shipped EXAMPLE goal-file loads, and a successful
  converge path that prints the outcome + exits 0 — capturing stdout for
  assertions.

  The shipped example goal-file (`priv/examples/deploy_target.toml`) declares a
  `go test ./...` code predicate and an http_probe live predicate whose URL is
  supplied by the (not-yet-provisioned) deploy target (T0.6h); it therefore can't
  converge hermetically without Go + Cloud Run. The converge test instead writes
  a goal-file of the SAME shape (a `test_runner` code predicate + an `http_probe`
  live predicate) whose config the local stubs satisfy, so the assertion exercises
  the genuine CLI → runtime → converge path.
  """
  # Real git + real HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{ReadModel, Repo}

  @example_goal "priv/examples/deploy_target.toml"

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1" do
    test "parses `run <goal-file> --workspace <path>`" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:workspace] == "/tmp/ws"
    end

    test "accepts the goal-file and workspace in either order" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "--workspace", "/tmp/ws", "goal.toml"])

      assert opts[:workspace] == "/tmp/ws"
    end

    test "workspace is optional (falls back to the goal-file scope)" do
      assert {:run, "goal.toml", opts} = Kazi.CLI.parse(["run", "goal.toml"])
      assert opts[:workspace] == nil
    end

    test "--help (and -h) is recognized" do
      assert {:help, _} = Kazi.CLI.parse(["--help"])
      assert {:help, _} = Kazi.CLI.parse(["-h"])
      assert {:help, _} = Kazi.CLI.parse(["run", "goal.toml", "--help"])
    end

    test "missing goal-file for run is an error" do
      assert {:error, message} = Kazi.CLI.parse(["run"])
      assert message =~ "requires a <goal-file>"
    end

    test "an unknown command is an error" do
      assert {:error, message} = Kazi.CLI.parse(["explode", "goal.toml"])
      assert message =~ "unknown command"
    end

    test "no command is an error" do
      assert {:error, message} = Kazi.CLI.parse([])
      assert message =~ "no command"
    end

    test "an unknown option is an error" do
      assert {:error, message} = Kazi.CLI.parse(["run", "goal.toml", "--bogus", "x"])
      assert message =~ "unknown option"
    end

    # T5.5 / T7.3: `kazi init` argv boundary (stack vs registry source).
    test "parses `init <repo-dir>` (stack source)" do
      assert {:init, "./repo", opts} = Kazi.CLI.parse(["init", "./repo"])
      assert opts[:registry] == nil
      assert opts[:enrich] == nil
    end

    test "parses `init <repo-dir> --out <file> --enrich`" do
      assert {:init, "./repo", opts} =
               Kazi.CLI.parse(["init", "./repo", "--out", "g.toml", "--enrich"])

      assert opts[:out] == "g.toml"
      assert opts[:enrich] == true
    end

    test "parses `init --registry <file.json>` (registry source, no positional)" do
      assert {:init, nil, opts} = Kazi.CLI.parse(["init", "--registry", "caps.json"])
      assert opts[:registry] == "caps.json"
    end

    test "`init --registry` with a stray positional repo-dir is an error" do
      assert {:error, message} = Kazi.CLI.parse(["init", "--registry", "caps.json", "./repo"])
      assert message =~ "no positional repo-dir"
    end

    test "`init` with neither a repo-dir nor --registry is an error" do
      assert {:error, message} = Kazi.CLI.parse(["init"])
      assert message =~ "requires a <repo-dir>" or message =~ "--registry"
    end
  end

  # ===========================================================================
  # Tier 1 — run/1 usage + load-error paths
  # ===========================================================================

  describe "run/1 — help and usage" do
    test "--help prints usage and exits 0" do
      assert capture_io(fn -> assert Kazi.CLI.run(["--help"]) == 0 end) =~ "USAGE:"
    end

    test "a usage error prints to stderr and exits 2" do
      stderr =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["nonsense"]) == 2
        end)

      assert stderr =~ "unknown command"
    end
  end

  describe "run/1 — goal-load error" do
    setup :checkout_sandbox

    test "a missing goal-file prints a clear message and exits non-zero" do
      stderr =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["run", "/does/not/exist.toml", "--workspace", "/tmp"]) == 1
        end)

      assert stderr =~ "could not load goal-file"
      assert stderr =~ "/does/not/exist.toml"
    end
  end

  # ===========================================================================
  # Tier 1 — the shipped example goal-file loads through the CLI's loader path
  # ===========================================================================

  describe "the shipped example goal-file" do
    setup :checkout_sandbox

    test "loads cleanly via Kazi.Goal.Loader (the path the CLI uses)" do
      assert {:ok, goal} = Kazi.Goal.Loader.load(@example_goal)
      assert goal.id == "deploy-target-slice0"
      assert Enum.map(goal.predicates, & &1.id) == ["go-tests", "livez-live"]
    end
  end

  # ===========================================================================
  # Tier 2 — end-to-end converge through the CLI
  # ===========================================================================

  describe "run/2 — end-to-end converge" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "loads a goal-file, converges via real wiring, prints outcome, exits 0",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A local HTTP server the live probe really requests. Starts "down" so the
      # live predicate fails pre-deploy (forcing the full reconcile sequence); the
      # deploy stub flips it to "ok" so the probe passes only post-deploy.
      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # A goal-file on disk, same SHAPE as the shipped example (a test_runner code
      # predicate + an http_probe live predicate), with config the local stubs
      # satisfy. Loaded by the real CLI loader path.
      goal_file = write_goal_file(tmp_dir, work, url)

      # Stubs pointed at the runtime's existing seams.
      harness_stub = write_harness_stub(tmp_dir)
      deploy_stub = write_deploy_stub(tmp_dir, url, body_file)

      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch, request.base})
        {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      runtime_opts = [
        adapter_opts: [command: harness_stub],
        integrator: integrator,
        deploy_cmd: deploy_stub,
        deploy_params: %{
          service: "kazi-cli-e2e",
          project: "kazi-test",
          region: "us-central1",
          source: work
        },
        reobserve_interval_ms: 5,
        await_timeout: 15_000
      ]

      {code, out} =
        with_io(fn ->
          Kazi.CLI.run(["run", goal_file, "--workspace", work], runtime_opts)
        end)

      assert code == 0
      assert out =~ "CONVERGED"
      assert out =~ "cli-e2e"
      assert out =~ "predicate vector:"
      assert out =~ "code"
      assert out =~ "live"
      assert out =~ "iterations:"

      # The real reconcile sequence ran through the CLI: code dispatch → integrate
      # → deploy → converge once the live probe passed.
      assert_received {:integrated, _branch, "main"}
      assert File.exists?(Path.join(work, "fixed.txt"))

      # Persistence: the default path projected every iteration to the read-model.
      iterations = ReadModel.list_iterations("cli-e2e")
      assert iterations != []
      assert List.last(iterations).converged == true
    end
  end

  # ===========================================================================
  # Tier 2 — vacuous goal rejected through the CLI (T2.3, R3)
  # ===========================================================================

  describe "run/2 — vacuous goal" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a goal whose predicates all pass at t0 exits non-zero with a clear message",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      # The code predicate already passes at t0 (the marker file exists), so the
      # whole vector is satisfied before kazi does anything: the goal is vacuous.
      File.write!(Path.join(work, "fixed.txt"), "already there\n")
      goal_file = write_vacuous_goal_file(tmp_dir, work)

      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["run", goal_file, "--workspace", work])
        end)

      # Non-zero exit + a clear vacuous-goal message; the loop never started.
      assert code == 1
      assert stderr =~ "vacuous"
      assert stderr =~ "at t0"
      assert ReadModel.list_iterations("cli-vacuous") == []
    end
  end

  # ===========================================================================
  # Tier 2 — `kazi init` stack source (T5.5) writes one goal-file
  # ===========================================================================

  describe "run/2 — init stack source" do
    @describetag :tmp_dir

    test "detects the stack and writes a loadable goal-file with a live TODO scaffold",
         %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "go-repo")
      File.mkdir_p!(repo)
      File.write!(Path.join(repo, "go.mod"), "module example.com/app\n")
      out = Path.join(tmp_dir, "go.goal.toml")

      {code, output} =
        with_io(fn -> Kazi.CLI.run(["init", repo, "--out", out]) end)

      assert code == 0
      assert output =~ "WROTE  #{out}"
      assert output =~ "Review the live-predicate TODO"

      # The written goal-file loads and names the detected go test command.
      assert {:ok, goal} = Kazi.Goal.Loader.load(out)
      acceptance = Enum.find(goal.predicates, &(&1.id == "tests-pass"))
      assert acceptance.config[:cmd] == "go"
      assert acceptance.config[:args] == ["test", "./..."]

      # The commented live-predicate scaffold is present (but does not parse).
      toml = File.read!(out)
      assert toml =~ "# [[predicate]]"
      assert toml =~ ~s(# provider = "http_probe")
    end

    test "a repo with no recognised stack exits non-zero with a clear message",
         %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "empty-repo")
      File.mkdir_p!(repo)
      File.write!(Path.join(repo, "README.txt"), "hi\n")

      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["init", repo, "--out", Path.join(tmp_dir, "x.toml")])
        end)

      assert code == 1
      assert stderr =~ "could not detect a stack"
    end
  end

  # ===========================================================================
  # Tier 2 — `kazi init --registry` writes a goal SET (T7.3, ADR-0015)
  # ===========================================================================

  # A STUB harness for --enrich, driven through the same seam everything else
  # uses. With enrichment OFF it is never called; ON it fills a gap with a live
  # acceptance predicate. No real `claude`, no network.
  defmodule InitStubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({"predicates":[{"id":"probe","provider":"http_probe","url":"http://x/ok"}]})
       }}
    end
  end

  describe "run/2 — init registry source" do
    @describetag :tmp_dir

    test "writes one goal-file per capability under --out/<scope>/<id>.toml, all loadable",
         %{tmp_dir: tmp_dir} do
      registry = write_registry(tmp_dir)
      out = Path.join(tmp_dir, "kazi-goals")

      {code, output} =
        with_io(fn -> Kazi.CLI.run(["init", "--registry", registry, "--out", out]) end)

      assert code == 0
      assert output =~ "Wrote 3 goal-file(s)"

      auth = Path.join([out, "auth", "auth.password-reset.toml"])
      billing = Path.join([out, "billing", "billing.invoice-pdf.toml"])
      gap = Path.join([out, "search.autocomplete.toml"])

      assert File.exists?(auth)
      assert File.exists?(billing)
      # The gap capability has no scope, so it lands at the top of --out.
      assert File.exists?(gap)

      # Every generated goal-file loads via the loader.
      for path <- [auth, billing, gap] do
        assert {:ok, _goal} = Kazi.Goal.Loader.load(path)
        assert File.read!(path) =~ "# [[predicate]]"
      end

      # The declared binding names the real test command.
      {:ok, auth_goal} = Kazi.Goal.Loader.load(auth)
      [pred] = auth_goal.predicates ++ auth_goal.guards
      assert pred.config[:cmd] == "go"
    end

    test "a prose .md registry path is rejected with a clear message", %{tmp_dir: tmp_dir} do
      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["init", "--registry", Path.join(tmp_dir, "capabilities.md")])
        end)

      assert code == 1
      assert stderr =~ "could not adopt registry"
      assert stderr =~ "GENERATED VIEW" or stderr =~ "generated view"
    end

    test "--enrich is OFF by default: the gap capability stays a gap-marker",
         %{tmp_dir: tmp_dir} do
      registry = write_registry(tmp_dir)
      out = Path.join(tmp_dir, "no-enrich-goals")

      # Pass a stub harness via inject_opts but NO --enrich: it must not be driven.
      {code, _output} =
        with_io(fn ->
          Kazi.CLI.run(["init", "--registry", registry, "--out", out], harness: InitStubHarness)
        end)

      assert code == 0
      gap = Path.join([out, "search.autocomplete.toml"])
      {:ok, goal} = Kazi.Goal.Loader.load(gap)
      # Gap-marker guard with the no-op `true` command (not enriched).
      assert [marker] = goal.guards
      assert marker.id == "acceptance-gap"
    end

    test "--enrich ON fills the gap via the injected stub harness", %{tmp_dir: tmp_dir} do
      registry = write_registry(tmp_dir)
      out = Path.join(tmp_dir, "enriched-goals")

      {code, _output} =
        with_io(fn ->
          Kazi.CLI.run(
            ["init", "--registry", registry, "--out", out, "--enrich"],
            harness: InitStubHarness
          )
        end)

      assert code == 0
      gap = Path.join([out, "search.autocomplete.toml"])
      {:ok, goal} = Kazi.Goal.Loader.load(gap)
      # The gap is now an http_probe acceptance predicate (harness-proposed).
      assert [filled] = goal.predicates
      assert filled.kind == :http_probe
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  # A small capability registry on disk for the init-registry tests: one declared
  # binding (scoped auth), one multi-binding (scoped billing), one gap (no scope).
  defp write_registry(tmp_dir) do
    path = Path.join(tmp_dir, "capabilities.json")

    File.write!(path, """
    {
      "version": 1,
      "capabilities": [
        {
          "id": "auth.password-reset",
          "name": "User can reset their password",
          "test": {"cmd": "go", "args": ["test", "./auth/...", "-run", "TestPasswordReset"]},
          "scope": "auth"
        },
        {
          "id": "billing.invoice-pdf",
          "name": "Customer can download an invoice PDF",
          "tests": [
            {"cmd": "go", "args": ["test", "./billing/..."]},
            {"cmd": "npm", "args": ["run", "test:e2e:invoice"]}
          ],
          "scope": "billing"
        },
        {
          "id": "search.autocomplete",
          "name": "Search box suggests results as the user types"
        }
      ]
    }
    """)

    path
  end

  # A goal-file with a single code predicate that passes at t0 (the marker file
  # already exists) — the whole vector is satisfied before kazi acts, so the goal
  # is vacuous (T2.3). No live predicate: the t0 vector is fully green.
  defp write_vacuous_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "vacuous_goal.toml")

    File.write!(path, """
    id = "cli-vacuous"
    name = "Vacuous goal — all predicates pass at t0"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # A goal-file of the same shape as the shipped example, but stub-satisfiable:
  # the code predicate is a marker-file check the harness stub creates, and the
  # live probe targets the local HTTP server.
  defp write_goal_file(tmp_dir, work, url) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "cli-e2e"
    name = "CLI end-to-end converge"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]

    [[predicate]]
    id = "live"
    provider = "http_probe"
    url = "#{url}"
    expect_status = 200
    expect_body = "ok"
    """)

    path
  end

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
    docroot = Path.join(System.tmp_dir!(), "kazi_cli_httpd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-cli-test",
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
    tmp = Path.join(System.tmp_dir!(), "cli-merge-#{System.unique_integer([:positive])}")
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
