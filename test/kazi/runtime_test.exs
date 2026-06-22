defmodule Kazi.RuntimeTest do
  @moduledoc """
  Tier 2 — the end-to-end assembly test for `Kazi.Runtime` (T0.7b, UC-004).

  This drives the REAL component wiring — the real `TestRunner` and `HttpProbe`
  providers, the real `ClaudeAdapter` harness, the real `Integrate` and `Deploy`
  actions, and real SQLite persistence — against a TEMP target. It substitutes
  nothing in `lib/`; it only points the seams those modules already expose at
  local stubs:

    * the harness binary (`adapter_opts: [command: stub]`) — a real script that
      "fixes" the code by writing the marker file the test predicate checks;
    * the integrate action's `:integrator` seam — a real local rebase-merge into
      a bare origin (stands in for `gh pr merge --rebase`);
    * the deploy action's `:deploy_cmd` seam — a stub emulating `gcloud run
      deploy` that prints the live URL.

  The live `http_probe` predicate makes a REAL HTTP request against a local
  server, so the loop observes a genuine predicate vector, dispatches the
  harness, integrates, deploys, and converges only once the whole vector
  (including the live probe) is satisfied — and every iteration is projected to
  the test SQLite read-model.
  """
  # Real git + real HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}

  @moduletag :tmp_dir

  setup do
    # The runtime's persistence seam writes through Kazi.ReadModel on the loop's
    # process. Share this checked-out Sandbox connection with any process so the
    # loop's writes land in the same transaction the test reads from.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "drives a goal end-to-end through real components to convergence + persists every iteration",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # A local HTTP server the live probe really requests. It serves a body file
    # that starts as "down" so the live predicate FAILS before deploy — forcing
    # the loop through the full reconcile sequence — and the deploy stub flips it
    # to "ok" so the probe passes only against the "deployed" service.
    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    # The harness stub "fixes" the code: it writes the marker file the test
    # predicate checks, so the :tests predicate goes red → green across dispatch.
    harness_stub = write_harness_stub(tmp_dir, work)

    # The deploy stub stands in for `gcloud run deploy`: it "ships" the service
    # (flips the live body to "ok") and prints the service URL.
    deploy_stub = write_deploy_stub(tmp_dir, url, body_file)

    # A real local rebase-merge integrator (stands in for `gh pr merge --rebase`).
    test_pid = self()

    integrator = fn request, _opts ->
      send(test_pid, {:integrated, request.branch, request.base})
      merge_commit = local_rebase_merge(bare, request.branch, request.base)
      {:ok, %{pr: 7, merge_commit: merge_commit}}
    end

    goal =
      Goal.new("runtime-e2e",
        predicates: [
          # Real test-runner: passes once `fixed.txt` exists in the workspace.
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]}),
          # Real live probe against the running server (deploy-gated by kind).
          Predicate.new(:live, :http_probe,
            config: %{url: url, expect_status: 200, expect_body: "ok"}
          )
        ],
        scope: Scope.new(workspace: work)
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               adapter_opts: [command: harness_stub],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               deploy_params: %{
                 service: "kazi-e2e",
                 project: "kazi-test",
                 region: "us-central1",
                 source: work
               },
               # Poll the live predicate fast so the test doesn't wait on the
               # production default interval.
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    # Converged via the real reconcile sequence: dispatch (code red) → integrate
    # (code green, not landed) → deploy (landed) → converge once the live probe
    # passes against the deployed service.
    assert result.outcome == :converged
    assert result.actions == [:dispatch_agent, :integrate, :deploy]

    # The integrate action's real local git path ran (branch landed on origin).
    assert_received {:integrated, branch, "main"}
    assert is_binary(branch)
    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
    assert tree =~ "fixed.txt"

    # The harness really ran in the workspace and created the marker file.
    assert File.exists?(Path.join(work, "fixed.txt"))

    # Persistence: every observed iteration was projected to the read-model, the
    # vector round-trips, and the terminal iteration is marked converged.
    iterations = ReadModel.list_iterations("runtime-e2e")
    assert length(iterations) == result.iterations
    assert Enum.map(iterations, & &1.iteration_index) == Enum.to_list(0..(result.iterations - 1))

    last = List.last(iterations)
    assert last.converged == true
    refute Enum.any?(Enum.drop(iterations, -1), & &1.converged)

    # The persisted final vector is the satisfied one the loop converged on.
    final_vector = ReadModel.to_predicate_vector(last)
    assert PredicateVector.satisfied?(final_vector)
    assert PredicateVector.get(final_vector, "code").status == :pass
    assert PredicateVector.get(final_vector, "live").status == :pass
  end

  test "fails loudly when a predicate names a provider the runtime can't dispatch" do
    goal =
      Goal.new("unknown-kind",
        predicates: [Predicate.new(:p, :no_such_kind)]
      )

    assert {:error, {:unknown_provider_kinds, [:no_such_kind]}} =
             Runtime.run(goal, persist?: false)
  end

  test "runs without touching the read-model when persistence is disabled", %{tmp_dir: tmp_dir} do
    %{work: work} = setup_repo(tmp_dir)
    File.write!(Path.join(work, "fixed.txt"), "already-fixed\n")
    # The live probe starts "down" so the goal is NOT vacuous at t0 (its live
    # predicate fails before deploy, T2.3); the deploy stub flips it to "ok".
    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    deploy_stub = write_deploy_stub(tmp_dir, url, body_file)

    integrator = fn request, _opts ->
      {:ok, %{pr: 1, merge_commit: local_rebase_merge_origin(work, request.branch, request.base)}}
    end

    goal =
      Goal.new("no-persist",
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]}),
          Predicate.new(:live, :http_probe,
            config: %{url: url, expect_status: 200, expect_body: "ok"}
          )
        ],
        scope: Scope.new(workspace: work)
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               persist?: false,
               adapter_opts: [command: "true"],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               deploy_params: %{
                 service: "s",
                 project: "p",
                 region: "r",
                 source: work
               },
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    assert result.outcome == :converged
    assert ReadModel.list_iterations("no-persist") == []
  end

  test "a hard budget ceiling stops the loop over-budget and persists the stop reason (T1.4)",
       %{tmp_dir: tmp_dir} do
    %{work: work} = setup_repo(tmp_dir)

    # A code predicate that NEVER passes (`false` always exits non-zero) so the
    # loop can only terminate by hitting the budget — not by converging. The
    # harness stub does nothing useful (the predicate stays red).
    goal =
      Goal.new("over-budget",
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "false"]})
        ],
        budget: [max_iterations: 2],
        scope: Scope.new(workspace: work)
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               adapter_opts: [command: "true"],
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    # The loop stopped on the hard budget ceiling, not on convergence.
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations
    assert result.iterations == 2

    # The stop is visible in the persisted iteration log: a budget_stop row
    # naming the exceeded dimension, beyond the last observed iteration index.
    iterations = ReadModel.list_iterations("over-budget")
    budget_stop = Enum.find(iterations, &(&1.action_kind == "budget_stop"))

    assert budget_stop, "expected a persisted budget_stop iteration in the read-model"
    # action_params round-trips through a JSON map column, so the reason atom is
    # read back as its string form.
    assert to_string(budget_stop.action_params["reason"]) == "max_iterations"
    refute budget_stop.converged
  end

  test "rejects a vacuous goal whose predicates all pass at t0 and never starts the loop (T2.3, R3)",
       %{tmp_dir: tmp_dir} do
    %{work: work} = setup_repo(tmp_dir)

    # Make the code predicate already pass at t0: the marker file exists before
    # the run, so `test -f fixed.txt` is green before kazi does anything. With the
    # WHOLE vector satisfied at t0, the goal is vacuous / underspecified.
    File.write!(Path.join(work, "fixed.txt"), "already there\n")

    goal =
      Goal.new("vacuous",
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
        ],
        scope: Scope.new(workspace: work)
      )

    # Rejected at the t0 guard — before the loop starts.
    assert {:error, :vacuous_goal} =
             Runtime.run(goal,
               workspace: work,
               # A harness that would crash the run if it were ever dispatched —
               # proving the loop never started.
               adapter_opts: [command: "/nonexistent/should-not-run"]
             )

    # The loop never ran, so nothing was persisted as converged (no iterations).
    assert ReadModel.list_iterations("vacuous") == []
  end

  test "a non-vacuous goal with a failing predicate at t0 is NOT rejected and proceeds (T2.3)",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # The code predicate FAILS at t0 (no marker file yet); the harness stub
    # creates it, so the goal proceeds through the normal reconcile path instead
    # of being rejected as vacuous.
    harness_stub = write_harness_stub(tmp_dir, work)

    # A no-op deploy stub: the goal has no live predicate, so once code is landed
    # the loop deploys and converges; the stub stands in for `gcloud run deploy`.
    deploy_stub = Path.join(tmp_dir, "noop_deploy.sh")
    File.write!(deploy_stub, "#!/bin/sh\necho deployed\nexit 0\n")
    File.chmod!(deploy_stub, 0o755)

    integrator = fn request, _opts ->
      {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    goal =
      Goal.new("non-vacuous",
        predicates: [
          Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
        ],
        scope: Scope.new(workspace: work)
      )

    assert {:ok, result} =
             Runtime.run(goal,
               workspace: work,
               adapter_opts: [command: harness_stub],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               deploy_params: %{service: "s", project: "p", region: "r", source: work},
               reobserve_interval_ms: 5,
               await_timeout: 10_000
             )

    # It proceeded normally: the loop ran, dispatched the agent, and converged.
    assert result.outcome == :converged
    assert :dispatch_agent in result.actions
    assert result.iterations > 0
  end

  describe "per-goal retrieval opt-in (T4.9c, UC-022/UC-006)" do
    test "off by default: a goal that declares NO retriever dispatches the unchanged prompt",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      {capture_stub, capture_file} = write_prompt_capture_stub(tmp_dir, work)
      deploy_stub = write_noop_deploy_stub(tmp_dir)

      integrator = fn request, _opts ->
        {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      goal =
        Goal.new("retr-off",
          predicates: [
            Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
          ],
          scope: Scope.new(workspace: work)
        )

      assert {:ok, _result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: capture_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: %{service: "s", project: "p", region: "r", source: work},
                 reobserve_interval_ms: 5,
                 await_timeout: 10_000
               )

      # The dispatched prompt carries the live failing evidence and NO retrieval
      # section — off by default leaves the prompt unchanged.
      prompt = File.read!(capture_file)
      assert prompt =~ "fix failing predicates"
      refute prompt =~ "## Relevant prior context (retrieved)"
    end

    test "enabling via goal metadata injects the retrieved snippets into the dispatch prompt",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      {capture_stub, capture_file} = write_prompt_capture_stub(tmp_dir, work)
      deploy_stub = write_noop_deploy_stub(tmp_dir)

      integrator = fn request, _opts ->
        {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      # The goal DECLARES a retriever in its metadata — the per-goal opt-in. The
      # runtime threads it into adapter_opts so the loop's dispatch prompt augments
      # with the retrieved snippets.
      retriever =
        Kazi.Retrieval.StaticRetriever.new(
          snippets: [{"def prior_fix(x), do: x", source: "lib/prior.ex:7"}]
        )

      goal =
        Goal.new("retr-on",
          predicates: [
            Predicate.new(:code, :tests, config: %{cmd: "sh", args: ["-c", "test -f fixed.txt"]})
          ],
          scope: Scope.new(workspace: work),
          metadata: %{retriever: retriever}
        )

      assert {:ok, _result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: capture_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: %{service: "s", project: "p", region: "r", source: work},
                 reobserve_interval_ms: 5,
                 await_timeout: 10_000
               )

      prompt = File.read!(capture_file)
      # Augmented: the live evidence is still present AND the retrieved snippet is
      # injected in the dedicated section.
      assert prompt =~ "fix failing predicates"
      assert prompt =~ "## Relevant prior context (retrieved)"
      assert prompt =~ "def prior_fix(x), do: x"
      assert prompt =~ "lib/prior.ex:7"
    end
  end

  # --- fixtures ----------------------------------------------------------------

  # A harness stub that CAPTURES the prompt it is dispatched (the `-p` argument the
  # ClaudeAdapter passes) to a file, then "fixes" the code so the goal converges.
  # Lets a test assert what the loop's dispatch prompt actually carried. Returns
  # `{stub_path, capture_file}`.
  defp write_prompt_capture_stub(tmp_dir, _work) do
    path = Path.join(tmp_dir, "stub_capture_#{System.unique_integer([:positive])}.sh")
    capture_file = Path.join(tmp_dir, "captured_prompt_#{System.unique_integer([:positive])}.txt")

    # `claude -p <prompt> --output-format json ...`: $2 is the prompt argument.
    File.write!(path, """
    #!/bin/sh
    printf '%s' "$2" > "#{capture_file}"
    echo "the converged fix" > fixed.txt
    echo "{}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    {path, capture_file}
  end

  # A no-op deploy stub: the goal has no live predicate, so once code is landed the
  # loop deploys and converges; the stub stands in for `gcloud run deploy`.
  defp write_noop_deploy_stub(tmp_dir) do
    path = Path.join(tmp_dir, "noop_deploy_#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\necho deployed\nexit 0\n")
    File.chmod!(path, 0o755)
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

  # The harness stub: a real executable the ClaudeAdapter shells out to. It
  # writes the marker file the :tests predicate checks INTO THE WORKSPACE (proving
  # the adapter ran with cd: workspace), then exits 0.
  defp write_harness_stub(tmp_dir, _work) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    # The agent "fixes" the code by creating the file the test predicate checks.
    echo "the converged fix" > fixed.txt
    echo "harness ran in $(pwd)"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Stub emulating `gcloud run deploy`: "ship" the service by flipping the live
  # body to "ok", print progress, then the service URL.
  defp write_deploy_stub(tmp_dir, url, body_file) do
    path = Path.join(tmp_dir, "stub_deploy_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying from source..."
    # The deployed service now answers healthy.
    printf 'ok' > "#{body_file}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal local HTTP server (stdlib :inets/:httpd) that answers GET /healthz
  # with the current contents of the served body file, so the live http_probe
  # makes a real request whose result tracks the (mutable) file. Returns the
  # served body-file path so a stub can change what the probe sees.
  defp start_http_server(body) do
    docroot = Path.join(System.tmp_dir!(), "kazi_httpd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-test",
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
    tmp = Path.join(System.tmp_dir!(), "merge-#{System.unique_integer([:positive])}")
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

  # Resolve the bare origin path from a working clone, then rebase-merge there.
  defp local_rebase_merge_origin(work, branch, base) do
    {origin, 0} = System.cmd("git", ["remote", "get-url", "origin"], cd: work)
    local_rebase_merge(String.trim(origin), branch, base)
  end
end
