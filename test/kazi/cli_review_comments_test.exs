defmodule Kazi.CLIReviewCommentsTest do
  @moduledoc """
  TKE.6 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2): review-comment ingestion as a
  new grind input, read from the lane contract, never fetched by kazi.

  Consistent with "kazi never holds a GitHub credential" (decided design 3.2):
  kazi does not call `gh api`/`gh pr view` itself. Whoever already holds the
  credential and composes the resume dispatch writes the fetched unresolved
  review comments onto an optional `review_comments` array on the lane
  contract before kazi ever runs; kazi's job is read-and-render only -- fold
  that array into the next dispatch prompt as a new, clearly labeled section.

  HERMETIC: a real (throwaway) git repo per test, the same stub-harness/PATH-
  shim pattern `cli_resume_pr_test.exs`/`cli_integration_trailer_test.exs` use
  -- no network, no real `gh`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # GREEN: a contract's one review_comments entry shows up in the next
  # dispatch's assembled prompt, in its own labeled section.
  # ===========================================================================

  describe "a lane contract carrying one review_comments entry" do
    test "its text is rendered into the next dispatch prompt, in a labeled section",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      capture = Path.join(tmp_dir, "argv-capture.txt")

      contract =
        write_lane_contract(tmp_dir, work, [
          %{
            "path" => "lib/kazi/loop.ex",
            "line" => 42,
            "body" => "This branch never handles the empty-list case -- please add a test."
          }
        ])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: argv_capturing_harness(tmp_dir, capture)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _payload} = Jason.decode(String.trim(out))

      assert File.exists?(capture), "the stub harness must have been dispatched"
      prompt = File.read!(capture)

      assert prompt =~ "## Reviewer feedback (unresolved PR review comments)"
      assert prompt =~ "lib/kazi/loop.ex:42"
      assert prompt =~ "This branch never handles the empty-list case -- please add a test."
    end
  end

  # ===========================================================================
  # byte-identical default: an absent or empty review_comments omits the
  # section entirely.
  # ===========================================================================

  describe "no review_comments (absent, or a contract with an empty array)" do
    test "no lane contract at all: the prompt shape is unaffected", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      capture = Path.join(tmp_dir, "argv-capture-none.txt")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--json"
                   ],
                   adapter_opts: [command: argv_capturing_harness(tmp_dir, capture)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _payload} = Jason.decode(String.trim(out))
      refute File.read!(capture) =~ "Reviewer feedback"
    end

    test "a lane contract with an empty review_comments array: byte-identical prompt",
         %{tmp_dir: tmp_dir} do
      work_bare = git_repo_fixture(tmp_dir)
      goal_bare = write_goal_file(tmp_dir, work_bare)
      capture_bare = Path.join(tmp_dir, "argv-capture-bare.txt")

      out_bare =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_bare,
                     "--workspace",
                     work_bare,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--json"
                   ],
                   adapter_opts: [command: argv_capturing_harness(tmp_dir, capture_bare)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _} = Jason.decode(String.trim(out_bare))
      prompt_bare = File.read!(capture_bare)

      work_empty = git_repo_fixture(tmp_dir)
      goal_empty = write_goal_file(tmp_dir, work_empty)
      capture_empty = Path.join(tmp_dir, "argv-capture-empty.txt")
      contract = write_lane_contract(tmp_dir, work_empty, [])

      out_empty =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_empty,
                     "--workspace",
                     work_empty,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: argv_capturing_harness(tmp_dir, capture_empty)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, _} = Jason.decode(String.trim(out_empty))
      prompt_empty = File.read!(capture_empty)

      # Both prompts embed the (identical) absolute workspace-independent goal
      # id/predicate shape -- neither carries a review-comments section, and
      # the ABSENT-vs-EMPTY-array cases render byte-identical output.
      refute prompt_bare =~ "Reviewer feedback"
      refute prompt_empty =~ "Reviewer feedback"
    end
  end

  # ===========================================================================
  # subprocess spy: kazi makes ZERO gh/network calls to fetch review state
  # itself, even when a contract's review_comments are present and rendered.
  # ===========================================================================

  describe "kazi's own subprocess calls when review_comments are present" do
    test "no gh call originates from kazi itself", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_goal_file(tmp_dir, work)
      capture = Path.join(tmp_dir, "argv-capture-spy.txt")

      contract =
        write_lane_contract(tmp_dir, work, [
          %{"body" => "please rebase onto main"}
        ])

      spy_log = Path.join(tmp_dir, "gh-spy.log")
      spy_dir = Path.join(tmp_dir, "spybin")
      File.mkdir_p!(spy_dir)
      spy_gh = Path.join(spy_dir, "gh")

      File.write!(spy_gh, """
      #!/bin/sh
      echo "$@" >> #{inspect(spy_log)}
      exit 1
      """)

      File.chmod!(spy_gh, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", spy_dir <> ":" <> original_path)

      out =
        try do
          capture_io(fn ->
            assert Kazi.CLI.run(
                     [
                       "apply",
                       goal_file,
                       "--workspace",
                       work,
                       "--single-node",
                       "--in-place",
                       "--allow-primary-workspace",
                       "--no-preflight",
                       "--lane-contract",
                       contract,
                       "--json"
                     ],
                     adapter_opts: [command: argv_capturing_harness(tmp_dir, capture)],
                     reobserve_interval_ms: 5,
                     await_timeout: 15_000
                   ) == 0
          end)
        after
          System.put_env("PATH", original_path)
        end

      assert {:ok, _} = Jason.decode(String.trim(out))
      assert File.read!(capture) =~ "please rebase onto main"
      refute File.exists?(spy_log), "kazi itself must never invoke `gh`"
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp git_repo_fixture(tmp_dir) do
    work = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  defp write_goal_file(tmp_dir, workspace) do
    path =
      Path.join(
        tmp_dir,
        "review-comments-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-review-comments-fixture"
    name = "CLI review-comments fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_lane_contract(tmp_dir, workspace, review_comments) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{"task_sha" => head_sha(workspace), "review_comments" => review_comments})
    )

    path
  end

  defp head_sha(work) do
    {out, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"])
    String.trim(out)
  end

  # A stub harness that BOTH captures its own argv (where the claude profile
  # renders the prompt via `-p <prompt>`, T4.1) to `capture_path` and satisfies
  # the fixture predicate, so a single dispatch both proves what the assembled
  # prompt looked like AND lets the run converge.
  defp argv_capturing_harness(tmp_dir, capture_path) do
    write_stub(tmp_dir, "argv-capture", """
    printf '%s\\n' "$@" >> #{inspect(capture_path)}
    echo "the converged fix" > fixed.txt
    git add -A
    git -c user.email=t@example.com -c user.name=t commit -m "fix" --quiet
    exit 0
    """)
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
