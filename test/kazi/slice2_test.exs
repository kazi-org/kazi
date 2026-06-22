defmodule Kazi.Slice2Test do
  @moduledoc """
  Tier 2 — the CONSOLIDATED, cross-cutting suite for Slice-2 creation mode
  (T2.4, verifying UC-010 and UC-012).

  The three Slice-2 features each have a focused test that proves the feature in
  isolation: `Kazi.CreationLoopTest` (T2.1) drives ONE create goal whose
  acceptance criteria are `:tests` + `:http_probe`; `Kazi.Providers.BrowserTest`
  (T2.2) exercises the `:browser` provider's subprocess boundary against a canned
  verdict, never inside a loop; the vacuous-goal cases live in `Kazi.RuntimeTest`
  (T2.3) over plain repair goals. That isolation is correct for proving one
  feature, but it leaves the cross-cutting questions T2.4 exists to answer:

    * Does creation mode work as a WHOLE — does the `:browser` acceptance provider
      (T2.2), which has only ever been unit-tested, actually drive a real
      `Kazi.Runtime`/`Kazi.Loop` create goal to `:converged` when scripted to fail
      then pass (UC-012)? It is a LIVE kind (deploy-gated), so this also proves the
      live gate holds for a browser criterion exactly as it does for http_probe.
    * Does the vacuous-goal guard (T2.3) fire in the CREATION context — is a
      create goal whose acceptance criteria ALL already pass at t0 rejected
      `{:error, :vacuous_goal}`, so kazi does not "build nothing and declare
      success" (UC-010, Risk R3)?
    * Do the pieces INTERACT correctly — a create goal carrying BOTH an
      `:http_probe` and a `:browser` acceptance criterion converges only after the
      whole acceptance vector (across both live kinds) holds; and the vacuous guard
      composes with a browser acceptance criterion.

  This module answers them. It substitutes nothing in `lib/` (the zero-stub policy
  is for `lib/` only): exactly like `Kazi.CreationLoopTest` and `Kazi.FullLoopTest`
  it points only the seams the real modules already expose at hermetic local
  doubles — the harness binary (`adapter_opts: [command: stub]`) is the coding
  agent that "builds the feature"; the integrate action's `:integrator` is a real
  local rebase-merge into a bare origin (no GitHub); the deploy action's
  `:deploy_cmd` is a stub emulating `gcloud run deploy` (no gcloud); the
  `:browser` provider's runner is a local shell stub mirroring the EXACT
  subprocess contract of the real Node Playwright runner (and of the shared
  `test/support/stub_playwright.sh`), but DRIVEN BY A STATE FILE so it can be
  "scripted to fail then pass" — the shared static stub cannot flip its verdict
  mid-run because its env is fixed at predicate-build time; and the `:http_probe`
  criterion is a REAL request against a local stdlib `:inets` server. No Go, no
  external network, no real browser.

  The local doubles are defined inline (not shared with the sibling Tier-2 test
  files) because this project does not add `test/support` to `elixirc_paths`, so a
  test cannot rely on a sibling test file's helper module being compiled — the
  existing Tier-2 tests inline their helpers for the same reason.
  """
  # Real git + real local HTTP + real subprocess + the shared SQLite Sandbox
  # connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}

  @moduletag :tmp_dir

  setup do
    # The runtime persists each iteration through Kazi.ReadModel on the loop's own
    # process; share this checked-out Sandbox connection so the loop's writes land
    # where the test reads (mirrors Kazi.FullLoopTest / Kazi.CreationLoopTest).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # 1. Creation via acceptance predicates (UC-010) — the whole-system creation
  #    loop driven by a FAILING http_probe acceptance criterion that the build
  #    flips to pass. (CreationLoopTest proves T2.1 in isolation; this re-proves
  #    the consolidated path is healthy as the entry point of the suite.)
  # ===========================================================================

  describe "creation mode converges from a failing http_probe acceptance criterion (UC-010)" do
    test "a create goal authored as failing acceptance criteria is built to converged",
         %{tmp_dir: tmp_dir} do
      goal_id = "slice2-create-http"

      # A workspace whose feature does NOT exist yet: the marker is "absent", so
      # the CODE acceptance predicate (`grep -q '^built$' feature.txt`) FAILS at t0
      # — the failing work-list item that drives the agent to BUILD the feature.
      %{work: work, bare: bare} = setup_feature_repo(tmp_dir, marker: "absent")

      # The LIVE acceptance criterion: a REAL request against a local server whose
      # body starts "absent" so the http_probe FAILS at t0 and only serves the
      # feature payload ("widgets") once the deploy stub ships the built feature.
      {server, url, body_file} = start_http_server("absent")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      # The harness stub IS the coding agent: it "builds the feature" by writing
      # the marker the code acceptance predicate checks, flipping it red → green.
      harness_stub = write_harness_stub(tmp_dir, marker: "built")

      # The deploy stub ships the built feature so the deployed endpoint serves the
      # feature payload — the live acceptance criterion passes only against it.
      deploy_stub = write_http_deploy_stub(tmp_dir, url: url, body_file: body_file)

      integrator = local_integrator(bare, self(), pr: 24)

      goal =
        Goal.new(goal_id,
          mode: :create,
          predicates: [
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            Predicate.new(:widgets_live, :http_probe,
              acceptance?: true,
              config: %{url: url, expect_status: 200, expect_body: "widgets", body_match: :exact}
            )
          ],
          scope: Scope.new(workspace: work)
        )

      assert Goal.create?(goal)
      assert goal |> Goal.acceptance_predicates() |> length() == 2

      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: deploy_params(work, "slice2-create-http"),
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # Converged via the full build sequence: dispatch (BUILD) → integrate (land)
      # → deploy (ship) → converge once the live acceptance criterion holds.
      assert result.outcome == :converged
      assert result.actions == [:dispatch_agent, :integrate, :deploy]

      # The harness REALLY built the feature marker in the workspace.
      assert File.read!(Path.join(work, "feature.txt")) |> String.trim() == "built"
      # The integrate action's real local git path landed it on origin.
      assert_received {:integrated, _branch, "main"}
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "feature.txt"

      iterations = ReadModel.list_iterations(goal_id)
      assert length(iterations) == result.iterations

      # Both acceptance criteria FAILED at t0 (the feature did not exist).
      first = iterations |> List.first() |> ReadModel.to_predicate_vector()
      refute pass?(first, "feature_built")
      refute pass?(first, "widgets_live")

      # The live gate held: a state where the built code acceptance passed but the
      # live acceptance had not yet flipped — and never converged there.
      assert_live_gate(iterations, "feature_built", "widgets_live")

      last = List.last(iterations)
      assert last.converged
      refute Enum.any?(Enum.drop(iterations, -1), & &1.converged)
      final = ReadModel.to_predicate_vector(last)
      assert PredicateVector.satisfied?(final)
    end
  end

  # ===========================================================================
  # 2. Browser acceptance predicate (UC-012) — the cross-cutting headline. The
  #    :browser provider (T2.2) has only ever been unit-tested; here it drives a
  #    REAL create-mode loop. Its Playwright Port (the stub) is scripted to FAIL
  #    then PASS so kazi must build + ship before the browser criterion converges.
  # ===========================================================================

  describe "creation mode converges from a failing browser acceptance criterion (UC-012)" do
    test "a create goal whose acceptance criterion is a :browser predicate is driven to converged",
         %{tmp_dir: tmp_dir} do
      goal_id = "slice2-create-browser"

      %{work: work, bare: bare} = setup_feature_repo(tmp_dir, marker: "absent")

      # The browser verdict is driven by a mutable state file: while it reads
      # "down" the stub emits a FAIL verdict (the UI does not render the feature
      # yet); once the deploy stub flips it to "up" the stub emits a PASS verdict.
      # This is the Playwright Port "scripted to fail then pass" over the SAME
      # subprocess contract the real runner uses — no real browser.
      ui_state = Path.join(tmp_dir, "ui_state.txt")
      File.write!(ui_state, "down")

      # The harness builds the feature (code acceptance) so the loop progresses
      # past dispatch into integrate/deploy — where the browser criterion flips.
      harness_stub = write_harness_stub(tmp_dir, marker: "built")
      # The deploy stub "ships" the UI: it flips the browser state file to "up".
      deploy_stub = write_browser_deploy_stub(tmp_dir, ui_state: ui_state)
      # The Playwright stub wrapper: emits pass/fail JSON based on the state file.
      verdict_stub = write_browser_verdict_stub(tmp_dir, ui_state: ui_state)

      integrator = local_integrator(bare, self(), pr: 25)

      goal =
        Goal.new(goal_id,
          mode: :create,
          predicates: [
            # CODE acceptance: the new feature's failing build check — drives the
            # agent so the loop reaches integrate/deploy (the browser is live).
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            # BROWSER acceptance criterion (UC-012): a real subprocess verdict that
            # FAILS at t0 (UI absent) and PASSES once built + deployed.
            Predicate.new(:ui_renders, :browser,
              acceptance?: true,
              config: %{
                url: "https://app.example.test/",
                cmd: verdict_stub,
                args: [],
                assertions: [%{type: "text", selector: "h1", contains: "Widgets"}]
              }
            )
          ],
          scope: Scope.new(workspace: work)
        )

      assert Goal.create?(goal)

      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: deploy_params(work, "slice2-create-browser"),
                 reobserve_interval_ms: 5,
                 await_timeout: 15_000
               )

      # Converged through the full build sequence, gated on the BROWSER criterion.
      assert result.outcome == :converged
      assert result.actions == [:dispatch_agent, :integrate, :deploy]
      assert File.read!(ui_state) |> String.trim() == "up"

      iterations = ReadModel.list_iterations(goal_id)

      # The browser acceptance criterion FAILED at t0 (the UI did not exist).
      first = iterations |> List.first() |> ReadModel.to_predicate_vector()
      refute pass?(first, "ui_renders")

      # The live (browser) gate held: an observed state where the built code
      # acceptance passed but the browser criterion had not yet flipped — and the
      # loop did NOT converge there. Proves the :browser kind is deploy-gated.
      assert_live_gate(iterations, "feature_built", "ui_renders")

      last = List.last(iterations)
      assert last.converged
      final = ReadModel.to_predicate_vector(last)
      assert pass?(final, "feature_built")
      assert pass?(final, "ui_renders")
    end
  end

  # ===========================================================================
  # 3. Vacuous-goal guard in the creation context (UC-010, R3) — a create goal
  #    whose acceptance criteria ALL pass at t0 is rejected; kazi does not "build
  #    nothing and declare success". (RuntimeTest proves T2.3 over repair goals;
  #    this pins it for CREATE mode specifically.)
  # ===========================================================================

  describe "the vacuous-goal guard rejects an all-pass-at-t0 create goal (UC-010, R3)" do
    test "a create goal whose acceptance criteria already all pass at t0 is :vacuous_goal",
         %{tmp_dir: tmp_dir} do
      goal_id = "slice2-vacuous-create"

      # The "feature" already exists: the marker is "built" at t0, so the code
      # acceptance predicate PASSES before kazi does anything.
      %{work: work} = setup_feature_repo(tmp_dir, marker: "built")

      # The live acceptance criterion already serves the feature payload at t0, so
      # the http_probe PASSES too. The WHOLE acceptance vector is satisfied at t0.
      {server, url, _body_file} = start_http_server("widgets")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      goal =
        Goal.new(goal_id,
          mode: :create,
          predicates: [
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            Predicate.new(:widgets_live, :http_probe,
              acceptance?: true,
              config: %{url: url, expect_status: 200, expect_body: "widgets", body_match: :exact}
            )
          ],
          scope: Scope.new(workspace: work)
        )

      assert Goal.create?(goal)

      # Rejected before the loop starts — building and "verifying" nothing is not
      # a converged creation (R3). A harness/integrator/deploy that MUST NOT run is
      # passed so a regression that started the loop would shell out and fail loud.
      assert {:error, :vacuous_goal} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: must_not_run_stub(tmp_dir)],
                 await_timeout: 5_000
               )

      # Nothing was persisted as an iteration — the loop never started.
      assert ReadModel.list_iterations(goal_id) == []
    end
  end

  # ===========================================================================
  # 4. Interactions / edge — the pieces TOGETHER. (a) a create goal carrying BOTH
  #    an http_probe AND a browser acceptance criterion converges only after the
  #    whole cross-kind acceptance vector holds; (b) the vacuous guard composes
  #    with a browser acceptance criterion (all-pass-at-t0 over the browser kind
  #    is still rejected).
  # ===========================================================================

  describe "interactions: http_probe + browser acceptance criteria together (UC-010, UC-012)" do
    test "a create goal with BOTH a http_probe and a browser acceptance criterion converges only after both flip",
         %{tmp_dir: tmp_dir} do
      goal_id = "slice2-create-mixed"

      %{work: work, bare: bare} = setup_feature_repo(tmp_dir, marker: "absent")

      {server, url, body_file} = start_http_server("absent")
      on_exit(fn -> :inets.stop(:httpd, server) end)

      ui_state = Path.join(tmp_dir, "mixed_ui_state.txt")
      File.write!(ui_state, "down")

      harness_stub = write_harness_stub(tmp_dir, marker: "built")
      verdict_stub = write_browser_verdict_stub(tmp_dir, ui_state: ui_state)
      # ONE deploy stub ships BOTH live surfaces: it flips the http body AND the
      # browser state file in a single deploy, so the two live acceptance criteria
      # can only pass together against the built-and-deployed service.
      deploy_stub =
        write_mixed_deploy_stub(tmp_dir, url: url, body_file: body_file, ui_state: ui_state)

      integrator = local_integrator(bare, self(), pr: 26)

      goal =
        Goal.new(goal_id,
          mode: :create,
          predicates: [
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            Predicate.new(:widgets_live, :http_probe,
              acceptance?: true,
              config: %{url: url, expect_status: 200, expect_body: "widgets", body_match: :exact}
            ),
            Predicate.new(:ui_renders, :browser,
              acceptance?: true,
              config: %{
                url: "https://app.example.test/",
                cmd: verdict_stub,
                args: [],
                assertions: [%{type: "text", selector: "h1", contains: "Widgets"}]
              }
            )
          ],
          scope: Scope.new(workspace: work)
        )

      assert goal |> Goal.acceptance_predicates() |> length() == 3

      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: harness_stub],
                 integrator: integrator,
                 deploy_cmd: deploy_stub,
                 deploy_params: deploy_params(work, "slice2-create-mixed"),
                 reobserve_interval_ms: 5,
                 await_timeout: 20_000
               )

      assert result.outcome == :converged
      assert result.actions == [:dispatch_agent, :integrate, :deploy]
      assert File.read!(ui_state) |> String.trim() == "up"

      iterations = ReadModel.list_iterations(goal_id)

      # All three acceptance criteria FAILED at t0.
      first = iterations |> List.first() |> ReadModel.to_predicate_vector()
      refute pass?(first, "feature_built")
      refute pass?(first, "widgets_live")
      refute pass?(first, "ui_renders")

      # The cross-kind live gate: in EVERY observed state where the code acceptance
      # was green but EITHER live criterion was still red, the loop did NOT
      # converge. Convergence required the WHOLE acceptance vector across both
      # live kinds (http_probe AND browser) to hold.
      code_green_some_live_red =
        Enum.filter(iterations, fn it ->
          v = ReadModel.to_predicate_vector(it)
          pass?(v, "feature_built") and not (pass?(v, "widgets_live") and pass?(v, "ui_renders"))
        end)

      assert code_green_some_live_red != [],
             "expected an observation where the built code acceptance passed but at least one " <>
               "live (http_probe / browser) acceptance criterion had not yet flipped"

      refute Enum.any?(code_green_some_live_red, & &1.converged),
             "the create goal converged while a live acceptance criterion was still failing"

      last = List.last(iterations)
      assert last.converged
      final = ReadModel.to_predicate_vector(last)
      assert pass?(final, "feature_built")
      assert pass?(final, "widgets_live")
      assert pass?(final, "ui_renders")
    end

    test "the vacuous guard composes with a browser acceptance criterion (all-pass-at-t0 → :vacuous_goal)",
         %{tmp_dir: tmp_dir} do
      goal_id = "slice2-vacuous-browser"

      %{work: work} = setup_feature_repo(tmp_dir, marker: "built")

      # The browser verdict reads a state file that is ALREADY "up" at t0, so the
      # browser acceptance criterion PASSES at t0. With the code acceptance also
      # green (marker "built"), the WHOLE acceptance vector is satisfied at t0 →
      # vacuous, even though one criterion is the live :browser kind.
      ui_state = Path.join(tmp_dir, "vac_ui_state.txt")
      File.write!(ui_state, "up")
      verdict_stub = write_browser_verdict_stub(tmp_dir, ui_state: ui_state)

      goal =
        Goal.new(goal_id,
          mode: :create,
          predicates: [
            Predicate.new(:feature_built, :tests,
              acceptance?: true,
              config: %{cmd: "sh", args: ["-c", "grep -q '^built$' feature.txt"]}
            ),
            Predicate.new(:ui_renders, :browser,
              acceptance?: true,
              config: %{
                url: "https://app.example.test/",
                cmd: verdict_stub,
                args: [],
                assertions: [%{type: "text", selector: "h1", contains: "Widgets"}]
              }
            )
          ],
          scope: Scope.new(workspace: work)
        )

      assert {:error, :vacuous_goal} =
               Runtime.run(goal,
                 workspace: work,
                 adapter_opts: [command: must_not_run_stub(tmp_dir)],
                 await_timeout: 5_000
               )

      assert ReadModel.list_iterations(goal_id) == []
    end
  end

  # ===========================================================================
  # Helpers — local doubles (NOT lib/ stubs; the zero-stub policy is lib/ only).
  # They are real external programs / git scaffolding the real modules drive over
  # their existing injectable seams (mirrors CreationLoopTest / FullLoopTest).
  # ===========================================================================

  # A bare "origin" + working clone whose feature marker `feature.txt` starts at
  # `opts[:marker]`. "absent" = the feature does not exist yet (creation shape);
  # "built" = the feature already exists (for the vacuous-at-t0 cases).
  defp setup_feature_repo(tmp_dir, opts) do
    marker = Keyword.fetch!(opts, :marker)
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git_config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
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

  # The harness stub: the coding agent that "builds the feature" by writing the
  # marker the code acceptance predicate checks into the workspace (red → green).
  defp write_harness_stub(tmp_dir, opts) do
    marker = Keyword.fetch!(opts, :marker)
    path = Path.join(tmp_dir, "stub_harness_#{System.unique_integer([:positive])}.sh")

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

  # A harness/deploy stub that MUST NOT run (vacuous cases): if the loop ever
  # started and dispatched it, it exits non-zero so the regression fails loud
  # rather than passing silently.
  defp must_not_run_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_must_not_run_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "FATAL: a vacuous goal started the loop and dispatched the harness" 1>&2
    exit 17
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A minimal local HTTP server (stdlib :inets/:httpd) answering GET /healthz with
  # the current contents of its body file — so the http_probe makes a REAL request
  # whose result tracks the (mutable) file. Returns {pid, url, body_file}.
  defp start_http_server(body) do
    docroot =
      Path.join(System.tmp_dir!(), "kazi_t24_httpd_#{System.unique_integer([:positive])}")

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-t24-test",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1",
        mime_types: [{~c"healthz", ~c"text/plain"}, {~c"", ~c"text/plain"}]
      )

    info = :httpd.info(pid)
    port = info[:port]
    {pid, "http://127.0.0.1:#{port}/healthz", body_file}
  end

  # The Playwright runner STUB this suite drives over System.cmd. It mirrors the
  # real runner's contract (read the JSON payload as the last positional arg,
  # print one JSON verdict to stdout) but its verdict is DRIVEN BY A STATE FILE:
  # while the file reads "up" it prints a "pass" verdict; otherwise a "fail"
  # verdict with expected-vs-found evidence. The deploy stub flips that file, so
  # the browser criterion is genuinely build-and-deploy gated. No real browser.
  defp write_browser_verdict_stub(tmp_dir, opts) do
    ui_state = Keyword.fetch!(opts, :ui_state)
    path = Path.join(tmp_dir, "stub_browser_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    # The Playwright Port "scripted to fail then pass" by reading a state file.
    state=$(cat "#{ui_state}" 2>/dev/null)
    if [ "$state" = "up" ]; then
      printf '{"status":"pass","assertions":[{"type":"text","selector":"h1","ok":true,"expected":"Widgets","found":"Widgets"}],"screenshot":null,"error":null}\\n'
    else
      printf '{"status":"fail","assertions":[{"type":"text","selector":"h1","ok":false,"expected":"Widgets","found":"Error 404"}],"screenshot":null,"error":null}\\n'
    fi
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Stand-in for `gcloud run deploy` (http_probe surface): ship the built feature
  # so the deployed endpoint serves the payload ("widgets").
  defp write_http_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    body_file = Keyword.fetch!(opts, :body_file)
    path = Path.join(tmp_dir, "stub_deploy_http_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying the new feature from source..."
    printf 'widgets' > "#{body_file}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Stand-in for `gcloud run deploy` (browser surface): ship the UI by flipping
  # the browser state file to "up", so the Playwright stub's verdict flips to pass.
  defp write_browser_deploy_stub(tmp_dir, opts) do
    ui_state = Keyword.fetch!(opts, :ui_state)
    path = Path.join(tmp_dir, "stub_deploy_browser_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying the UI from source..."
    printf 'up' > "#{ui_state}"
    echo "https://app.example.test/"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Stand-in for `gcloud run deploy` shipping BOTH live surfaces at once: flip the
  # http body AND the browser state file in one deploy.
  defp write_mixed_deploy_stub(tmp_dir, opts) do
    url = Keyword.fetch!(opts, :url)
    body_file = Keyword.fetch!(opts, :body_file)
    ui_state = Keyword.fetch!(opts, :ui_state)
    path = Path.join(tmp_dir, "stub_deploy_mixed_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "Building and deploying the feature (API + UI) from source..."
    printf 'widgets' > "#{body_file}"
    printf 'up' > "#{ui_state}"
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A real local rebase-merge integrator (stands in for `gh pr merge --rebase`) —
  # no GitHub. Reports back to `pid` so a test can assert it ran.
  defp local_integrator(bare, pid, opts) do
    pr = Keyword.fetch!(opts, :pr)

    fn request, _opts ->
      send(pid, {:integrated, request.branch, request.base})
      merge_commit = local_rebase_merge(bare, request.branch, request.base)
      {:ok, %{pr: pr, merge_commit: merge_commit}}
    end
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp = Path.join(System.tmp_dir!(), "t24-merge-#{System.unique_integer([:positive])}")
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

  defp deploy_params(work, service) do
    %{service: service, project: "kazi-test", region: "us-central1", source: work}
  end

  # The live-gate assertion shared by the convergence scenarios: there MUST be an
  # observed state where the code acceptance (`code_id`) passed but the live
  # acceptance (`live_id`) had not yet flipped, and in NO such state did the loop
  # converge — convergence is gated on the live criterion, not on code-green.
  defp assert_live_gate(iterations, code_id, live_id) do
    code_green_live_red =
      Enum.filter(iterations, fn it ->
        v = ReadModel.to_predicate_vector(it)
        pass?(v, code_id) and not pass?(v, live_id)
      end)

    assert code_green_live_red != [],
           "expected an observation where the built code acceptance passed but the live " <>
             "acceptance (#{live_id}) had not yet flipped (build → integrate → deploy gate)"

    refute Enum.any?(code_green_live_red, & &1.converged),
           "the create goal converged while its live acceptance criterion (#{live_id}) was failing"
  end

  defp pass?(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      nil -> false
      %{status: status} -> status == :pass
    end
  end
end
