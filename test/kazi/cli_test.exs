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
  import ExUnit.CaptureLog

  alias Kazi.{ReadModel, Repo}

  @example_goal "priv/examples/deploy_target.toml"

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1" do
    test "parses `apply <goal-file> --workspace <path>`" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:workspace] == "/tmp/ws"
    end

    test "accepts the goal-file and workspace in either order" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "--workspace", "/tmp/ws", "goal.toml"])

      assert opts[:workspace] == "/tmp/ws"
    end

    test "workspace is optional (falls back to the goal-file scope)" do
      assert {:run, "goal.toml", opts} = Kazi.CLI.parse(["apply", "goal.toml"])
      assert opts[:workspace] == nil
    end

    test "--help (and -h) is recognized" do
      assert {:help, _} = Kazi.CLI.parse(["--help"])
      assert {:help, _} = Kazi.CLI.parse(["-h"])
      assert {:help, _} = Kazi.CLI.parse(["apply", "goal.toml", "--help"])
    end

    test "--version (and -v) is recognized" do
      assert {:version, _} = Kazi.CLI.parse(["--version"])
      assert {:version, _} = Kazi.CLI.parse(["-v"])
    end

    test "missing goal-file for apply is an error" do
      assert {:error, message} = Kazi.CLI.parse(["apply"])
      assert message =~ "requires a <goal-file>"
    end

    test "an unknown command is an error" do
      assert {:error, message} = Kazi.CLI.parse(["explode", "goal.toml"])
      assert message =~ "unknown command"
    end

    # T27.9 (ADR-0032): the removed `run`/`propose` aliases are now UNKNOWN
    # commands — a helpful error, NOT a silent dispatch.
    test "the removed `run` alias is an unknown command (T27.9)" do
      assert {:error, message} = Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws"])
      assert message =~ "unknown command"
      assert message =~ "run"
    end

    test "the removed `propose` alias is an unknown command (T27.9)" do
      assert {:error, message} = Kazi.CLI.parse(["propose", "an idea"])
      assert message =~ "unknown command"
      assert message =~ "propose"
    end

    test "no command is an error" do
      assert {:error, message} = Kazi.CLI.parse([])
      assert message =~ "no command"
    end

    test "an unknown option is an error" do
      assert {:error, message} = Kazi.CLI.parse(["apply", "goal.toml", "--bogus", "x"])
      assert message =~ "unknown option"
    end

    # T5.5: `kazi init <repo-dir>` argv boundary (stack-detection source).
    test "parses `init <repo-dir>` (stack source)" do
      assert {:init, "./repo", opts} = Kazi.CLI.parse(["init", "./repo"])
      assert opts[:enrich] == nil
    end

    test "parses `init <repo-dir> --out <file> --enrich`" do
      assert {:init, "./repo", opts} =
               Kazi.CLI.parse(["init", "./repo", "--out", "g.toml", "--enrich"])

      assert opts[:out] == "g.toml"
      assert opts[:enrich] == true
    end

    test "`init` with no repo-dir is an error" do
      assert {:error, message} = Kazi.CLI.parse(["init"])
      assert message =~ "requires a <repo-dir>"
    end
  end

  # ===========================================================================
  # Tier 1 — apply/plan are the ONLY verbs; run/propose were REMOVED (T27.9, ADR-0032)
  # ===========================================================================

  describe "parse/1 — apply/plan are the only verbs (run/propose removed)" do
    test "`apply` parses to the internal {:run, ...} tuple" do
      assert {:run, "goal.toml", apply_opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert apply_opts[:workspace] == "/tmp/ws"
      # T27.9: no `:deprecated` marker survives — the alias machinery is gone.
      refute Keyword.has_key?(apply_opts, :deprecated)
    end

    test "the removed `run`/`propose` aliases no longer parse (T27.9)" do
      assert {:error, run_msg} = Kazi.CLI.parse(["run", "goal.toml"])
      assert run_msg =~ "unknown command"

      assert {:error, propose_msg} = Kazi.CLI.parse(["propose", "an idea"])
      assert propose_msg =~ "unknown command"
    end

    test "`apply` carries the run flags through (env / standing / harness / json / parallel)" do
      assert {:run, "g.toml", opts} =
               Kazi.CLI.parse([
                 "apply",
                 "g.toml",
                 "--workspace",
                 "/w",
                 "--env",
                 "prod",
                 "--standing",
                 "--harness",
                 "opencode",
                 "--json",
                 "--parallel"
               ])

      assert opts[:env] == "prod"
      assert opts[:standing] == true
      assert opts[:harness] == "opencode"
      assert opts[:json] == true
      assert opts[:parallel] == true
    end

    test "`apply` with no goal-file is an error" do
      assert {:error, message} = Kazi.CLI.parse(["apply"])
      assert message =~ "the `apply` command requires a <goal-file>"
    end

    test "`plan \"<idea>\"` parses to the internal {:propose, ...} tuple" do
      assert {:propose, "an idea", plan_opts} =
               Kazi.CLI.parse(["plan", "an idea", "--workspace", "/w"])

      assert plan_opts[:workspace] == "/w"
      # T27.9: no `:deprecated` marker survives — the alias machinery is gone.
      refute Keyword.has_key?(plan_opts, :deprecated)
    end

    test "`plan` carries the propose flags (yes / strict / adr / predicates / json)" do
      assert {:propose, "idea", opts} =
               Kazi.CLI.parse(["plan", "idea", "--yes", "--strict", "--adr", "--json"])

      assert opts[:yes] == true
      assert opts[:strict] == true
      assert opts[:adr] == true
      assert opts[:json] == true
    end

    test "`plan --json --predicates` (caller-drafts, no idea) parses like propose" do
      preds = ~s({"predicates":[]})
      assert {:propose, "", opts} = Kazi.CLI.parse(["plan", "--json", "--predicates", preds])
      assert opts[:predicates] == preds
      assert opts[:json] == true
      refute Keyword.has_key?(opts, :deprecated)
    end

    test "a missing idea for plan is an error" do
      assert {:error, message} = Kazi.CLI.parse(["plan"])
      assert message =~ "requires an <idea>"
    end
  end

  # ===========================================================================
  # Tier 1 — run/1 usage + load-error paths
  # ===========================================================================

  describe "run/1 — help and usage" do
    test "--help prints usage and exits 0" do
      assert capture_io(fn -> assert Kazi.CLI.run(["--help"]) == 0 end) =~ "USAGE:"
    end

    test "--version prints `kazi <vsn>` and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["--version"]) == 0 end)
      assert out =~ ~r/^kazi \d+\.\d+\.\d+/
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
          assert Kazi.CLI.run(["apply", "/does/not/exist.toml", "--workspace", "/tmp"]) == 1
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
          Kazi.CLI.run(["apply", goal_file, "--workspace", work], runtime_opts)
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
  # Tier 2 — `apply` converges; the removed `run` alias errors (T27.9, ADR-0032)
  # ===========================================================================

  describe "run/2 — apply converges; the removed run alias errors as unknown" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "`apply <goal>` converges, printing no deprecation hint",
         %{tmp_dir: tmp_dir} do
      %{opts: opts, goal_file: goal_file, work: work} = converging_fixture(tmp_dir)

      # Capture stderr (outer) AND stdout+code (inner) of a SINGLE run — the
      # reconcile is not idempotent, so the fixture is exercised exactly once.
      stderr =
        capture_io(:stderr, fn ->
          {code, out} =
            with_io(fn -> Kazi.CLI.run(["apply", goal_file, "--workspace", work], opts) end)

          assert code == 0
          assert out =~ "CONVERGED"
          assert out =~ "cli-e2e"
        end)

      # No deprecation surface remains anywhere (T27.9).
      refute stderr =~ "deprecated"
    end

    test "`run <goal>` is now an UNKNOWN command (helpful error, exit 2), NOT a silent dispatch",
         %{tmp_dir: tmp_dir} do
      %{opts: opts, goal_file: goal_file, work: work} = converging_fixture(tmp_dir)

      {code, stderr} =
        with_io(:stderr, fn ->
          Kazi.CLI.run(["run", goal_file, "--workspace", work], opts)
        end)

      assert code == 2
      assert stderr =~ "unknown command"
      assert stderr =~ "run"
      # The reconcile never ran — no deprecation hint, no convergence.
      refute stderr =~ "deprecated"
    end
  end

  # ===========================================================================
  # Tier 2 — over-budget run exits cleanly, no CaseClauseError (T18.4)
  # ===========================================================================

  describe "run/2 — over-budget (max_iterations) terminal stop" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "an unconvergeable goal exits 1 and reports over-budget, never raises",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      # A code predicate that can NEVER pass (the marker file is never created) +
      # a 1-iteration budget, so the loop terminates :over_budget after one dispatch.
      goal_file = Path.join(tmp_dir, "unconvergeable.toml")

      File.write!(goal_file, """
      id = "over-budget-e2e"
      name = "never converges"

      [budget]
      max_iterations = 1

      [scope]
      workspace = "#{work}"

      [[predicate]]
      id = "code"
      provider = "test_runner"
      cmd = "sh"
      args = ["-c", "test -f never-created.txt"]
      """)

      # A no-op harness: it runs but never satisfies the predicate.
      noop_harness = Path.join(tmp_dir, "noop_harness.sh")
      File.write!(noop_harness, "#!/bin/sh\nexit 0\n")
      File.chmod!(noop_harness, 0o755)

      runtime_opts = [adapter_opts: [command: noop_harness], reobserve_interval_ms: 5]

      # Human surface: exit 1, over-budget reported, NO raise (the T18.4 regression)
      # AND no unique-constraint persistence warning (the T18.3 idempotency goal).
      log =
        capture_log(fn ->
          {c, out} =
            with_io(fn ->
              Kazi.CLI.run(["apply", goal_file, "--workspace", work], runtime_opts)
            end)

          send(self(), {:result, c, out})
        end)

      assert_received {:result, code, out}
      assert code == 1
      assert out =~ "over"
      refute log =~ "has already been taken"
      refute log =~ "failed to persist"

      # JSON surface: a parseable over_budget result object, also exit 1, no raise.
      {json_code, json_out} =
        with_io(fn ->
          Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"], runtime_opts)
        end)

      assert json_code == 1
      assert {:ok, decoded} = Jason.decode(json_out)
      assert decoded["status"] == "over_budget"
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
          Kazi.CLI.run(["apply", goal_file, "--workspace", work])
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
  # helpers
  # ===========================================================================

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

  # The converging end-to-end fixture (T27.1 apply/run equivalence): a real bare
  # origin + clone, a local HTTP probe that starts "down" and is flipped "ok" by a
  # deploy stub, a harness stub that creates the marker file, and an integrator
  # that locally rebase-merges. Returns the runtime `:opts`, the goal-file, and the
  # workspace — the SAME wiring the `run` converge test uses, so `apply` and `run`
  # exercise an identical reconcile path.
  defp converging_fixture(tmp_dir) do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    goal_file = write_goal_file(tmp_dir, work, url)
    harness_stub = write_harness_stub(tmp_dir)
    deploy_stub = write_deploy_stub(tmp_dir, url, body_file)

    integrator = fn request, _opts ->
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    opts = [
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

    %{opts: opts, goal_file: goal_file, work: work}
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
