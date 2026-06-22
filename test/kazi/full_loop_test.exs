defmodule Kazi.FullLoop.Fixtures do
  @moduledoc """
  Local test doubles + temp-fixture builders for the full-loop integration test
  (T0.11). These are NOT lib/ stubs (the zero-stub policy is for lib/ only): they
  are real external binaries the real modules shell out to, and real git/HTTP
  scaffolding, used to point the runtime's existing injectable seams at hermetic
  local stand-ins. Defined here (in the test file) rather than under
  `test/support` because this project does not add `test/support` to
  `elixirc_paths`; the existing Tier-2 tests inline their helpers the same way.
  """

  @doc """
  A local bare "origin" with an initial commit on `main`, plus a working clone
  whose `status.txt` marker starts at `opts[:marker]` (default `"not-ok"`) — the
  not-ok→ok convergence shape the real Go dogfood fixture uses. Returns
  `%{bare: path, work: path}`.
  """
  def setup_repo(tmp_dir, opts \\ []) do
    marker = Keyword.get(opts, :marker, "not-ok")
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    # The marker the REAL code predicate (`grep -q '^ok$' status.txt`) checks.
    File.write!(Path.join(work, "status.txt"), marker <> "\n")
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

  @doc """
  The harness stub: a real executable the ClaudeAdapter shells out to. It writes
  `opts[:marker]` (default `"ok"`) into `status.txt` IN THE WORKSPACE (proving the
  adapter ran with `cd: workspace`), flipping the REAL code predicate red → green.
  """
  def write_harness_stub(tmp_dir, opts \\ []) do
    marker = Keyword.get(opts, :marker, "ok")
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    # The agent "fixes the code" by writing the marker the test predicate checks.
    echo "#{marker}" > status.txt
    echo "harness ran in $(pwd)"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  @doc """
  Stub emulating `gcloud run deploy`: "ship" the service by flipping the live body
  to "ok", print progress, then the service URL. Requires `:url` and `:body_file`.
  """
  def write_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    body_file = Keyword.fetch!(opts, :body_file)
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

  @doc """
  Like `write_deploy_stub/2` but the deploy SUCCEEDS without making the service
  healthy: it prints the service URL and exits 0, but leaves the served body
  untouched. Lets a test park the loop in the deployed-but-live-red poll state so
  the live gate can be inspected directly. Requires `:url`.
  """
  def write_noop_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    path = Path.join(tmp_dir, "stub_deploy_noop_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    # "Ship" the service (deploy succeeds) but do NOT make it healthy: the live
    # probe stays red until the test flips the served body itself.
    echo "Building and deploying from source..."
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  @doc """
  A minimal local HTTP server (stdlib `:inets`/`:httpd`) answering `GET /healthz`
  with the current contents of its body file, so the live `http_probe` makes a
  REAL request whose result tracks the (mutable) file. Returns
  `{pid, url, body_file}`; a deploy stub mutates `body_file` to change what the
  probe sees.
  """
  def start_http_server(body) do
    docroot =
      Path.join(System.tmp_dir!(), "kazi_t011_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-t011-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"healthz", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/healthz", body_file}
  end

  @doc """
  Stand-in for `gh pr merge --rebase` (no GitHub): rebase the pushed `branch` onto
  `base` in a fresh clone of the bare origin and push the result. Returns the new
  base tip SHA.
  """
  def local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "t011-merge-#{System.unique_integer([:positive])}")
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

defmodule Kazi.FullLoopTest do
  @moduledoc """
  Tier 2 — the comprehensive FULL-LOOP convergence integration test (T0.11,
  UC-005). The dress rehearsal for the T0.12 dogfood, run hermetically.

  This drives the WHOLE Slice-0 reconcile loop end-to-end through the REAL
  component wiring (`Kazi.Runtime` → `Kazi.Loop` → the real `TestRunner` and
  `HttpProbe` providers, the real `ClaudeAdapter` harness, the real `Integrate`
  and `Deploy` actions, real SQLite persistence) and proves the loop's defining
  property: **convergence is objective and live-gated** — `:converged` is reached
  ONLY after BOTH the code predicate AND the live `:http_probe` predicate are
  `:pass` (concept §1/§5, the T0.8 objective-termination guard).

  It substitutes nothing in `lib/`. It only points the seams those modules
  already expose at local doubles (`Kazi.FullLoop.Fixtures`): the harness binary
  (`adapter_opts: [command: stub]`), the integrate action's `:integrator` (a real
  local rebase-merge into a bare origin — no GitHub), and the deploy action's
  `:deploy_cmd` (a stub emulating `gcloud run deploy` — no gcloud). The live probe
  is a REAL HTTP request against a local stdlib `:inets` server whose body flips
  from "not-ok" to "ok" only when the deploy stub runs — so the live predicate is
  genuinely deploy-gated, exactly as in production.

  ## What makes this distinct from `Kazi.RuntimeTest` / `Kazi.CLITest`

  Those assert the *final* terminal state and the action order. T0.11 additionally
  asserts the **intermediate** state that is the whole point of the loop: it
  follows the not-ok→ok convergence SHAPE of the real Go dogfood fixture
  (`fixtures/deploy-target/`, reserved for T0.12) using a REAL failing command
  (`grep -q '^ok$' status.txt` over a `status.txt` that starts `not-ok`), and it
  proves from the persisted iteration history that while the code predicate was
  green but the live probe was still red, the loop did **not** converge. No Go and
  no external network: it runs under `mix test` on a clean Elixir-only CI runner.
  """
  # Real git + real local HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Loop, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}
  alias Kazi.FullLoop.Fixtures

  @moduletag :tmp_dir

  @goal_id "full-loop-t011"

  setup do
    # The runtime's persistence seam writes through Kazi.ReadModel on the loop's
    # process. Share this checked-out Sandbox connection with any process so the
    # loop's writes land in the transaction the test reads from.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "the full reconcile loop, end-to-end and hermetic (UC-005)" do
    test "converges only after BOTH code and live predicates pass, and persists the history",
         %{tmp_dir: tmp_dir} do
      # --- ARRANGE: a temp workspace mirroring the Go fixture's not-ok→ok shape -
      #
      # A real git repo (with a bare "origin") whose `status.txt` marker starts at
      # `not-ok` — so the REAL code predicate `grep -q '^ok$' status.txt` exits
      # non-zero (a genuine :fail), exactly like the dogfood fixture's failing
      # test. The harness stub will flip it to `ok`.
      %{work: work, bare: bare} = Fixtures.setup_repo(tmp_dir, marker: "not-ok")

      # The live probe makes a REAL request against this local server. Its body
      # starts "not-ok" so the live predicate FAILS before deploy; the deploy stub
      # flips it to "ok" so the probe passes ONLY against the "deployed" service.
      {server, url, body_file} = Fixtures.start_http_server("not-ok")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # The harness stub "fixes the code": it writes `ok` into status.txt in the
      # workspace, so the next real observation of the test_runner predicate flips
      # red → green. This proves observe→dispatch→re-observe reacts to REAL
      # predicate results.
      harness_stub = Fixtures.write_harness_stub(tmp_dir, marker: "ok")

      # The deploy stub stands in for `gcloud run deploy`: it "ships" the service
      # by flipping the live body to "ok", then prints the service URL.
      deploy_stub = Fixtures.write_deploy_stub(tmp_dir, url: url, body_file: body_file)

      # A real local rebase-merge integrator (stands in for `gh pr merge
      # --rebase`) — no GitHub. Reports back so the test can assert it ran.
      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch, request.base})
        merge_commit = Fixtures.local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 11, merge_commit: merge_commit}}
      end

      goal =
        Goal.new(@goal_id,
          predicates: [
            # REAL test-runner: a command that genuinely fails until status.txt
            # contains exactly `ok` (mirrors the Go fixture's not-ok→ok test).
            Predicate.new(:code, :tests,
              config: %{cmd: "sh", args: ["-c", "grep -q '^ok$' status.txt"]}
            ),
            # REAL live probe against the running server (deploy-gated by kind).
            Predicate.new(:live, :http_probe,
              config: %{url: url, expect_status: 200, expect_body: "ok", body_match: :exact}
            )
          ],
          scope: Scope.new(workspace: work)
        )

      # --- ACT: drive the goal to a terminal state through the real runtime -----
      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: %{
                   service: "kazi-t011",
                   project: "kazi-test",
                   region: "us-central1",
                   source: work
                 },
                 # Poll the live predicate fast so the test doesn't wait on the
                 # production default interval.
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # --- ASSERT 1: the loop converged via the full reconcile sequence ---------
      #
      # dispatch (code red) → integrate (code green, not landed) → deploy (landed)
      # → converge once the live probe passes against the "deployed" service.
      assert result.outcome == :converged
      assert result.actions == [:dispatch_agent, :integrate, :deploy]

      # The harness REALLY ran in the workspace and fixed the code marker.
      assert File.read!(Path.join(work, "status.txt")) |> String.trim() == "ok"

      # The integrate action's real local git path ran (the fix landed on origin).
      assert_received {:integrated, branch, "main"}
      assert is_binary(branch)
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "status.txt"

      # --- ASSERT 2: the LIVE GATE (T0.8 / UC-005) ------------------------------
      #
      # The headline assertion: convergence is objective and live-gated. Read the
      # full persisted history and prove that the loop observed a state where the
      # CODE predicate was already :pass but the LIVE probe was still NOT :pass —
      # and in EVERY such observation the loop did NOT converge. This is the
      # objective-termination guard in action: code-green is not enough; the live
      # probe must hold too.
      iterations = ReadModel.list_iterations(@goal_id)
      assert length(iterations) == result.iterations

      code_green_live_red =
        Enum.filter(iterations, fn it ->
          vector = ReadModel.to_predicate_vector(it)
          # to_predicate_vector keys by string ids (their on-disk form).
          code_pass?(vector, "code") and not code_pass?(vector, "live")
        end)

      # There MUST be at least one such observation: after the harness fixes the
      # code (code → green) the loop still has to integrate and deploy before the
      # live probe can pass, so code-green/live-red is necessarily observed.
      assert code_green_live_red != [],
             "expected at least one observed iteration with code :pass and live not :pass " <>
               "(the live gate) — the loop must reconcile through integrate+deploy before " <>
               "the live probe can pass"

      # NONE of those code-green/live-red iterations may be marked converged: a
      # failing live probe blocks success exactly as a failing test does.
      refute Enum.any?(code_green_live_red, & &1.converged),
             "the loop converged while the live probe was still failing — the objective " <>
               "termination guard (T0.8) regressed to 'code green is good enough'"

      # --- ASSERT 3: persistence / iteration history ----------------------------
      #
      # Every observed iteration was projected to the read-model in order, and ONLY
      # the final iteration is marked converged.
      assert Enum.map(iterations, & &1.iteration_index) ==
               Enum.to_list(0..(result.iterations - 1))

      last = List.last(iterations)
      assert last.converged == true
      refute Enum.any?(Enum.drop(iterations, -1), & &1.converged)

      # The first observation FAILED to converge (code predicate was genuinely red
      # on the unfixed fixture): the loop did not declare premature success.
      first = List.first(iterations)
      assert first.converged == false
      first_vector = ReadModel.to_predicate_vector(first)
      refute code_pass?(first_vector, "code")

      # The persisted final vector is the satisfied one the loop converged on —
      # BOTH predicates :pass.
      final_vector = ReadModel.to_predicate_vector(last)
      assert PredicateVector.satisfied?(final_vector)
      assert code_pass?(final_vector, "code")
      assert code_pass?(final_vector, "live")
    end

    test "the live gate, observed in real time: code green + landed + deployed but live red is NOT terminal",
         %{tmp_dir: tmp_dir} do
      # This drives the same real loop but parks it in the loop's step-5 LIVE POLL
      # state — code green, change landed AND deployed, yet the live probe still
      # red because the "deployed" service is not healthy yet — and asserts
      # directly, via `Kazi.Loop.snapshot/1`, that the loop is NOT terminal there.
      # It is the live-gate proof in real time, complementing the history-based
      # proof above. The probe is held red simply by leaving the served body at
      # "not-ok"; the test then flips it to "ok" and watches the loop converge.
      %{work: work, bare: bare} = Fixtures.setup_repo(tmp_dir, marker: "not-ok")
      # The served body starts (and stays) "not-ok" until THIS test flips it, so
      # the loop reaches deployed-but-live-red and stays there, pollable.
      {server, url, body_file} = Fixtures.start_http_server("not-ok")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      harness_stub = Fixtures.write_harness_stub(tmp_dir, marker: "ok")

      # A deploy stub that "ships" successfully but does NOT make the service
      # healthy (it does not touch the body file). So after deploy the loop is
      # landed + deployed with the live probe still red — the step-5 poll state.
      deploy_stub = Fixtures.write_noop_deploy_stub(tmp_dir, url: url)

      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch})
        merge_commit = Fixtures.local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 12, merge_commit: merge_commit}}
      end

      goal =
        Goal.new("full-loop-t011-live-gate",
          predicates: [
            Predicate.new(:code, :tests,
              config: %{cmd: "sh", args: ["-c", "grep -q '^ok$' status.txt"]}
            ),
            Predicate.new(:live, :http_probe,
              config: %{url: url, expect_status: 200, expect_body: "ok", body_match: :exact}
            )
          ],
          scope: Scope.new(workspace: work)
        )

      # Drive the loop directly (non-blocking) so we can snapshot it while it polls
      # the live predicate.
      providers = %{tests: Kazi.Providers.TestRunner, http_probe: Kazi.Providers.HttpProbe}

      {:ok, loop} =
        Loop.start_link(
          goal: goal,
          providers: providers,
          harness: Kazi.Harness.ClaudeAdapter,
          integrate: Kazi.Actions.Integrate,
          deploy: Kazi.Actions.Deploy,
          workspace: work,
          adapter_opts: [command: harness_stub],
          integrate_params: %{},
          deploy_params: %{
            service: "kazi-t011-gate",
            project: "kazi-test",
            region: "us-central1",
            source: work,
            cmd: deploy_stub
          },
          extra_action_context: %{integrator: integrator},
          # Poll the live predicate slowly enough that the loop is reliably IDLE
          # between polls when we snapshot it (a busy gen_statem cannot answer a
          # synchronous snapshot/await call).
          reobserve_interval_ms: 50
        )

      # The integrate seam ran (code went green and was landed).
      assert_receive {:integrated, _branch}, 5_000

      # Wait until the loop has landed AND deployed but the live probe is still
      # red — the step-5 live-poll state. snapshot/1 succeeds here because the
      # loop is idle between polls.
      assert wait_until(
               fn ->
                 snap = Loop.snapshot(loop)

                 snap.landed? and snap.deployed? and
                   code_pass?(snap.vector, :code) and not code_pass?(snap.vector, :live)
               end,
               10_000
             ),
             "the loop never reached the deployed-but-live-red poll state"

      # INSPECT THE LIVE GATE: code green, change landed AND deployed, but the
      # live probe is still red — and the loop is NOT terminal. It is reconciling
      # (polling the live predicate), not converged. This is the objective
      # termination guard (T0.8 / UC-005) holding the line: code-green-and-shipped
      # is still not success while the live probe fails.
      snap = Loop.snapshot(loop)
      refute snap.state in [:converged, :stopped]
      assert snap.landed? == true
      assert snap.deployed? == true
      assert code_pass?(snap.vector, :code)
      refute code_pass?(snap.vector, :live)
      assert {:error, :timeout} = Loop.await(loop, 100)

      # Bring the "deployed" service healthy; the next poll observes the live probe
      # passing and the loop finally converges.
      File.write!(body_file, "ok")

      assert {:ok, terminal} = Loop.await(loop, 10_000)
      assert terminal.outcome == :converged
      assert code_pass?(terminal.vector, :code)
      assert code_pass?(terminal.vector, :live)
      Loop.stop(loop)
    end
  end

  # --- helpers ----------------------------------------------------------------

  # A predicate result is "pass" when its status is :pass. Tolerates the on-disk
  # rehydrated vector (status :pass) and the in-memory vector alike, and a nil
  # (absent) result counts as not-pass.
  defp code_pass?(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      nil -> false
      %{status: status} -> status == :pass
    end
  end

  # Poll `fun` until it returns truthy or the deadline elapses.
  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
