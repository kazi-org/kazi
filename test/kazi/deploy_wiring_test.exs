defmodule Kazi.DeployWiringTest do
  @moduledoc """
  Tier 2 — the consolidated end-to-end test for wiring the deepened deploy
  (T3.3a multi-env, T3.3b rollback, T3.3c release tagging) through
  `Kazi.Runtime` and the `Kazi.CLI` (T3.3d, UC-015).

  It drives the REAL component wiring — the real providers, the real
  `Kazi.Actions.Deploy`, real SQLite persistence, and (for the CLI assertion) the
  real loader → `Kazi.CLI.run/2` → runtime path — against a TEMP target. It
  substitutes nothing in `lib/`; it only points the seams those modules already
  expose at local stubs:

    * the deploy action's `:deploy_cmd` seam — a stub emulating `gcloud run
      deploy` that records its args and prints the live URL;
    * the deploy action's `:tag_cmd` seam — a stub emulating `git tag` that
      records the tag created;
    * the integrate action's `:integrator` seam — a real local rebase-merge.

  NO real gcloud/git-remote/network: every external command is a hermetic stub.

  It proves the T3.3d acceptance end-to-end:

    1. **multi-env selection** — a goal run with `deploy_params: %{env: :prod,
       envs: %{...}}` invokes the deployer with the *prod* target's
       service/project/region (and never the staging target);
    2. **release tagging surfaced** — a successful deploy produces a release tag
       (via the injected tagger), and that release ref is surfaced in the run
       outcome (`result.release_ref`) AND recorded in the read-model
       (`Kazi.ReadModel.release_refs/1`);
    3. **CLI level** — the same path through `Kazi.CLI.run/2` exits 0, prints the
       release ref, and the operator's `--env` selection reaches the deployer;
    4. **rollback** — `Kazi.Actions.Deploy.execute/2` for a `:rollback` action,
       driven with the env-aware params the runtime/CLI thread, reverts to and
       returns the prior revision via the same injectable seam.
  """
  # Real git + real HTTP + the shared SQLite Sandbox connection: serial.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Action, Goal, Predicate, ReadModel, Repo, Runtime, Scope}
  alias Kazi.Actions.Deploy

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Multi-env selection + release tagging surfaced through Kazi.Runtime
  # ===========================================================================

  test "runtime: env :prod selects the prod target, surfaces the release ref in the outcome + read-model",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    harness_stub = write_harness_stub(tmp_dir)
    args_file = Path.join(tmp_dir, "deploy_args.txt")
    deploy_stub = write_recording_deploy_stub(tmp_dir, args_file, url, body_file)
    tag_args_file = Path.join(tmp_dir, "tag_args.txt")
    tagger = write_tagger_stub(tmp_dir, tag_args_file)

    integrator = fn request, _opts ->
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    goal =
      Goal.new("deploy-wiring-prod",
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
               adapter_opts: [command: harness_stub],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               # T3.3d: the deepened deploy is driven through :deploy_params —
               # env selection (T3.3a) + an injected tagger (T3.3c).
               deploy_params: %{
                 env: :prod,
                 tag_cmd: tagger,
                 release_ref: "release-kazi-prod-v1",
                 source: work,
                 envs: %{
                   staging: %{
                     service: "kazi-staging",
                     project: "proj-staging",
                     region: "us-central1"
                   },
                   prod: %{
                     service: "kazi-prod",
                     project: "proj-prod",
                     region: "europe-west1"
                   }
                 }
               },
               reobserve_interval_ms: 5,
               await_timeout: 15_000
             )

    assert result.outcome == :converged

    # T3.3d: the release ref of the deployed artifact is surfaced in the outcome.
    assert result.release_ref == "release-kazi-prod-v1"

    # T3.3a multi-env: the deployer was invoked with the PROD target, never staging.
    deploy_args = File.read!(args_file) |> String.split("\n", trim: true)
    assert "kazi-prod" in deploy_args
    assert "proj-prod" in deploy_args
    assert "europe-west1" in deploy_args
    refute "kazi-staging" in deploy_args
    refute "proj-staging" in deploy_args

    # T3.3c: the tagger created the release tag.
    tag_args = File.read!(tag_args_file) |> String.split("\n", trim: true)
    assert tag_args == ["tag", "release-kazi-prod-v1"]

    # T3.3d: the release ref is recorded in the read-model and queryable.
    refs = ReadModel.release_refs("deploy-wiring-prod")
    assert {_index, "release-kazi-prod-v1"} = List.last(refs)
  end

  test "runtime: a run with no deploy env still converges and surfaces a derived release ref",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    harness_stub = write_harness_stub(tmp_dir)
    args_file = Path.join(tmp_dir, "deploy_args.txt")
    deploy_stub = write_recording_deploy_stub(tmp_dir, args_file, url, body_file)
    tag_args_file = Path.join(tmp_dir, "tag_args.txt")
    tagger = write_tagger_stub(tmp_dir, tag_args_file)

    integrator = fn request, _opts ->
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    goal =
      Goal.new("deploy-wiring-derived",
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
               adapter_opts: [command: harness_stub],
               integrator: integrator,
               deploy_cmd: deploy_stub,
               # No env/envs: back-compat single-target deploy. No explicit
               # release_ref, so the deploy derives a timestamped one (T3.3c).
               deploy_params: %{
                 service: "kazi-single",
                 project: "proj-single",
                 region: "us-central1",
                 source: work,
                 tag_cmd: tagger
               },
               reobserve_interval_ms: 5,
               await_timeout: 15_000
             )

    assert result.outcome == :converged
    # A derived release ref names the single-target service (T3.3c default).
    assert result.release_ref =~ ~r/^release-kazi-single-\d+$/

    refs = ReadModel.release_refs("deploy-wiring-derived")
    assert {_index, ref} = List.last(refs)
    assert ref == result.release_ref
  end

  # ===========================================================================
  # CLI-level: --env reaches the deployer, the release ref is printed (T3.3d)
  # ===========================================================================

  test "CLI: --env selects the deploy target, exits 0, prints the surfaced release ref",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    {server, url, body_file} = start_http_server("down")
    on_exit(fn -> :inets.stop(:httpd, server) end)

    goal_file = write_goal_file(tmp_dir, work, url)
    harness_stub = write_harness_stub(tmp_dir)
    args_file = Path.join(tmp_dir, "cli_deploy_args.txt")
    deploy_stub = write_recording_deploy_stub(tmp_dir, args_file, url, body_file)
    tag_args_file = Path.join(tmp_dir, "cli_tag_args.txt")
    tagger = write_tagger_stub(tmp_dir, tag_args_file)

    integrator = fn request, _opts ->
      {:ok, %{pr: 7, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    # The runtime_opts carry the seams + the per-env targets; the operator's
    # `--env staging` selection is threaded by the CLI into deploy_params, so the
    # STAGING target must be the one the deployer is invoked with.
    runtime_opts = [
      adapter_opts: [command: harness_stub],
      integrator: integrator,
      deploy_cmd: deploy_stub,
      deploy_params: %{
        source: work,
        tag_cmd: tagger,
        release_ref: "release-cli-staging-v1",
        envs: %{
          staging: %{service: "kazi-staging", project: "proj-staging", region: "us-central1"},
          prod: %{service: "kazi-prod", project: "proj-prod", region: "europe-west1"}
        }
      },
      reobserve_interval_ms: 5,
      await_timeout: 15_000
    ]

    {code, out} =
      with_io(fn ->
        Kazi.CLI.run(
          [
            "apply",
            goal_file,
            "--workspace",
            work,
            "--allow-primary-workspace",
            "--env",
            "staging"
          ],
          runtime_opts
        )
      end)

    assert code == 0
    assert out =~ "CONVERGED"
    # T3.3d: the release ref is printed in the CLI report.
    assert out =~ "release:"
    assert out =~ "release-cli-staging-v1"

    # The operator's --env staging selection reached the deployer.
    deploy_args = File.read!(args_file) |> String.split("\n", trim: true)
    assert "kazi-staging" in deploy_args
    assert "proj-staging" in deploy_args
    refute "kazi-prod" in deploy_args
  end

  test "CLI: parse/1 accepts --env and carries it in the run opts" do
    assert {:run, "goal.toml", opts} =
             Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--env", "prod"])

    assert opts[:workspace] == "/tmp/ws"
    assert opts[:env] == "prod"

    # --env is optional: omitting it leaves env nil (back-compat single-target).
    assert {:run, "goal.toml", base_opts} = Kazi.CLI.parse(["apply", "goal.toml"])
    assert base_opts[:env] == nil
  end

  # ===========================================================================
  # Rollback through the env-aware params the runtime/CLI thread (T3.3b/T3.3d)
  # ===========================================================================

  test "rollback: env-aware params revert to and return the prior revision via the injected seam",
       %{tmp_dir: tmp_dir} do
    args_file = Path.join(tmp_dir, "rollback_args.txt")
    stub = write_rollback_stub(tmp_dir, args_file)

    # The same env-aware deploy params shape the runtime/CLI thread, now driving
    # a :rollback action (T3.3b) directly through the deploy module.
    action =
      Action.new(:rollback,
        params: %{
          cmd: stub,
          env: :prod,
          envs: %{
            prod: %{service: "kazi-prod", project: "proj-prod", region: "europe-west1"}
          }
        }
      )

    assert {:ok, result} = Deploy.execute(action, %{})

    # Reverted to the prior revision (the rollback ref), against the prod target.
    assert result.service == "kazi-prod"
    assert result.prior_ref == "kazi-prod-00041-prior"
    assert result.rolled_back_to == "kazi-prod-00041-prior"

    args = File.read!(args_file) |> String.split("\n", trim: true)
    assert "revisions" in args
    assert "update-traffic" in args
    assert "kazi-prod-00041-prior=100" in args
    assert "kazi-prod" in args
    assert "europe-west1" in args
  end

  # ===========================================================================
  # fixtures
  # ===========================================================================

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
    path = Path.join(tmp_dir, "stub_harness_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A deploy stub that RECORDS its args (so the test can assert the env-selected
  # target reached the deployer), flips the live body to "ok", and prints the URL.
  defp write_recording_deploy_stub(tmp_dir, args_file, url, body_file) do
    path = Path.join(tmp_dir, "stub_deploy_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    for a in "$@"; do echo "$a" >> "#{args_file}"; done
    printf 'ok' > "#{body_file}"
    echo "Building and deploying from source..."
    echo "#{url}"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A tagger stub emulating `git tag <ref>`: records the args, exits 0.
  defp write_tagger_stub(tmp_dir, tag_args_file) do
    path = Path.join(tmp_dir, "stub_tagger_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    for a in "$@"; do echo "$a" >> "#{tag_args_file}"; done
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A rollback stub emulating the two `gcloud run` calls: `revisions list` prints
  # current then prior (newest-first); `services update-traffic` prints the URL.
  defp write_rollback_stub(tmp_dir, args_file) do
    path = Path.join(tmp_dir, "stub_rollback_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    for a in "$@"; do echo "$a" >> "#{args_file}"; done
    case "$2" in
      revisions)
        echo "kazi-prod-00042-current"
        echo "kazi-prod-00041-prior"
        ;;
      services)
        echo "https://kazi-prod-uc.a.run.app"
        ;;
    esac
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_goal_file(tmp_dir, work, url) do
    path = Path.join(tmp_dir, "goal_#{System.unique_integer([:positive])}.toml")

    File.write!(path, """
    id = "deploy-wiring-cli"
    name = "Deploy wiring CLI end-to-end"

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

  defp start_http_server(body) do
    docroot =
      Path.join(
        System.tmp_dir!(),
        "kazi_deploywiring_httpd_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(docroot)
    body_file = Path.join(docroot, "healthz")
    File.write!(body_file, body)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi-deploywiring-test",
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
    tmp = Path.join(System.tmp_dir!(), "dw-merge-#{System.unique_integer([:positive])}")
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
