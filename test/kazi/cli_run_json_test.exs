defmodule Kazi.CLIRunJsonTest do
  @moduledoc """
  T15.3 (ADR-0023 decision 2): the `kazi run --json` VERSIONED result contract.

  On termination `kazi run --json` emits a single JSON object carrying the
  terminal `status` (`converged` / `stuck` / `over_budget` / `error`), the
  PREDICATE VECTOR (`{id, verdict}` per predicate), `iterations`, `budget_spent`,
  a `next_action` orchestration hint, and `schema_version` — documented in
  `docs/schemas/run-result.md`.

  These are Tier-2 boundary tests: they drive the REAL CLI exec core
  (`Kazi.CLI.run/2`) against a goal-file on disk, pointing the runtime's existing
  injection seams (`:adapter_opts` harness binary, `:integrator`, `:deploy_cmd`,
  and the loop opts `:budget` / `:stuck_iterations` / `:flake_max_retries` that
  `Kazi.Runtime` forwards verbatim) at local stubs — exactly as `Kazi.CLITest`
  does. Output is captured with `ExUnit.CaptureIO`. Each terminal status yields
  the documented object; the existing human `run` output stays unchanged (it is
  exercised by `Kazi.CLITest`).

  HERMETIC: a local stub harness, a local stub deploy, a local in-process HTTP
  server, an in-process integrator — no real `claude`, `gh`, `gcloud`, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  # ===========================================================================
  # Tier 1 — `--json` argv boundary for run
  # ===========================================================================

  describe "parse/1 — run --json" do
    test "run carries --json through to its opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--json"])

      assert opts[:json] == true
    end

    test "without --json the run flag defaults to false (human is the default)" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:json] == false
    end
  end

  # ===========================================================================
  # Tier 2 — each terminal status yields the documented JSON object
  # ===========================================================================

  describe "run --json — converged" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "emits a single JSON object with the predicate vector and exits 0",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      goal_file = write_goal_file(tmp_dir, work, url)
      runtime_opts = converge_runtime_opts(tmp_dir, work, url, body_file, bare)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"], runtime_opts) ==
                   0
        end)

      # VALID JSON only — the whole stdout decodes as one object, no human prose.
      assert {:ok, payload} = Jason.decode(String.trim(out))
      refute out =~ "CONVERGED"
      refute out =~ "predicate vector:"

      assert payload["schema_version"] == 2
      assert payload["goal_id"] == "cli-e2e"
      assert payload["status"] == "converged"
      assert payload["next_action"] == "done"
      assert payload["reason"] == nil
      assert is_integer(payload["iterations"]) and payload["iterations"] > 0
      assert payload["budget_spent"]["iterations"] == payload["iterations"]
      assert payload["budget_spent"]["exceeded"] == nil

      # The predicate VECTOR: a {id, verdict} per predicate, every one passing.
      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector == %{"code" => "pass", "live" => "pass"}
    end
  end

  describe "run --json — over_budget" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a tight iteration budget yields status over_budget with the exceeded dimension",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      goal_file = write_unfixable_goal_file(tmp_dir, work)

      runtime_opts = [
        # A harness stub that never satisfies the code predicate, so the loop can
        # never converge — the budget ceiling is what stops it.
        adapter_opts: [command: write_noop_harness_stub(tmp_dir)],
        budget: Kazi.Budget.new(max_iterations: 1),
        flake_max_retries: 0,
        stuck_iterations: 0,
        reobserve_interval_ms: 5,
        await_timeout: 15_000
      ]

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"], runtime_opts) ==
                   1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["status"] == "over_budget"
      assert payload["next_action"] == "raise_budget"
      assert payload["reason"] == "max_iterations"
      assert payload["budget_spent"]["exceeded"] == "max_iterations"

      # The predicate vector is still present and names the failing predicate.
      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector["code"] == "fail"
    end
  end

  describe "run --json — stuck" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a persistently failing code predicate yields status stuck",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      goal_file = write_unfixable_goal_file(tmp_dir, work)

      runtime_opts = [
        adapter_opts: [command: write_noop_harness_stub(tmp_dir)],
        # The same non-empty failing set across 2 observations declares stuck
        # (T1.5); no flake re-runs so a single fail is taken as real.
        stuck_iterations: 2,
        flake_max_retries: 0,
        reobserve_interval_ms: 5,
        await_timeout: 15_000
      ]

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"], runtime_opts) ==
                   1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["status"] == "stuck"
      assert payload["next_action"] == "investigate"
      assert payload["reason"] == "stuck"

      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector["code"] == "fail"
    end
  end

  describe "run --json — error" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a vacuous goal yields a status error envelope on stdout (non-zero exit)",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      # The code predicate already passes at t0 (the marker exists), so the whole
      # vector is satisfied before kazi acts: the goal is vacuous (R3), a pre-loop
      # failure surfaced as status "error".
      File.write!(Path.join(work, "fixed.txt"), "already there\n")
      goal_file = write_vacuous_goal_file(tmp_dir, work)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"]) == 1
        end)

      # The error is a JSON object on STDOUT (not stderr prose), so the
      # orchestrator parses one surface and branches on the non-zero exit.
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["goal_id"] == "cli-vacuous"
      assert payload["status"] == "error"
      assert payload["next_action"] == "investigate"
      assert payload["error"] =~ "vacuous"
    end
  end

  # ===========================================================================
  # helpers (mirroring Kazi.CLITest's run-injection style)
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

  # The shipped-example shape: a test_runner code predicate the harness stub
  # satisfies + an http_probe live predicate the deploy stub flips to "ok".
  defp write_goal_file(tmp_dir, work, url) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "cli-e2e"
    name = "CLI run --json converge"

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

  # A single code predicate that NEVER passes (the marker file is never created
  # by the noop harness stub) — the loop cannot converge, so a budget/stuck stop
  # is what terminates it.
  defp write_unfixable_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "unfixable_goal.toml")

    File.write!(path, """
    id = "cli-unfixable"
    name = "CLI run --json never converges"

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

  # The converge harness stub: creates the marker file the code predicate checks.
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

  # A noop harness stub: it runs but never satisfies the code predicate, so the
  # loop keeps dispatching until the budget / stuck ceiling stops it.
  defp write_noop_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_noop_harness_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
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
      Path.join(System.tmp_dir!(), "kazi_cli_runjson_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-cli-runjson-test",
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
    tmp = Path.join(System.tmp_dir!(), "cli-runjson-merge-#{System.unique_integer([:positive])}")
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
