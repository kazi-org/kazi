defmodule Kazi.FreshBaseGuardTest do
  @moduledoc """
  T50.8 (ADR-0065 decision 5): `--base <ref>` selects the task worktree's base;
  a stale default base warns loudly; kazi NEVER fetches to freshen a base.

  Contract:

    1. `--base origin/main` bases the worktree on THAT ref, not the checkout's
       HEAD — the worktree's HEAD SHA equals the fixture origin/main SHA;
    2. a stale default base (checkout behind its upstream) warns on stderr
       naming BOTH SHAs; the same run with an explicit `--base` emits NO
       warning (R-E50-4: intent stated, no nag);
    3. no git invocation on the worktree path is ever a fetch/pull — every
       staleness read hits the local ref store only;
    4. `--in-place` + `--base` together are rejected (contradictory: there is
       no worktree to base);
    5. an unresolvable `--base` ref fails with an error NAMING the ref, before
       any worktree is created;
    6. default behavior unchanged: no `--base`, base up to date -> no warning,
       worktree from HEAD.

  Hermetic, mirroring test/kazi/serial_worktree_indirection_test.exs: real
  fixture git repos under tmp with a FIXTURE REMOTE (a second local repo as
  origin), stub harnesses, no network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Scheduler.Worktree

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "--base origin/main bases the worktree on that ref, not the checkout's HEAD",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = repo_with_origin(tmp_dir)

    # Move the checkout's HEAD PAST origin/main with a local commit.
    File.write!(Path.join(work, "local.txt"), "local\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-qm", "local-only"], cd: work, stderr_to_stdout: true)

    origin_main_sha = sha(work, "origin/main")
    head_sha = sha(work, "HEAD")
    refute origin_main_sha == head_sha

    sha_file = Path.join(tmp_dir, "worktree-head-sha")
    goal_file = write_goal_file(tmp_dir, work)

    {_stderr, code} =
      capture_io_with_code(:stderr, fn ->
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work, "--base", "origin/main", "--json"],
            adapter_opts: [command: sha_recording_harness(tmp_dir, sha_file)],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
        |> elem(0)
      end)

    assert code == 0

    recorded = sha_file |> File.read!() |> String.trim()
    assert recorded == origin_main_sha, "the worktree must be based on the --base ref"
    refute recorded == head_sha
  end

  test "a stale default base warns on stderr naming both SHAs; --base silences it",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = stale_checkout(tmp_dir)

    base_sha = sha(work, "HEAD")
    upstream_sha = sha(work, "origin/main")
    refute base_sha == upstream_sha

    goal_file = write_goal_file(tmp_dir, work)

    {stderr, code} =
      capture_io_with_code(:stderr, fn ->
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work, "--json"],
            adapter_opts: [command: passing_harness(tmp_dir)],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
        |> elem(0)
      end)

    assert code == 0
    assert stderr =~ "warning:"
    assert stderr =~ "behind its locally-known upstream"
    assert stderr =~ base_sha, "the warning must name the base SHA"
    assert stderr =~ upstream_sha, "the warning must name the upstream tip SHA"
    assert stderr =~ "1 commit(s) behind"
    refute stderr =~ "fetching", "the warning is advisory; kazi never fetches"

    # The SAME stale checkout with an explicit --base states intent: NO warning.
    {stderr2, code2} =
      capture_io_with_code(:stderr, fn ->
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work, "--base", "main", "--json"],
            adapter_opts: [command: passing_harness(tmp_dir)],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
        |> elem(0)
      end)

    assert code2 == 0
    refute stderr2 =~ "behind its locally-known upstream"
  end

  test "no git call on the worktree path is ever a fetch/pull (stale base included)",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = stale_checkout(tmp_dir)
    base_dir = Path.join(tmp_dir, "wt-base")
    log = Path.join(tmp_dir, "git-argv.log")
    recording_git = recording_git(tmp_dir, log)

    # Default base on a STALE checkout: the staleness check runs its full read
    # path (upstream lookup, both rev-parses, the behind-count) AND the
    # worktree is created + removed — every git argv recorded. The warning
    # fires at wrap time, so wrap runs inside the capture.
    stderr =
      capture_io(:stderr, fn ->
        reconciler =
          Worktree.wrap(fn _partition, _path -> :converged end,
            repo: work,
            base_dir: base_dir,
            git_cmd: recording_git
          )

        assert reconciler.(%{key: "fresh"}) == :converged
      end)

    assert stderr =~ "behind its locally-known upstream"

    # An explicit base ref exercises the validation + creation path too.
    reconciler2 =
      Worktree.wrap(fn _partition, _path -> :converged end,
        repo: work,
        base_dir: base_dir,
        git_cmd: recording_git,
        base_ref: "origin/main"
      )

    assert reconciler2.(%{key: "pinned"}) == :converged

    recorded = File.read!(log)
    assert recorded =~ "worktree add", "sanity: the recorder saw the real git traffic"

    # Judge the git SUBCOMMAND (the first argv token) — the recorded worktree
    # paths themselves may contain arbitrary strings (this test's own tmp_dir
    # embeds "fetch-pull" from the test name).
    for line <- String.split(recorded, "\n", trim: true) do
      subcommand = line |> String.split(" ", trim: true) |> List.first()

      refute subcommand in ["fetch", "pull"],
             "the base guard must never fetch/pull, but recorded: #{line}"
    end
  end

  test "--in-place + --base together are rejected with an error naming both flags",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = repo_with_origin(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--in-place", "--base", "main", "--json"],
          adapter_opts: [command: never_called_harness(tmp_dir)]
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "--in-place"
    assert message =~ "--base"
    refute File.exists?(harness_called_marker(tmp_dir))
  end

  test "an unresolvable --base ref fails naming the ref, before any worktree is created",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = repo_with_origin(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--base", "no-such-ref", "--json"],
          adapter_opts: [command: never_called_harness(tmp_dir)]
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "no-such-ref", "the error must name the unresolvable ref"
    assert message =~ "never fetches"
    assert linked_worktrees(work) == [], "no worktree may be created for a bad base"
    refute File.exists?(harness_called_marker(tmp_dir))
  end

  test "default behavior unchanged: no --base, base up to date -> no warning, worktree from HEAD",
       %{tmp_dir: tmp_dir} do
    {_origin, work} = repo_with_origin(tmp_dir)
    head_sha = sha(work, "HEAD")

    sha_file = Path.join(tmp_dir, "worktree-head-sha")
    goal_file = write_goal_file(tmp_dir, work)

    {stderr, code} =
      capture_io_with_code(:stderr, fn ->
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work, "--json"],
            adapter_opts: [command: sha_recording_harness(tmp_dir, sha_file)],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)
        |> elem(0)
      end)

    assert code == 0
    refute stderr =~ "behind its locally-known upstream"

    assert sha_file |> File.read!() |> String.trim() == head_sha,
           "with no --base the worktree is created from the workspace's HEAD"

    assert linked_worktrees(work) == []
  end

  # --- fixtures -------------------------------------------------------------

  # A checkout whose `origin` is a second local fixture repo: origin gets two
  # commits, then a plain local `git clone` — which configures main's upstream
  # (origin/main) and origin/HEAD, all in the local ref store, no network.
  defp repo_with_origin(tmp_dir) do
    n = System.unique_integer([:positive])
    origin = Path.join(tmp_dir, "origin-#{n}")
    work = Path.join(tmp_dir, "checkout-#{n}")

    File.mkdir_p!(origin)
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch=main", origin])
    configure_git!(origin)
    File.write!(Path.join(origin, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: origin)
    {_, 0} = System.cmd("git", ["commit", "-qm", "one"], cd: origin, stderr_to_stdout: true)
    File.write!(Path.join(origin, "second.txt"), "second\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: origin)
    {_, 0} = System.cmd("git", ["commit", "-qm", "two"], cd: origin, stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["clone", "-q", origin, work], stderr_to_stdout: true)
    configure_git!(work)

    {origin, work}
  end

  # A checkout that is BEHIND its upstream as the local ref store already
  # knows it: reset the clone one commit back while origin/main stays at the
  # tip. No fetch needed anywhere — the staleness is locally known.
  defp stale_checkout(tmp_dir) do
    {origin, work} = repo_with_origin(tmp_dir)
    {_, 0} = System.cmd("git", ["reset", "-q", "--hard", "HEAD~1"], cd: work)
    {origin, work}
  end

  defp configure_git!(repo) do
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: repo)
  end

  defp sha(repo, ref) do
    {out, 0} = System.cmd("git", ["rev-parse", ref], cd: repo)
    String.trim(out)
  end

  # A predicate that FAILS at t0 (`test -f fixed.txt`) so the goal is never
  # vacuous — the serial_worktree_indirection_test fixture shape.
  defp write_goal_file(tmp_dir, workspace) do
    path = Path.join(tmp_dir, "fbg-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "fresh-base-fixture"
    name = "fresh base guard fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # Every LINKED worktree still registered against `repo` (excludes the
  # primary worktree line itself).
  defp linked_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&List.first(String.split(&1, "\n", trim: true)))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.reject(&(Path.expand(&1) == Path.expand(repo)))
  end

  # The recording :git_cmd seam: append every argv to `log`, then exec the real
  # git — so the test can assert NO recorded call is a fetch/pull.
  # The tmp_dir path embeds the test name (parens, quotes, commas), so every
  # path interpolated into a stub body MUST be double-quoted for `sh`.
  defp recording_git(tmp_dir, log) do
    write_stub(tmp_dir, "recording-git", ~s[echo "$@" >> "#{log}"\nexec git "$@"])
  end

  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", ~s[touch "#{harness_called_marker(tmp_dir)}"\nexit 0])
  end

  # Converges (writes fixed.txt in its own cwd — the worktree) and records the
  # worktree's HEAD SHA, so the test can assert WHICH ref it was based on.
  defp sha_recording_harness(tmp_dir, sha_file) do
    write_stub(
      tmp_dir,
      "sha-recording",
      ~s[git rev-parse HEAD > "#{sha_file}"\necho "the converged fix" > fixed.txt\nexit 0]
    )
  end

  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  # capture_io/2 returns only the captured output; thread the inner exit code
  # out alongside it.
  defp capture_io_with_code(device, fun) do
    holder = self()

    stderr =
      capture_io(device, fn ->
        send(holder, {:code, fun.()})
      end)

    assert_received {:code, code}
    {stderr, code}
  end
end
