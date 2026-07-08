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
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
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

      # ADR-0046 back-compat: `budget_spent.tokens` is always present as the single
      # rolled-up total — an orchestrator pinning the pre-envelope contract keeps
      # reading it. This stub harness reports no usage, so the total is 0…
      assert payload["budget_spent"]["tokens"] == 0
      # …and the additive `usage` envelope is OMITTED entirely (absent ≠ zero):
      # a no-usage run is byte-identical to the pre-envelope contract.
      refute Map.has_key?(payload, "usage")

      # The predicate VECTOR: a {id, verdict} per predicate, every one passing.
      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector == %{"code" => "pass", "live" => "pass"}

      # T34.6 (ADR-0046 §5): the additive `economy` object is present on a recorded
      # run. status/stuck/iterations are always present; the converged-predicate
      # count is the KPI denominator. This stub harness reports NO cost, so the
      # cost-per-converged-predicate KPI is OMITTED (unavailable ≠ 0).
      economy = payload["economy"]
      assert is_map(economy)
      assert economy["status"] == "converged"
      assert economy["stuck"] == false
      assert economy["converged_predicates"] == 2
      assert is_integer(economy["iterations"]) and economy["iterations"] > 0
      refute Map.has_key?(economy, "cost_per_converged_predicate")
    end

    test "a harness reporting usage emits the additive usage envelope, omitting unreported fields",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      {server, url, body_file} = start_http_server("down")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      goal_file = write_goal_file(tmp_dir, work, url)

      # A converge harness that ALSO emits a Claude JSON envelope with a usage
      # object + total_cost_usd, so the loop accumulates real usage.
      runtime_opts =
        converge_runtime_opts(
          tmp_dir,
          work,
          url,
          body_file,
          bare,
          write_json_harness_stub(tmp_dir)
        )

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
                   0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["status"] == "converged"

      # Back-compat: the rolled-up token total is the summed Claude usage
      # (100 + 250 + 0 + 5000 = 5350 per dispatch), surfaced in budget_spent.tokens.
      assert payload["budget_spent"]["tokens"] > 0

      # The additive envelope is PRESENT and carries the reported cost…
      usage = payload["usage"]
      assert is_map(usage)
      assert usage["cost_usd"] > 0

      # T34.2: …and the cached-vs-fresh TOKEN split is now mapped from the Claude
      # usage object — fresh input, generated output, and the cache-read class the
      # economy program centers on are all present and positive.
      assert usage["input_tokens"] > 0
      assert usage["output_tokens"] > 0
      assert usage["cached_input_tokens"] > 0
      # cache_creation was reported as 0 — a reported 0 is kept (it WAS measured),
      # distinct from an unreported field.
      assert usage["cache_write_tokens"] == 0

      # The split is consistent with the back-compat rollup: the four token fields
      # sum to budget_spent.tokens (same per-dispatch source, un-summed here).
      assert usage["input_tokens"] + usage["output_tokens"] + usage["cache_write_tokens"] +
               usage["cached_input_tokens"] == payload["budget_spent"]["tokens"]

      # …while components the harness did not report as a distinct envelope field
      # are OMITTED (absent ≠ zero), not zero-filled.
      refute Map.has_key?(usage, "reasoning_tokens")

      # T34.6 (ADR-0046 §5): with a reported cost the `economy` object now carries
      # the cost-per-converged-predicate KPI, derived from the run-aggregate cost
      # and the 2 converged predicates.
      economy = payload["economy"]
      assert economy["status"] == "converged"
      assert economy["converged_predicates"] == 2
      assert economy["cost_usd"] > 0
      assert economy["cost_per_converged_predicate"] == economy["cost_usd"] / 2

      # T34.8: the economy object also carries a NON-ZERO run-aggregate token total
      # (no longer "tokens: 0") and the harness-reported cost — so a benchmark reads
      # real $/tokens straight from kazi's economy, no capture shim needed. The
      # token total matches the back-compat rollup; the cost matches the `usage`
      # figure (Claude's authoritative total_cost_usd).
      assert economy["tokens"] == payload["budget_spent"]["tokens"]
      assert economy["tokens"] > 0
      assert economy["cost_usd"] == usage["cost_usd"]
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
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
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

      # T48.4 (ADR-0058 decision 4): a REAL failing predicate is still :fail at
      # the terminal re-observation -- honestly budget_exhausted, not a
      # mislabeled config wedge.
      assert payload["cause"]["class"] == "budget_exhausted"
      assert payload["cause"]["ids"] == ["code"]
      assert payload["cause"]["exhausted"] == "max_iterations"
    end

    test "a max_tokens ceiling that never binds (no usage reported) flags usage_fidelity",
         %{tmp_dir: tmp_dir} do
      # T48.5 (ADR-0058 §4): the same noop stub the converged-suite test above
      # proves reports NO usage at all — with a max_tokens ceiling ALSO set, the
      # loop's token total can never grow, so the ceiling can never bind. The
      # iteration ceiling is what actually stops the run; `usage_fidelity`
      # names WHY the token ceiling was never enforced.
      %{work: work} = setup_repo(tmp_dir)

      goal_file = write_unfixable_goal_file(tmp_dir, work)

      runtime_opts = [
        adapter_opts: [command: write_noop_harness_stub(tmp_dir)],
        budget: Kazi.Budget.new(max_iterations: 1, max_tokens: 100),
        flake_max_retries: 0,
        stuck_iterations: 0,
        reobserve_interval_ms: 5,
        await_timeout: 15_000
      ]

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
                   1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "over_budget"
      # The ITERATION dimension tripped first, not tokens — direct proof the
      # token ceiling never bound.
      assert payload["reason"] == "max_iterations"
      assert payload["usage_fidelity"] == "unreported"
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
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
                   1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["status"] == "stuck"
      assert payload["next_action"] == "investigate"
      assert payload["reason"] == "stuck"

      vector = Map.new(payload["predicates"], &{&1["id"], &1["verdict"]})
      assert vector["code"] == "fail"

      # T48.4 (ADR-0058 decision 4): an ordinary failing-set stuck stop is
      # exactly what it says it is -- no cause class, key absent entirely.
      refute Map.has_key?(payload, "cause")
    end

    # T48.1 (ADR-0058) made the url-less live wedge STRUCTURALLY IMPOSSIBLE from
    # a goal-file: the loader rejects it before a loop ever starts, so `kazi
    # apply` can no longer reach the `error_wedged` stop this way -- the JSON
    # error envelope naming the predicate and the missing key IS the honest
    # outcome now. (The `error_wedged` cause itself stays pinned at loop/runtime
    # level in permanent_live_error_stuck_test.exs, where the goal is built
    # programmatically, and the CLI's present-`cause` rendering is pinned by the
    # budget_exhausted case above.)
    test "a url-less live predicate is rejected at goal-load with a JSON error, not run to a wedge (T48.1/T48.4, ADR-0058)",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      goal_file = write_live_wedge_goal_file(tmp_dir, work)

      runtime_opts =
        converge_runtime_opts(
          tmp_dir,
          work,
          "http://unused.invalid/healthz",
          Path.join(tmp_dir, "unused_body"),
          bare
        )
        |> Keyword.merge(stuck_iterations: 3, flake_max_retries: 0)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--allow-primary-workspace",
                     "--json"
                   ],
                   runtime_opts
                 ) ==
                   1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "could not load goal-file"
      assert payload["error"] =~ "live_route"
      assert payload["error"] =~ "url"
      refute Map.has_key?(payload, "status")
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
          assert Kazi.CLI.run([
                   "apply",
                   goal_file,
                   "--workspace",
                   work,
                   "--allow-primary-workspace",
                   "--json"
                 ]) == 1
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

  defp converge_runtime_opts(tmp_dir, work, url, body_file, bare, harness_stub \\ nil) do
    harness_stub = harness_stub || write_harness_stub(tmp_dir)
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

  # A code predicate the harness stub satisfies immediately (so the loop
  # reaches "landed + deployed, only the live predicate unsatisfied") plus a
  # live `http_probe` predicate with NO `url` configured -- the real
  # `Kazi.Providers.HttpProbe` errors `:missing_url` on EVERY observation
  # (T48.3, ADR-0058), the residual config-error wedge T48.4's cause class
  # names.
  defp write_live_wedge_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "live_wedge_goal.toml")

    File.write!(path, """
    id = "cli-live-wedge"
    name = "CLI run --json live permanent-error wedge"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]

    [[predicate]]
    id = "live_route"
    provider = "http_probe"
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
  # A converge harness that satisfies the code predicate (writes fixed.txt) AND
  # emits a Claude JSON result envelope on stdout — a `usage` object the profile
  # sums into the token total, plus a `total_cost_usd` the loop surfaces as the
  # additive `usage.cost_usd`. Used to exercise a POPULATED usage envelope
  # end-to-end (T34.1, ADR-0046).
  defp write_json_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_json_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    cat <<'JSON'
    {"type":"result","subtype":"success","is_error":false,"result":"Made the failing test pass.","total_cost_usd":0.0123,"usage":{"input_tokens":100,"output_tokens":250,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000}}
    JSON
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

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
