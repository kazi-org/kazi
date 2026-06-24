defmodule Kazi.CLIRunStreamTest do
  @moduledoc """
  T15.4 (ADR-0023 decision 3): `kazi run --json --stream` JSONL progress.

  A multi-iteration run with `--json --stream` emits a JSONL event STREAM — one
  JSON object per LINE per loop iteration (`event: "iteration"`, the
  predicate-vector at that observation) — TERMINATED by the final T15.3 run-result
  object. Each line parses INDEPENDENTLY, so an orchestrator monitors a long
  convergence line-by-line without blocking.

  These are Tier-2 boundary tests driving the REAL CLI exec core
  (`Kazi.CLI.run/2`) against a goal-file on disk, pointing the runtime's existing
  injection seams (`:adapter_opts` harness binary, `:integrator`, `:deploy_cmd`)
  at local stubs — exactly as `Kazi.CLIRunJsonTest` does. Output is captured with
  `ExUnit.CaptureIO`.

  HERMETIC: a local stub harness, a local stub deploy, a local in-process HTTP
  server, an in-process integrator — no real `claude`, `gh`, `gcloud`, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  # ===========================================================================
  # Tier 1 — `--stream` argv boundary for run
  # ===========================================================================

  describe "parse/1 — run --json --stream" do
    test "run carries --stream through to its opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse([
                 "run",
                 "goal.toml",
                 "--workspace",
                 "/tmp/ws",
                 "--json",
                 "--stream"
               ])

      assert opts[:json] == true
      assert opts[:stream] == true
    end

    test "without --stream the run flag defaults to false (a single result object)" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws", "--json"])

      assert opts[:stream] == false
    end
  end

  # ===========================================================================
  # Tier 2 — a multi-iteration run emits a valid JSONL stream
  # ===========================================================================

  describe "run --json --stream — converging multi-iteration run" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "emits one JSON event per iteration, terminated by the result object",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      goal_file = write_goal_file(tmp_dir, work, url)
      runtime_opts = converge_runtime_opts(tmp_dir, work, url, body_file, bare)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", work, "--json", "--stream"],
                   runtime_opts
                 ) == 0
        end)

      # Every NON-BLANK line parses INDEPENDENTLY as one JSON object (JSONL).
      lines =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          assert {:ok, obj} = Jason.decode(line)
          obj
        end)

      # A multi-iteration run: at least one iteration event before the result.
      assert length(lines) >= 2

      {events, [result]} = Enum.split(lines, -1)

      # Every leading line is an iteration event carrying the predicate vector.
      assert events != []

      Enum.each(events, fn event ->
        assert event["event"] == "iteration"
        assert event["schema_version"] == 1
        assert is_integer(event["iteration"])
        assert is_list(event["predicates"])
        assert is_boolean(event["converged"])
      end)

      # Iteration indices are monotonically non-decreasing (the loop's 0-based
      # observation counter), so the stream is ordered.
      indices = Enum.map(events, & &1["iteration"])
      assert indices == Enum.sort(indices)
      assert List.first(indices) == 0

      # The FINAL line is the T15.3 run-result object (NOT an iteration event): the
      # stream terminator the orchestrator branches on.
      refute Map.has_key?(result, "event")
      assert result["schema_version"] == 1
      assert result["goal_id"] == "cli-e2e"
      assert result["status"] == "converged"
      assert result["next_action"] == "done"

      vector = Map.new(result["predicates"], &{&1["id"], &1["verdict"]})
      assert vector == %{"code" => "pass", "live" => "pass"}
    end
  end

  describe "run --json (no --stream) — unchanged single result object" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "emits exactly one JSON object, no iteration events", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      goal_file = write_goal_file(tmp_dir, work, url)
      runtime_opts = converge_runtime_opts(tmp_dir, work, url, body_file, bare)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["run", goal_file, "--workspace", work, "--json"], runtime_opts) ==
                   0
        end)

      # The whole stdout is ONE JSON object — no per-iteration lines leak when
      # --stream is absent (the T15.3 contract is byte-for-byte unchanged).
      assert {:ok, payload} = Jason.decode(String.trim(out))
      refute payload["event"] == "iteration"
      assert payload["status"] == "converged"
      assert String.split(out, "\n", trim: true) |> length() == 1
    end
  end

  # ===========================================================================
  # helpers (mirroring Kazi.CLIRunJsonTest's run-injection style)
  # ===========================================================================

  defp converge_runtime_opts(tmp_dir, work, url, body_file, bare) do
    harness_stub = write_harness_stub(tmp_dir)
    deploy_stub = write_deploy_stub(tmp_dir, url, body_file)
    test_pid = self()

    integrator = fn request, _opts ->
      send(test_pid, {:integrated, request.branch, request.base})
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    [
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
  end

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp write_goal_file(tmp_dir, work, url) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "cli-e2e"
    name = "CLI run --json --stream converge"

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
      Path.join(
        System.tmp_dir!(),
        "kazi_cli_runstream_httpd_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-cli-runstream-test",
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
    tmp =
      Path.join(System.tmp_dir!(), "cli-runstream-merge-#{System.unique_integer([:positive])}")

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
