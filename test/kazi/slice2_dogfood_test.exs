defmodule Kazi.Slice2DogfoodTest do
  @moduledoc """
  Tier 2 — the SLICE-2 CREATION ACCEPTANCE DOGFOOD (T2.5, verifying UC-010).

  This is the creation analog of the Slice-0 full-loop dogfood (T0.11/T0.12) and
  the Slice-1 regression dogfood (T1.8): it demonstrates, end-to-end through the
  REAL `Kazi.Runtime`/`Kazi.Loop`, the exact scenario the slice exists for —
  **kazi BUILDING a small real feature from failing acceptance predicates, driven
  red → green → live** (concept §10 Slice 2, the creation-mode milestone). Where
  the Slice-1 dogfood proves kazi catches a bad fix, this proves kazi makes a good
  one: it does not just REPAIR regressed behavior, it CREATES behavior that did
  not exist before.

  ## The feature spec (as failing acceptance predicates)

  A tiny real feature, specified as acceptance criteria over the REAL
  `Kazi.Providers.HttpProbe` against a REAL local HTTP server (stdlib
  `:inets`/`:httpd`) — an actually-running service the probe hits over `127.0.0.1`,
  NOT Cloud Run (production Cloud-Run-live remains the GCP-gated T0.12; this
  dogfood is deliberately hermetic — no Go, no external network, no GCP, no real
  browser):

    * **`greeting_endpoint`** (`http_probe`, acceptance): `GET /greeting` returns
      HTTP 200. At t0 the server serves the literal 404-shaped body `not found`
      (the route does not exist yet), so the *body* assertion below cannot hold —
      this is the failing work-list item that DEFINES the feature.
    * **`greeting_body`** (`http_probe`, acceptance): `GET /greeting` returns a
      body containing `hello, kazi`. At t0 the endpoint does not serve that
      greeting, so this FAILS — the precise behavior kazi must CREATE.

  Both acceptance criteria are authored to FAIL at t0 (the feature is absent), so
  the vacuous-goal guard (T2.3) does NOT trip — there is real work to do.

  ## How the build happens (genuine, over the real seams)

  The loop runs the REAL `Kazi.Runtime` wiring. The only test-only doubles are the
  seams the real modules already expose (the zero-stub policy is for `lib/` only,
  exactly as `Kazi.FullLoopTest` / `Kazi.Slice1DogfoodTest` / `Kazi.Slice2Test`
  do it):

    * the **harness** binary (`adapter_opts: [command: stub]`) is the coding agent
      that performs the genuine "build": it writes the feature's source marker
      into the workspace so the CODE acceptance predicate flips red → green, which
      is what drives the loop past `:dispatch_agent` into integrate/deploy;
    * the **integrate** action's `:integrator` seam is a real local rebase-merge
      into a bare `origin` (no GitHub) — the built feature genuinely lands;
    * the **deploy** action's `:deploy_cmd` seam is a stub emulating
      `gcloud run deploy` (no gcloud); when it "ships" the built feature it
      rewrites the REAL local server's response body so the live `http_probe`
      acceptance criteria can only pass against the deployed feature.

  The "live" check is therefore a REAL http_probe request against an actually
  running local server whose body the deploy step rewrites — proving the feature
  is live, not merely that code compiled.

  ## What this proves (the D2 acceptance)

    1. At t0 the acceptance vector FAILS (the feature is absent) and the
       vacuous-goal guard does NOT trip (there is real work).
    2. kazi dispatches the agent → the feature gets built → integrate lands it →
       deploy ships it → the live acceptance criteria flip to pass → kazi
       converges. The full creation arc, end to end.
    3. kazi did NOT converge before the feature existed: the objective-termination
       guard (T0.8) holds for creation exactly as for repair — there is an
       observed state where the built code acceptance passed but the live greeting
       had not yet flipped, and the loop did NOT converge there.
    4. The iteration history is persisted to the read-model, with NO iteration
       marked converged before the live feature held.

  Hermetic: its own SQLite Sandbox connection, a real harness binary, a real temp
  git repo, a real local HTTP server — no Go, no external network, no GitHub, no
  GCP, no real browser. The local doubles are defined inline (this project does
  not add `test/support` to `elixirc_paths`, so a test cannot rely on a sibling
  test file's helpers being compiled — the existing Tier-2 tests inline theirs for
  the same reason).
  """
  # Real git + real local HTTP + real subprocess (harness/deploy) + the shared
  # SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}

  @moduletag :tmp_dir

  @goal_id "slice2-dogfood-t25"

  # The greeting the built feature must serve (the behavior kazi CREATES).
  @greeting "hello, kazi"

  setup do
    # The runtime persists each iteration through Kazi.ReadModel on the loop's own
    # process; share this checked-out Sandbox connection so the loop's writes land
    # where the test reads (mirrors Kazi.FullLoopTest / Kazi.Slice2Test).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "creation dogfood: kazi builds a small real feature to green-and-live (UC-010, D2)" do
    test "a GET /greeting feature, authored as failing http_probe acceptance criteria, is built to converged",
         %{tmp_dir: tmp_dir} do
      # --- ARRANGE: the feature does NOT exist yet ------------------------------
      #
      # A real git repo whose feature source marker is "absent": the CODE
      # acceptance predicate (`grep -q '^built$' greeting.feature`) FAILS at t0 —
      # the failing work-list item that drives the agent to BUILD the feature.
      %{work: work, bare: bare} = setup_feature_repo(tmp_dir, marker: "absent")

      # The REAL local HTTP server. At t0 the GET /greeting ROUTE IS ABSENT — the
      # backing resource does not exist, so the server genuinely 404s (the
      # create_feature.toml semantics: "the deployed service 404s, no such route
      # yet"). Both live acceptance criteria therefore FAIL at t0: there is no 200,
      # and no greeting body. The deploy stub CREATES the resource (the new route)
      # serving the greeting once the built feature ships, so the live probe can
      # only pass against the deployed feature.
      {server, url, body_file} = start_greeting_server(:absent)
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # The harness stub IS the coding agent performing the genuine build: it writes
      # the feature source marker the CODE acceptance predicate checks, flipping it
      # red → green (this is what carries the loop past dispatch into integrate).
      harness_stub = write_build_harness(tmp_dir, marker: "built")

      # The deploy stub stands in for `gcloud run deploy` (no gcloud): it "ships"
      # the built feature by rewriting the REAL server's body to the greeting, so
      # the live http_probe acceptance criteria pass only against the deployed
      # feature.
      deploy_stub =
        write_deploy_stub(tmp_dir, url: url, body_file: body_file, greeting: @greeting)

      # A real local rebase-merge integrator (no GitHub) that reports back so the
      # test can assert the built feature genuinely landed on origin.
      integrator = local_integrator(bare, self(), pr: 25)

      # --- The feature, specified as FAILING acceptance predicates --------------
      goal =
        Goal.new(@goal_id,
          mode: :create,
          name: "Build a GET /greeting endpoint from failing acceptance criteria",
          predicates: [
            # CODE acceptance: the feature's source must exist. FAILS at t0
            # (marker "absent"); the agent builds it (marker "built"). This is what
            # drives the loop from dispatch into integrate/deploy so the LIVE
            # criteria below can be re-checked against the deployed feature.
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              description: "the GET /greeting feature source exists — fails at t0",
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' greeting.feature"]}
            ),
            # LIVE acceptance: GET /greeting returns 200. A REAL request against the
            # running local server.
            Predicate.new(:greeting_endpoint, :http_probe,
              acceptance?: true,
              description: "GET /greeting returns 200 (the new endpoint exists) — fails at t0",
              config: %{url: url, expect_status: 200}
            ),
            # LIVE acceptance: GET /greeting body contains the greeting. The precise
            # behavior kazi must CREATE; a REAL request against the running server.
            Predicate.new(:greeting_body, :http_probe,
              acceptance?: true,
              description: ~s|GET /greeting body contains "#{@greeting}" — fails at t0|,
              config: %{
                url: url,
                expect_status: 200,
                expect_body: @greeting,
                body_match: :contains
              }
            )
          ],
          scope: Scope.new(workspace: work)
        )

      # The goal is a self-describing CREATE goal with three acceptance criteria.
      assert Goal.create?(goal)
      assert goal |> Goal.acceptance_predicates() |> length() == 3

      # --- PRE-FLIGHT: every acceptance criterion FAILS at t0 -------------------
      #
      # Confirm the honest starting point BEFORE running the loop: against the real
      # world (the unbuilt workspace + the not-yet-serving local server) NOT ONE
      # acceptance criterion holds. This is what makes the goal non-vacuous: there
      # is genuine work to do. We assert it here so the "build" is unambiguous —
      # kazi starts from nothing.
      refute t0_pass?(goal, work, "feature_built")
      refute t0_pass?(goal, work, "greeting_endpoint")
      refute t0_pass?(goal, work, "greeting_body")

      # --- ACT: drive the REAL runtime to a terminal state ----------------------
      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: deploy_params(work),
                 # Poll fast so the dogfood does not wait on the production interval.
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # --- ASSERT 1: kazi CONVERGED via the full build sequence -----------------
      #
      # The feature was built from failing acceptance criteria to green-and-live:
      # dispatch (BUILD) → integrate (LAND) → deploy (SHIP) → converge once the
      # live greeting holds. This is the creation arc end to end.
      assert result.outcome == :converged,
             "the creation dogfood did not converge: #{inspect(result)}"

      assert result.actions == [:dispatch_agent, :integrate, :deploy]

      # The harness REALLY built the feature source in the workspace.
      assert File.read!(Path.join(work, "greeting.feature")) |> String.trim() == "built"

      # The integrate action's real local git path landed the built feature on
      # origin's main (no GitHub).
      assert_received {:integrated, _branch, "main"}
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "greeting.feature"

      # The live feature is genuinely serving the greeting (a final REAL request
      # against the running local server — not a stored verdict).
      assert {:ok, {{_v, 200, _r}, _h, live_body}} =
               :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary)

      assert live_body =~ @greeting,
             "the deployed endpoint did not serve the built greeting: #{inspect(live_body)}"

      # --- ASSERT 2: the persisted history witnesses the full red → green arc ----
      iterations = ReadModel.list_iterations(@goal_id)
      assert iterations != []
      assert length(iterations) == result.iterations

      # The FIRST observation is the honest starting point: every acceptance
      # criterion FAILED (the feature did not exist). kazi did not mistake the
      # empty starting state for success.
      first = iterations |> List.first() |> ReadModel.to_predicate_vector()
      refute pass?(first, "feature_built")
      refute pass?(first, "greeting_endpoint")
      refute pass?(first, "greeting_body")

      # --- ASSERT 3: kazi did NOT converge before the feature existed -----------
      #
      # The objective-termination guard (T0.8) holds for CREATION too: there is an
      # observed state where the built CODE acceptance passed but the LIVE greeting
      # had not yet flipped (code built but not deployed) — and in NO such state
      # did the loop converge. Convergence was gated on the live feature, not on
      # code-green. This is the headline anti-false-success assertion.
      code_green_live_red =
        Enum.filter(iterations, fn it ->
          v = ReadModel.to_predicate_vector(it)

          pass?(v, "feature_built") and
            not (pass?(v, "greeting_endpoint") and pass?(v, "greeting_body"))
        end)

      assert code_green_live_red != [],
             "expected an observation where the built code acceptance passed but the live " <>
               "greeting had not yet flipped (build → integrate → deploy gate)"

      refute Enum.any?(code_green_live_red, & &1.converged),
             "the create goal converged while a live acceptance criterion was still failing — " <>
               "kazi declared the feature done before it was live"

      # Exactly the LAST persisted iteration is converged; none before it.
      last = List.last(iterations)
      assert last.converged
      refute Enum.any?(Enum.drop(iterations, -1), & &1.converged)

      # The terminal vector is objectively satisfied — every acceptance criterion
      # passes with stored evidence.
      final = ReadModel.to_predicate_vector(last)
      assert PredicateVector.satisfied?(final)
      assert pass?(final, "feature_built")
      assert pass?(final, "greeting_endpoint")
      assert pass?(final, "greeting_body")
    end
  end

  # ===========================================================================
  # Helpers — local doubles (NOT lib/ stubs; the zero-stub policy is lib/ only).
  # Real external programs / git scaffolding / a real local HTTP server the real
  # modules drive over their existing injectable seams (mirrors Slice2Test /
  # Slice1DogfoodTest / FullLoopTest).
  # ===========================================================================

  # A bare "origin" + working clone whose feature source marker
  # `greeting.feature` starts at `opts[:marker]`. "absent" = the feature does not
  # exist yet (the creation shape).
  defp setup_feature_repo(tmp_dir, opts) do
    marker = Keyword.fetch!(opts, :marker)
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    File.write!(Path.join(work, "greeting.feature"), marker <> "\n")
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

  # The build harness: the coding agent that performs the genuine "build" by
  # writing the feature source marker the CODE acceptance predicate checks into
  # the workspace (red → green). Run with cd: workspace by the ClaudeAdapter.
  defp write_build_harness(tmp_dir, opts) do
    marker = Keyword.fetch!(opts, :marker)
    path = Path.join(tmp_dir, "stub_build_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    # The agent BUILDS the feature: write the source marker the acceptance
    # predicate checks (this is the genuine red -> green build of the feature).
    echo "#{marker}" > greeting.feature
    echo "harness built the GET /greeting feature in $(pwd)"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal local HTTP server (stdlib :inets/:httpd) serving GET /greeting from
  # a backing file under its docroot. The http_probe makes a REAL request whose
  # result tracks that (mutable) file: when the file is ABSENT the server genuinely
  # 404s (the "route does not exist yet" t0 shape); the deploy step CREATES the
  # file with the greeting so the route comes into being live. Passing `:absent`
  # starts with no backing file (404 at t0). Returns {pid, url, body_file}.
  defp start_greeting_server(body) do
    docroot =
      Path.join(System.tmp_dir!(), "kazi_t25_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "greeting")

    case body do
      :absent -> File.rm_rf!(body_file)
      contents when is_binary(contents) -> File.write!(body_file, contents)
    end

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-t25-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"greeting", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/greeting", body_file}
  end

  # Stand-in for `gcloud run deploy` (no gcloud): ship the built feature so the
  # deployed endpoint serves the greeting — the live acceptance criteria pass only
  # against it.
  defp write_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    body_file = Keyword.fetch!(opts, :body_file)
    greeting = Keyword.fetch!(opts, :greeting)
    path = Path.join(tmp_dir, "stub_deploy_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying the GET /greeting feature from source..."
    printf '#{greeting}' > "#{body_file}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A real local rebase-merge integrator (stands in for `gh pr merge --rebase`) —
  # no GitHub. Reports back to `pid` so the test can assert it ran.
  defp local_integrator(bare, pid, opts) do
    pr = Keyword.fetch!(opts, :pr)

    fn request, _opts ->
      send(pid, {:integrated, request.branch, request.base})
      merge_commit = local_rebase_merge(bare, request.branch, request.base)
      {:ok, %{pr: pr, merge_commit: merge_commit}}
    end
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "t25-merge-#{System.unique_integer([:positive])}")
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

  defp deploy_params(work) do
    %{service: @goal_id, project: "kazi-test", region: "us-central1", source: work}
  end

  # Evaluate ONE of the goal's acceptance predicates through its real provider
  # against the real world at t0 (the pre-flight check that the feature is absent),
  # mirroring the runtime's own t0 observation. Returns whether it passes.
  defp t0_pass?(%Goal{} = goal, workspace, id) do
    predicate = Enum.find(Goal.all_predicates(goal), &(to_string(&1.id) == id))

    provider = Map.fetch!(Runtime.provider_modules(), predicate.kind)

    context = %{
      goal: goal,
      scope: goal.scope,
      workspace: workspace,
      landed?: false,
      deployed?: false,
      iteration: 0
    }

    case provider.evaluate(predicate, context) do
      %{status: :pass} -> true
      _ -> false
    end
  end

  defp pass?(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      nil -> false
      %{status: status} -> status == :pass
    end
  end
end
