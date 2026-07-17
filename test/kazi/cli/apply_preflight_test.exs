defmodule Kazi.CLI.ApplyPreflightTest do
  @moduledoc """
  T44.9 (UC-058): `kazi apply` runs a base-dispatchability preflight before the
  FIRST dispatch and REFUSES (named error, exit 1, nothing dispatched) when the
  base cannot receive the run's work; `--no-preflight` bypasses it.

  The hermetic trigger: a goal with `[integration] mode = "branch"` (which pushes)
  against a git repo that has NO configured remote — `git push --dry-run` fails
  deterministically, no network needed. The predicate itself (`test -f fixed.txt`)
  is runnable and a stub harness satisfies it, so the ONLY thing wrong is the push
  path — exactly what preflight guards, and exactly what `--no-preflight` skips.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  describe "parse/1 — --no-preflight" do
    test "--no-preflight carries through to opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--no-preflight"])

      assert opts[:no_preflight] == true
    end

    test "without the flag it defaults to false" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:no_preflight] == false
    end
  end

  test "a broken push path REFUSES dispatch: named error, exit 1, no harness call",
       %{tmp_dir: tmp_dir} do
    work = repo_without_remote(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {code, out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: never_called_harness(tmp_dir)]
        )
      end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "git push --dry-run"
    assert message =~ work
    assert message =~ "--no-preflight"

    refute File.exists?(harness_called_marker(tmp_dir)),
           "preflight must refuse BEFORE any dispatch"
  end

  test "--no-preflight bypasses the check and proceeds to dispatch",
       %{tmp_dir: tmp_dir} do
    work = repo_without_remote(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {_code, out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--no-preflight", "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    # The whole point: preflight did NOT fire, and a dispatch happened even though
    # the push path would have failed preflight.
    refute out =~ "git push --dry-run"

    assert File.exists?(harness_called_marker(tmp_dir)),
           "the harness must be dispatched under --no-preflight"
  end

  # --- fixtures -------------------------------------------------------------

  # A git repo with a commit but NO remote: `git push --dry-run` fails ("No
  # configured push destination"), deterministically and offline.
  defp repo_without_remote(tmp_dir) do
    work = Path.join(tmp_dir, "repo")
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

  # mode = "branch" pushes, so preflight runs `git push --dry-run`. The predicate
  # is runnable (`sh -c 'test -f fixed.txt'`) so the ONLY preflight failure is the
  # push path; a stub harness that writes fixed.txt converges it.
  defp write_goal_file(tmp_dir, workspace) do
    path = Path.join(tmp_dir, "preflight-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "preflight-fixture"
    name = "preflight fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [integration]
    mode = "branch"

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

  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", "touch #{harness_called_marker(tmp_dir)}\nexit 0")
  end

  defp passing_harness(tmp_dir) do
    write_stub(
      tmp_dir,
      "passing",
      "touch #{harness_called_marker(tmp_dir)}\necho \"the converged fix\" > fixed.txt\nexit 0"
    )
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end
