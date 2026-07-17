defmodule Kazi.Bus.ClaimsFixtureTest do
  @moduledoc """
  T55.8 (ADR-0073 point 2): the claim-visibility reader against a REAL local
  bare git repo standing in for the shared remote -- not a mock. Proves the
  full boundary: two live `refs/claims/*` render with owner + age parsed from
  the real claim commit subjects; taking and releasing a claim appears and
  vanishes on the next read; and a genuinely unreachable remote degrades to one
  honest error inside the timeout.

  Daemon-independence is PINNED BY CONSTRUCTION: this file starts no daemon and
  `Kazi.Bus.Claims` makes no NATS/daemon call -- the claim path is pure git
  against the remote, so it works with the daemon absent.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.Claims

  setup do
    root = Path.join(System.tmp_dir!(), "kazi-claims-#{System.unique_integer([:positive])}")
    bare = Path.join(root, "remote.git")
    work = Path.join(root, "work")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    git!(work, ["config", "user.email", "fixture@example.test"])
    git!(work, ["config", "user.name", "fixture"])
    File.write!(Path.join(work, "README"), "seed\n")
    git!(work, ["add", "README"])
    git!(work, ["commit", "-m", "seed"])
    git!(work, ["push", "origin", "main"])

    %{work: work, bare: bare}
  end

  test "two live claims render with owner + host + age parsed from real commit subjects",
       %{work: work} do
    now = 2_000_000_000
    take_claim(work, "T55.8", "dev@sire.run", "build-box", now - 90)
    take_claim(work, "R-session-bus-doc", "other@example.test", "laptop", now - 3720)

    assert {:ok, claims} = Claims.read(cwd: work, remote: "origin", now: now)

    assert [r_doc, t558] = claims
    assert t558["task"] == "T55.8"
    assert t558["owner"] == "dev@sire.run"
    assert t558["host"] == "build-box"
    assert t558["age_s"] == 90

    assert r_doc["task"] == "R-session-bus-doc"
    assert r_doc["owner"] == "other@example.test"
    assert r_doc["age_s"] == 3720
  end

  test "taking then releasing a claim appears then vanishes on the next read -- no daemon",
       %{work: work} do
    now = 2_000_000_000

    assert {:ok, []} = Claims.read(cwd: work, remote: "origin", now: now)

    take_claim(work, "T99.1", "dev@example.test", "box", now - 10)
    assert {:ok, [%{"task" => "T99.1"}]} = Claims.read(cwd: work, remote: "origin", now: now)

    release_claim(work, "T99.1")
    assert {:ok, []} = Claims.read(cwd: work, remote: "origin", now: now)
  end

  test "a released claim is pruned even when a stale local namespace ref lingers",
       %{work: work} do
    now = 2_000_000_000
    take_claim(work, "T88.2", "dev@example.test", "box", now - 5)
    assert {:ok, [%{"task" => "T88.2"}]} = Claims.read(cwd: work, remote: "origin", now: now)

    # Release on the remote; the next fresh fetch must --prune it away rather
    # than presenting the still-cached local ref as live truth.
    release_claim(work, "T88.2")
    assert {:ok, []} = Claims.read(cwd: work, remote: "origin", now: now)
  end

  test "a genuinely unreachable remote degrades to :unreachable, never a stale render",
       %{work: work} do
    # A real git failure against an absent remote -- not a mock.
    assert {:error, :unreachable} =
             Claims.read(cwd: work, remote: Path.join(work, "no-such-remote.git"), now: 1)
  end

  test "an unroutable remote degrades within the short timeout", %{work: work} do
    started = System.monotonic_time(:millisecond)

    assert {:error, :unreachable} =
             Claims.read(
               cwd: work,
               remote: "git://nonexistent.invalid/repo.git",
               timeout_ms: 2_000,
               now: 1
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 20_000, "degraded in #{elapsed}ms -- must not hang unbounded"
  end

  # Mints a claim commit the SAME way the claim primitive does -- an unattached
  # commit-tree whose subject carries owner/host/stamp -- and pushes it to
  # refs/claims/<task> on origin. Committer date fixes the age the reader parses.
  defp take_claim(work, task, identity, host, committed_at) do
    stamp = "2026-07-16T09:00:00Z"
    date_env = "@#{committed_at} +0000"

    {sha, 0} =
      System.cmd(
        "git",
        [
          "-C",
          work,
          "commit-tree",
          "HEAD^{tree}",
          "-m",
          "claim #{task} by #{identity}@#{host} #{stamp}"
        ],
        env: [
          {"GIT_AUTHOR_NAME", "claim-bot"},
          {"GIT_AUTHOR_EMAIL", identity},
          {"GIT_COMMITTER_NAME", "claim-bot"},
          {"GIT_COMMITTER_EMAIL", identity},
          {"GIT_AUTHOR_DATE", date_env},
          {"GIT_COMMITTER_DATE", date_env}
        ]
      )

    sha = String.trim(sha)
    git!(work, ["push", "origin", "#{sha}:refs/claims/#{task}"])
  end

  defp release_claim(work, task),
    do: git!(work, ["push", "origin", ":refs/claims/#{task}"])

  defp git!(cwd, args) do
    {out, code} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end
end
