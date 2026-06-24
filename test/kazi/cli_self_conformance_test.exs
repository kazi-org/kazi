defmodule Kazi.CLISelfConformanceTest do
  @moduledoc """
  T15.7 (ADR-0023, decision 1): kazi SELF-CONFORMS to the harness conformance
  contract it imposes on harnesses (ADR-0022).

  kazi drives a coding harness as a NON-INTERACTIVE subprocess and parses its
  stdout (ADR-0016/0022). ADR-0023 flips that requirement onto kazi itself: an
  orchestrating agent must be able to drive kazi the same way. So under `--json`
  every command must be a well-behaved subprocess a non-TTY orchestrator can
  drive — exactly the three things ADR-0022 names for a first-class harness:

    1. **non-interactive** — never prompts/blocks on stdin, even when a TTY is
       simulated (so `--json` truly overrides any terminal-attached path);
    2. **machine-parseable, JSON-ONLY stdout** — the WHOLE of stdout decodes as a
       single JSON object, with no human prose interleaved on the same stream;
    3. **stable exit codes** — `0` on success and a fixed non-zero on the
       JSON-error path, so the orchestrator branches on the code, never on prose.

  `Kazi.Harness.Conformance` (T14.1) is the conformance helper for a PROFILE's
  `build_args`/`parse` (the harness kazi drives); it does not model CLI stdout, so
  this is the dedicated test ADR-0023 anticipated — it encodes the SAME contract
  for kazi's own `--json` surface (the task's "prefer a dedicated test if the
  helper does not fit"). The contract is encoded ONCE in `assert_conformant/2`
  and exercised across every `--json` command; a regression (prose leaking into
  `--json`, or a command blocking on stdin) makes a case FAIL.

  HERMETIC: every command runs through the REAL CLI exec core (`Kazi.CLI.run/2`)
  with `ExUnit.CaptureIO`, the test SQLite Sandbox read-model, and the existing
  inject_opts seams (a stub harness, persisted proposals/iterations) — no real
  `claude`, git, or network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{PredicateResult, PredicateVector, ReadModel, Repo}

  # The injectable stub harness the authoring `--json` tests use: a fixed JSON
  # proposal in the result envelope (no real claude, no network), drafting a
  # code + live predicate so the floor is satisfied on live-target.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({
           "name": "self-conformance e2e",
           "predicates": [
             {"id": "code", "provider": "test_runner",
              "config": {"cmd": "sh", "args": ["-c", "true"]}},
             {"id": "live", "provider": "http_probe",
              "config": {"url": "http://127.0.0.1:1/healthz", "expect_status": 200}}
           ]
         })
       }}
    end
  end

  # A harness that, if ever invoked, sends its owning test process a message — so
  # a caller-drafts case can assert NO inner model was spawned (kazi stayed the
  # pure tool the contract requires).
  defmodule SpyHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      if pid = opts[:spy_pid], do: send(pid, :harness_invoked)
      {:ok, %{result: ~s({"name":"unexpected","predicates":[]})}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # The contract — encoded ONCE, applied to every `--json` command.
  # ===========================================================================
  #
  # `assert_conformant/2` is the kazi-side analogue of
  # `Kazi.Harness.Conformance.assert_profile_conformance/2`: it pins, for a single
  # `--json` invocation, the three ADR-0022 guarantees. It returns the decoded
  # payload so a case can make additional bespoke assertions.
  #
  # Options:
  #   * `:argv` (required)        — the kazi argv (must include `--json`).
  #   * `:inject` (default [])    — the inject_opts seam (stub harness, stdin, …).
  #   * `:expected_exit` (req.)   — the stable exit code this case must return.

  # Run a `--json` command and assert it is a well-behaved, drivable subprocess.
  defp assert_conformant(label, opts) do
    argv = Keyword.fetch!(opts, :argv)
    inject = Keyword.get(opts, :inject, [])
    expected_exit = Keyword.fetch!(opts, :expected_exit)

    # GUARANTEE 1 — non-interactive: a TTY is SIMULATED (`tty: true`) and NO stdin
    # is supplied, so a command that tried to prompt/read stdin would block. We run
    # the capture inside a bounded Task: a real stdin block trips the timeout and
    # FAILS the case loudly rather than hanging the suite.
    {exit_code, out} =
      drive(fn ->
        capture_with_code(fn ->
          Kazi.CLI.run(argv, Keyword.put_new(inject, :tty, true))
        end)
      end)

    trimmed = String.trim(out)

    # GUARANTEE 2 — JSON-ONLY stdout: the WHOLE of stdout decodes as a single JSON
    # OBJECT (orchestrators parse one object), and there is no human prose line on
    # the same stream. A prose leak (a `human_fun` line escaping under --json) makes
    # this fail. `decode_object!/2` raises an `ExUnit.AssertionError` (not a
    # `MatchError`) on a non-JSON / non-object stdout, so the regression guards can
    # assert it fails.
    payload = decode_object!(label, trimmed)

    refute_prose(label, trimmed)

    # GUARANTEE 3 — stable exit code: the documented code for this surface.
    assert exit_code == expected_exit,
           "#{label}: expected stable exit #{expected_exit}, got #{exit_code}"

    payload
  end

  # Assert stdout under --json is a single JSON OBJECT, raising an
  # `ExUnit.AssertionError` (so a regression guard can `assert_raise` on it).
  defp decode_object!(label, trimmed) do
    case Jason.decode(trimmed) do
      {:ok, payload} when is_map(payload) ->
        payload

      {:ok, other} ->
        flunk(
          "#{label}: stdout under --json must be a single JSON object, got: #{inspect(other)}"
        )

      {:error, _} ->
        flunk("#{label}: stdout under --json is not valid JSON:\n#{inspect(trimmed)}")
    end
  end

  # No human prose may interleave with the JSON on stdout: every non-blank line
  # must itself be valid JSON. The whole output is one object, so in practice this
  # is a single line — but a regression that printed a human banner BEFORE/AFTER
  # the JSON object (a `human_fun` line escaping under --json) would surface here
  # as a non-JSON line and fail. (Checking line-shape, not substrings, avoids
  # false positives on JSON string VALUES that legitimately contain a word like
  # "kazi".)
  defp refute_prose(label, trimmed) do
    for line <- String.split(trimmed, "\n"), String.trim(line) != "" do
      assert match?({:ok, _}, Jason.decode(line)),
             "#{label}: a non-JSON (prose) line leaked into --json stdout: #{inspect(line)}"
    end
  end

  # Run `fun` under a hard wall-clock bound. A `--json` command that blocked on
  # stdin (the failure mode the contract forbids) would never return; the timeout
  # converts that hang into an explicit test FAILURE. The CaptureIO group leader
  # is shared into the task so captured output is still collected.
  defp drive(fun) do
    parent_gl = Process.group_leader()

    task =
      Task.async(fn ->
        Process.group_leader(self(), parent_gl)
        fun.()
      end)

    case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        flunk("a --json command did not return within 10s — it blocked (likely on stdin)")
    end
  end

  # CaptureIO wrapper that also returns the command's exit code.
  defp capture_with_code(fun) do
    parent = self()
    ref = make_ref()

    out =
      capture_io(fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, code} -> {code, out}
    after
      0 -> {:no_code, out}
    end
  end

  # ===========================================================================
  # Every `--json` command is a well-behaved subprocess — SUCCESS surfaces.
  # ===========================================================================

  describe "self-conformance — JSON-only, non-interactive, stable exit (success)" do
    test "version --json" do
      payload =
        assert_conformant("version --json", argv: ["--version", "--json"], expected_exit: 0)

      assert payload["schema_version"] == 2
      assert payload["kazi"] =~ ~r/^\d+\.\d+\.\d+/
    end

    test "plan --json (kazi-drafts, headless via --yes)" do
      payload =
        assert_conformant("plan --json",
          argv: ["plan", "ship a healthz endpoint", "--json", "--yes"],
          inject: [harness: StubHarness],
          expected_exit: 0
        )

      assert payload["schema_version"] == 2
      assert payload["proposal_ref"] =~ "prop-"
    end

    test "plan --json (caller-drafts, predicates supplied, spawns NO model)" do
      predicates =
        ~s({"predicates":[{"id":"code","provider":"test_runner","config":{}}]})

      payload =
        assert_conformant("plan --json --predicates",
          argv: ["plan", "--json", "--predicates", predicates],
          inject: [harness: SpyHarness, adapter_opts: [spy_pid: self()]],
          expected_exit: 0
        )

      # kazi stayed a PURE tool: no inner model was spawned (ADR-0023 decision 4).
      refute_received :harness_invoked
      assert payload["proposal_ref"] =~ "prop-"
    end

    test "apply --json (a fixture run converges)" do
      %{work: work, goal_file: goal_file, opts: opts} = converging_run()

      payload =
        assert_conformant("apply --json",
          argv: ["apply", goal_file, "--workspace", work, "--json"],
          inject: opts,
          expected_exit: 0
        )

      assert payload["schema_version"] == 2
      assert payload["status"] == "converged"
      assert payload["next_action"] == "done"
    end

    test "run --json / propose --json (deprecated aliases still emit valid objects)" do
      # ADR-0032: the old verbs remain DEPRECATED ALIASES — they dispatch
      # identically and emit the SAME result object at the bumped schema_version,
      # so callers pinning the alias keep working through the deprecation window.
      %{work: work, goal_file: goal_file, opts: opts} = converging_run()

      run_alias =
        assert_conformant("run --json (deprecated alias)",
          argv: ["run", goal_file, "--workspace", work, "--json"],
          inject: opts,
          expected_exit: 0
        )

      assert run_alias["schema_version"] == 2
      assert run_alias["status"] == "converged"

      propose_alias =
        assert_conformant("propose --json (deprecated alias)",
          argv: ["propose", "ship a healthz endpoint", "--json", "--yes"],
          inject: [harness: StubHarness],
          expected_exit: 0
        )

      assert propose_alias["schema_version"] == 2
      assert propose_alias["proposal_ref"] =~ "prop-"
    end

    test "status --json (a persisted run)" do
      vector =
        PredicateVector.new(%{code: PredicateResult.pass(), live: PredicateResult.fail()})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "self-conf-run",
          iteration_index: 2,
          predicate_vector: vector,
          converged: false
        })

      payload =
        assert_conformant("status --json",
          argv: ["status", "self-conf-run", "--json"],
          expected_exit: 0
        )

      assert payload["kind"] == "run"
      assert payload["ref"] == "self-conf-run"
    end

    test "list-proposed --json" do
      {0, _} =
        with_io(fn -> Kazi.CLI.run(["propose", "a listed idea"], harness: StubHarness) end)

      payload =
        assert_conformant("list-proposed --json",
          argv: ["list-proposed", "--json"],
          expected_exit: 0
        )

      assert payload["count"] == 1
    end

    test "approve --json / reject --json (the authoring transitions)" do
      approve_ref = propose_one()

      approved =
        assert_conformant("approve --json",
          argv: ["approve", approve_ref, "--json"],
          expected_exit: 0
        )

      assert approved["status"] == "approved"

      reject_ref = propose_one()

      rejected =
        assert_conformant("reject --json",
          argv: ["reject", reject_ref, "--json"],
          expected_exit: 0
        )

      assert rejected["status"] == "rejected"
    end
  end

  # ===========================================================================
  # The JSON-ERROR path is ALSO conformant — same JSON-only stdout surface, a
  # STABLE non-zero exit. An orchestrator parses one stdout surface across
  # success and failure and branches on the exit code.
  # ===========================================================================

  describe "self-conformance — the JSON-error path (stable non-zero exit)" do
    test "plan --json blocks would-be interactive clarify as a JSON error (exit 1)" do
      # No injected :ask and not --yes: interactively this WOULD prompt. Under
      # --json (with a TTY simulated) it must error LOUDLY as JSON on stdout and
      # return a stable non-zero, never reading stdin.
      payload =
        assert_conformant("plan --json (interactive-block → error)",
          argv: ["plan", "add a widgets feature", "--json"],
          inject: [harness: StubHarness],
          expected_exit: 1
        )

      assert payload["error"] =~ "interactive"
      # It refused rather than guessing — nothing persisted.
      assert ReadModel.list_proposed_goals(status: "proposed") == []
    end

    test "apply --json on a vacuous goal is a JSON error envelope (exit 1)" do
      %{work: work, goal_file: goal_file} = vacuous_run()

      payload =
        assert_conformant("apply --json (vacuous → error)",
          argv: ["apply", goal_file, "--workspace", work, "--json"],
          expected_exit: 1
        )

      assert payload["status"] == "error"
      assert payload["next_action"] == "investigate"
    end

    test "status --json on an unknown ref is a JSON error (exit 1)" do
      payload =
        assert_conformant("status --json (unknown → error)",
          argv: ["status", "no-such-ref", "--json"],
          expected_exit: 1
        )

      assert payload["error"] =~ "no run or proposal found"
    end

    test "approve --json on an unknown ref is a JSON error (exit 1)" do
      payload =
        assert_conformant("approve --json (unknown → error)",
          argv: ["approve", "prop-nope", "--json"],
          expected_exit: 1
        )

      assert payload["error"] =~ "could not approve"
    end
  end

  # ===========================================================================
  # Regression guards — the contract's NEGATIVE space. These prove the
  # `assert_conformant/2` checks actually FAIL on a violation (prose leak, a
  # stdin block), so the self-conformance suite is not vacuously green.
  # ===========================================================================

  describe "the conformance check fails on a regression" do
    test "prose leaking onto --json stdout is rejected by the JSON-only check" do
      # Simulate the regression: a command that prints a human banner alongside
      # the JSON object (a prose line on the same stdout stream). `refute_prose/2`
      # must flag the non-JSON line.
      leaky = ~s({"schema_version":2}\nPROPOSED   goal=x)

      assert_raise ExUnit.AssertionError, fn ->
        refute_prose("leaky", String.trim(leaky))
      end
    end

    test "a non-object (bare prose) stdout is rejected by the JSON-only check" do
      # `Kazi.CLI.run(["--version"])` (no --json) prints `kazi <vsn>` — human prose,
      # NOT JSON. Running it through the conformance check must FAIL, proving the
      # check is load-bearing (a command that forgot to honour --json is caught).
      assert_raise ExUnit.AssertionError, fn ->
        assert_conformant("non-json version (must fail)",
          argv: ["--version"],
          expected_exit: 0
        )
      end
    end

    test "a stdin block trips the bounded driver instead of hanging" do
      # A function that never returns models a command blocking on stdin. The
      # bounded `drive/1` must convert the hang into an assertion failure.
      assert_raise ExUnit.AssertionError, fn ->
        drive(fn -> Process.sleep(:infinity) end)
      end
    end
  end

  # ===========================================================================
  # helpers — fixture runs + a persisted proposal (mirroring the T15.x tests)
  # ===========================================================================

  # A converging fixture run: a code predicate a stub harness satisfies + a live
  # http_probe a stub deploy flips to "ok", driven through the runtime's existing
  # injection seams (mirrors Kazi.CLIRunJsonTest). Uses a tmp dir under the
  # scratch space; cleaned up on_exit.
  defp converging_run do
    tmp = mktmp("self-conf-run")
    %{work: work, bare: bare} = setup_repo(tmp)

    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    goal_file = write_converge_goal_file(tmp, work, url)
    harness_stub = write_harness_stub(tmp)
    deploy_stub = write_deploy_stub(tmp, url, body_file)
    test_pid = self()

    integrator = fn request, _opts ->
      send(test_pid, {:integrated, request.branch, request.base})
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    opts = [
      adapter_opts: [command: harness_stub],
      integrator: integrator,
      deploy_cmd: deploy_stub,
      deploy_params: %{
        service: "kazi-self-conf",
        project: "kazi-test",
        region: "us-central1",
        source: work
      },
      reobserve_interval_ms: 5,
      await_timeout: 15_000
    ]

    %{work: work, goal_file: goal_file, opts: opts}
  end

  # A vacuous goal: the code predicate already passes at t0, so the whole vector
  # is satisfied before kazi acts — a pre-loop "error" surface (R3).
  defp vacuous_run do
    tmp = mktmp("self-conf-vacuous")
    %{work: work} = setup_repo(tmp)
    File.write!(Path.join(work, "fixed.txt"), "already there\n")
    goal_file = write_vacuous_goal_file(tmp, work)
    %{work: work, goal_file: goal_file}
  end

  defp propose_one do
    {0, out} = with_io(fn -> Kazi.CLI.run(["propose", "an idea"], harness: StubHarness) end)

    out
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "proposal:", parts: 2) do
        [_, ref] -> String.trim(ref)
        _ -> nil
      end
    end)
  end

  defp mktmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_converge_goal_file(tmp, work, url) do
    path = Path.join(tmp, "goal.toml")

    File.write!(path, """
    id = "self-conf-e2e"
    name = "self-conformance run --json converge"

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

  defp write_vacuous_goal_file(tmp, work) do
    path = Path.join(tmp, "vacuous_goal.toml")

    File.write!(path, """
    id = "self-conf-vacuous"
    name = "vacuous — all predicates pass at t0"

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

  defp setup_repo(tmp) do
    bare = Path.join(tmp, "origin.git")
    work = Path.join(tmp, "work")

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

  defp write_harness_stub(tmp) do
    path = Path.join(tmp, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_deploy_stub(tmp, url, body_file) do
    path = Path.join(tmp, "stub_deploy_#{System.unique_integer([:positive])}.sh")

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
      Path.join(System.tmp_dir!(), "kazi_self_conf_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-self-conf-test",
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
    tmp = Path.join(System.tmp_dir!(), "self-conf-merge-#{System.unique_integer([:positive])}")
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
