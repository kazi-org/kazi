defmodule Kazi.CreationLoopTest do
  @moduledoc """
  Tier 2 — the creation-mode convergence integration test (T2.1, UC-010).

  Slice 0/1 drive *repair* goals: predicates describing behavior that has
  regressed. Slice 2 (concept §10) adds *creation mode*: a goal is authored as
  **acceptance criteria** — predicates describing desired NEW behavior that FAIL
  at t0 (the feature does not exist yet) and pass once kazi BUILDS it. This test
  proves the SAME convergence machinery the repair loop uses now drives a
  creation goal from failing acceptance criteria to converged — kazi builds a
  feature, it does not only repair one.

  It substitutes nothing in `lib/`. Exactly like `Kazi.FullLoopTest`, it only
  points the seams the real modules already expose at hermetic local doubles: the
  harness binary (`adapter_opts: [command: stub]`) is the coding agent that
  "builds the feature"; the integrate action's `:integrator` is a real local
  rebase-merge into a bare origin (no GitHub); the deploy action's `:deploy_cmd`
  is a stub emulating `gcloud run deploy` (no gcloud). The live acceptance
  criterion is a REAL HTTP request against a local stdlib `:inets` server whose
  body flips from a 404-shaped "absent" to the feature's payload only when the
  deploy stub runs — so the acceptance predicate is genuinely build-and-deploy-
  gated, exactly as in production. No Go, no external network.

  The local doubles are defined inline (not shared with `Kazi.FullLoopTest`)
  because this project does not add `test/support` to `elixirc_paths`, so a test
  cannot rely on a sibling test file's helper module being compiled — the
  existing Tier-2 tests inline their helpers for the same reason.

  The creation goal is authored with:

    * a CODE acceptance predicate (`acceptance?: true`, kind `:tests`) that fails
      at t0 because the new feature's test does not pass yet — this is the
      failing work-list item that drives the agent to BUILD the feature; and
    * a LIVE acceptance predicate (`acceptance?: true`, kind `:http_probe`)
      asserting the new endpoint serves the expected payload once deployed.

  Both fail at t0; the loop converges only once the harness has built the feature
  (code acceptance flips green), the change is landed + deployed, and the live
  http_probe acceptance criterion holds against the deployed service.
  """
  # Real git + real local HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}

  @moduletag :tmp_dir

  @goal_id "creation-loop-t21"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "creation mode: a goal authored as failing acceptance criteria converges (UC-010)" do
    test "kazi drives a create goal from failing http_probe acceptance to converged",
         %{tmp_dir: tmp_dir} do
      # --- ARRANGE: a workspace whose feature does NOT exist yet ----------------
      #
      # The "feature marker" file `feature.txt` starts at "absent": the new code
      # does not exist. The CODE acceptance predicate `grep -q '^built$'
      # feature.txt` therefore FAILS at t0 (the feature is unbuilt) — a genuine
      # :fail that drives the agent, exactly the creation-mode shape.
      %{work: work, bare: bare} = setup_feature_repo(tmp_dir, marker: "absent")

      # The LIVE acceptance criterion makes a REAL request against this local
      # server. Its body starts "absent" (the endpoint 404-equivalent doesn't
      # serve the feature) so the http_probe acceptance predicate FAILS before the
      # feature is built+deployed; the deploy stub flips it to the feature payload.
      {server, url, body_file} = start_http_server("absent")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # The harness stub IS the coding agent: it "builds the feature" by writing
      # the marker the code acceptance predicate checks, flipping it red → green.
      # This proves observe→dispatch→re-observe drives a CREATION goal: the agent
      # is dispatched against a failing acceptance criterion and builds toward it.
      harness_stub = write_harness_stub(tmp_dir, marker: "built")

      # The deploy stub stands in for `gcloud run deploy`: it "ships" the freshly
      # built feature, making the deployed endpoint serve the feature payload
      # ("widgets") — so the live acceptance criterion passes ONLY against the
      # built-and-deployed service.
      deploy_stub = write_feature_deploy_stub(tmp_dir, url: url, body_file: body_file)

      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrated, request.branch, request.base})
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 21, merge_commit: merge_commit}}
      end

      # The CREATION goal: mode :create, both predicates marked acceptance?: true.
      # Both fail at t0 — the feature does not exist.
      goal =
        Goal.new(@goal_id,
          mode: :create,
          predicates: [
            # CODE acceptance criterion: the new feature's test, failing until the
            # agent builds it (mirrors a new feature's failing acceptance test).
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            # LIVE acceptance criterion over http_probe: GET the new endpoint and
            # assert it serves the feature payload — true only once built+deployed.
            Predicate.new(:widgets_live, :http_probe,
              acceptance?: true,
              config: %{url: url, expect_status: 200, expect_body: "widgets", body_match: :exact}
            )
          ],
          scope: Scope.new(workspace: work)
        )

      # The goal really is a creation goal whose predicates are acceptance criteria.
      assert Goal.create?(goal)
      assert goal |> Goal.acceptance_predicates() |> length() == 2

      # --- ACT: drive the create goal to a terminal state through the real runtime
      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: %{
                   service: "kazi-t21",
                   project: "kazi-test",
                   region: "us-central1",
                   source: work
                 },
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # --- ASSERT 1: the create goal converged via the full build sequence ------
      #
      # dispatch (the agent BUILDS the feature) → integrate (land it) → deploy
      # (ship it) → converge once the live acceptance criterion passes.
      assert result.outcome == :converged
      assert result.actions == [:dispatch_agent, :integrate, :deploy]

      # The harness REALLY ran in the workspace and BUILT the feature marker.
      assert File.read!(Path.join(work, "feature.txt")) |> String.trim() == "built"

      # The integrate action's real local git path landed the built feature.
      assert_received {:integrated, branch, "main"}
      assert is_binary(branch)
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "feature.txt"

      # --- ASSERT 2: the acceptance criteria failed at t0, drove the work -------
      #
      # The first observation must show BOTH acceptance criteria failing: the
      # feature did not exist yet. This is the defining property of creation mode —
      # a goal that does NOT pass at t0 (cf. the vacuous-goal guard, T2.3).
      iterations = ReadModel.list_iterations(@goal_id)
      assert length(iterations) == result.iterations

      first = List.first(iterations)
      first_vector = ReadModel.to_predicate_vector(first)
      refute first.converged

      refute pass?(first_vector, "feature_built"),
             "the code acceptance criterion must FAIL at t0 (the feature is unbuilt)"

      refute pass?(first_vector, "widgets_live"),
             "the live acceptance criterion must FAIL at t0 (the endpoint does not exist)"

      # --- ASSERT 3: the live gate still holds for a create goal ----------------
      #
      # After the agent builds the feature (code acceptance green) the loop must
      # still integrate + deploy before the live http_probe acceptance can pass.
      # There MUST be an observed state where the code acceptance is :pass but the
      # live acceptance is not — and in NO such state did the loop converge.
      code_green_live_red =
        Enum.filter(iterations, fn it ->
          v = ReadModel.to_predicate_vector(it)
          pass?(v, "feature_built") and not pass?(v, "widgets_live")
        end)

      assert code_green_live_red != [],
             "expected an observation where the built feature's code acceptance passed but the " <>
               "live http_probe acceptance had not yet flipped (build → integrate → deploy gate)"

      refute Enum.any?(code_green_live_red, & &1.converged),
             "the create goal converged while its live acceptance criterion was still failing"

      # --- ASSERT 4: convergence is the full acceptance vector ------------------
      last = List.last(iterations)
      assert last.converged == true
      refute Enum.any?(Enum.drop(iterations, -1), & &1.converged)

      final_vector = ReadModel.to_predicate_vector(last)
      assert PredicateVector.satisfied?(final_vector)
      assert pass?(final_vector, "feature_built")
      assert pass?(final_vector, "widgets_live")
    end
  end

  # --- helpers ----------------------------------------------------------------

  # A bare "origin" + working clone whose feature marker `feature.txt` starts at
  # `opts[:marker]` ("absent" by default). Mirrors Fixtures.setup_repo/2 but for
  # the creation shape (the feature does not exist yet).
  defp setup_feature_repo(tmp_dir, opts) do
    marker = Keyword.get(opts, :marker, "absent")
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    # The marker the CODE acceptance predicate (`grep -q '^built$' feature.txt`)
    # checks: "absent" until the agent builds the feature.
    File.write!(Path.join(work, "feature.txt"), marker <> "\n")
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

  # The harness stub: a real executable the ClaudeAdapter shells out to. It is the
  # coding agent that "builds the feature" by writing the marker the code
  # acceptance predicate checks into the workspace, flipping it red → green.
  defp write_harness_stub(tmp_dir, opts) do
    marker = Keyword.get(opts, :marker, "built")
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    # The agent "builds the feature" by writing the marker the acceptance predicate checks.
    echo "#{marker}" > feature.txt
    echo "harness built the feature in $(pwd)"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal local HTTP server (stdlib `:inets`/`:httpd`) answering `GET /healthz`
  # with the current contents of its body file, so the live `http_probe` makes a
  # REAL request whose result tracks the (mutable) file. Returns
  # `{pid, url, body_file}`; the deploy stub mutates `body_file` to change what the
  # probe sees.
  defp start_http_server(body) do
    docroot =
      Path.join(System.tmp_dir!(), "kazi_t21_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-t21-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"healthz", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/healthz", body_file}
  end

  # Stand-in for `gh pr merge --rebase` (no GitHub): rebase the pushed `branch`
  # onto `base` in a fresh clone of the bare origin and push the result. Returns
  # the new base tip SHA.
  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "t21-merge-#{System.unique_integer([:positive])}")
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

  # Stub emulating `gcloud run deploy` for the CREATION shape: "ship" the freshly
  # built feature so the deployed endpoint serves its payload ("widgets"), print
  # the service URL, exit 0. Like Fixtures.write_deploy_stub/2 but serves the
  # feature payload rather than the repair fixture's "ok".
  defp write_feature_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    body_file = Keyword.fetch!(opts, :body_file)
    path = Path.join(tmp_dir, "stub_deploy_feature_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying the new feature from source..."
    # The deployed service now serves the newly built feature payload.
    printf 'widgets' > "#{body_file}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp pass?(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      nil -> false
      %{status: status} -> status == :pass
    end
  end
end
