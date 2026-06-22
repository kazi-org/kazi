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
      assert Enum.map(goal.predicates, & &1.id) == ["go-tests", "healthz-live"]
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
