defmodule Kazi.RuntimeStartupDeadlineTest do
  @moduledoc """
  issue #1683 (T69.2): `kazi apply` wedges forever with the #1255
  idle-scheduler signature when the reconcile loop never completes its FIRST
  observation.

  The blocking site the #1683 watchdog dumps name — the main process stuck in
  `{:gen, :do_call, 4}` inside `Kazi.Scheduler.await_coordinator/2` — is the
  outer end of an unbounded wait chain: the scheduler's `:await` (default
  `:infinity`) waits for partition terminal statuses that never arrive because
  the partition's `Kazi.Runtime.run/2` waits in `Loop.await(loop, :infinity)`
  for a loop that is blocked BEFORE its first observation completes (every
  live #1683 specimen froze with the run record at `iteration: 0`). Everything
  between `Loop.start_link` and the first observation — the predicate
  providers running the goal's own scripts (a command that never returns was
  the recorded trigger class) and the capture recipes — runs unbounded inside
  the loop's `gen_statem` process.

  The fix bounds the STARTUP leg of the terminal wait: from loop start until
  the loop projects its first observation (`on_iteration`, iteration 0). Past
  the deadline the run exits LOUDLY — a structured error naming the deadline
  and the `KAZI_APPLY_STARTUP_TIMEOUT_MS` remedy, the run record finished as
  `error` — instead of sitting wedged. Once the first observation lands the
  run is demonstrably live and the terminal wait keeps its existing
  (default `:infinity`) semantics, so a real multi-hour run is never cut off.

  The pins drive the REAL dispatch path (`Kazi.CLI.run/2`), no scheduler or
  loop mocks, mirroring `Kazi.CLIExitSemanticsTest`'s fixture vehicle.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  describe "the apply startup path carries a bounded wait (issue #1683)" do
    @tag :startup_deadline
    test "a first observation that never completes exits loudly within the deadline, \
not wedged forever",
         %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)

      # The #1683 trigger class: the goal's own script never returns, so the
      # loop's first observation never completes and — pre-fix — nothing in
      # the wait chain is bounded (both awaits default to `:infinity`).
      goal_file = write_goal_file(tmp_dir, work, "sleep 30")
      harness = noop_harness(tmp_dir)

      {out, result} = run_apply_bounded(goal_file, work, harness, 250, 5_000)

      assert match?({:ok, _code}, result),
             "the apply must exit within the startup deadline — a process that " <>
               "never returns is the #1683 wedge (observed: #{inspect(result)})"

      {:ok, code} = result

      assert code == 1, "the loud exit must be non-zero, got #{inspect(code)}"

      assert %{"status" => "error", "error" => message} = last_json_object(out)
      assert message =~ "startup deadline"
      assert message =~ "250"
      assert message =~ "KAZI_APPLY_STARTUP_TIMEOUT_MS"
    end

    @tag :startup_deadline
    test "the --parallel scheduler await unblocks when a partition's startup \
deadline fires (the #1683 blocking site)",
         %{tmp_dir: tmp_dir} do
      base = git_repo(tmp_dir)
      work = linked_worktree(tmp_dir, base)

      # The exact reported surface: `--parallel` wedges in
      # `Kazi.Scheduler.await_coordinator/2` when the partition's runtime never
      # reaches first observation. The deadline arrives via the operator env
      # knob so the pin exercises the REAL tuning surface, not an injected seam.
      goal_file = write_goal_file(tmp_dir, work, "sleep 30")
      harness = noop_harness(tmp_dir)

      System.put_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "250")

      {out, result} =
        try do
          run_apply_bounded(
            goal_file,
            work,
            harness,
            250,
            5_000,
            argv_extra: ["--parallel"]
          )
        after
          System.delete_env("KAZI_APPLY_STARTUP_TIMEOUT_MS")
        end

      assert match?({:ok, _code}, result),
             "the scheduler await must unblock when the partition's startup " <>
               "deadline fires — an unreturned process is the #1683 wedge " <>
               "(await_coordinator stuck in gen:do_call; observed: #{inspect(result)})"

      {:ok, code} = result

      assert code == 1, "the loud exit must be non-zero, got #{inspect(code)}"

      assert %{"collective" => "stuck"} = last_json_object(out)
    end
  end

  describe "the unblocked path (the bound covers ONLY the pre-observation leg)" do
    @tag :startup_deadline
    test "a run that reached first observation proceeds past the deadline", %{
      tmp_dir: tmp_dir
    } do
      work = git_repo(tmp_dir)

      # The predicate fails at t0 (no fixed.txt) — the first observation
      # completes immediately, so the run is live and the deadline is spent.
      # The harness then takes LONGER than the whole deadline to do its work:
      # a real run must never be cut off by the startup bound after t0.
      goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")
      harness = slow_fixing_harness(tmp_dir, 1_500)

      {out, result} = run_apply_bounded(goal_file, work, harness, 250, 15_000)

      assert match?({:ok, _code}, result),
             "a live run must still reach a terminal state (observed: #{inspect(result)})"

      {:ok, code} = result

      assert code == 0, "a converged run must exit 0, got #{inspect(code)}"

      assert %{"status" => "converged"} = last_json_object(out)
    end
  end

  describe "deadline resolution (opt > env > default)" do
    # `with_env/2` restores the ambient environment even when an assertion
    # fails, so a leaked value can never poison another test.
    test "the :startup_timeout_ms opt wins over the env and the default" do
      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "999", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms(startup_timeout_ms: 250) == 250
      end)
    end

    test "a parsable env value is honored; 0 and infinity disable the bound" do
      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "1234", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms([]) == 1234
      end)

      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "0", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms([]) == :infinity
      end)

      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "infinity", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms([]) == :infinity
      end)
    end

    test "an unparsable env value falls back to the default (never guesses, never raises)" do
      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "not-a-number", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms([]) == 300_000
      end)

      with_env("KAZI_APPLY_STARTUP_TIMEOUT_MS", "", fn ->
        assert Kazi.Runtime.resolve_startup_timeout_ms([]) == 300_000
      end)
    end

    test "an explicit :infinity opt disables the bound" do
      assert Kazi.Runtime.resolve_startup_timeout_ms(startup_timeout_ms: :infinity) == :infinity
    end

    defp with_env(name, value, fun) do
      System.put_env(name, value)

      try do
        fun.()
      after
        System.delete_env(name)
      end
    end
  end

  # --- driving the CLI (the real dispatch path, no scheduler/loop mocks) ------

  # Runs the apply in a monitored task and waits at most `wait_ms` for it to
  # return. Returns `{captured_output, {:ok, exit_code} | :wedged}` — the
  # `:wedged` shape is what the pre-fix binary produces (RED), the named cause
  # of the #1683 acceptance pin.
  defp run_apply_bounded(goal_file, work, harness, startup_ms, wait_ms, opts \\ []) do
    parent = self()
    argv_extra = Keyword.get(opts, :argv_extra, [])

    with_io(fn ->
      task =
        Task.async(fn ->
          code =
            Kazi.CLI.run(
              ["apply", goal_file, "--workspace", work, "--json"] ++ argv_extra,
              adapter_opts: [command: harness],
              reobserve_interval_ms: 5,
              await_timeout: :infinity,
              startup_timeout_ms: startup_ms
            )

          send(parent, {:apply_result, code})
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Kazi.Repo, self(), task.pid)

      receive do
        {:apply_result, code} -> {:ok, code}
      after
        wait_ms -> :wedged
      end
    end)
    |> then(fn {fun_result, output} -> {output, fun_result} end)
  end

  # --- fixtures (mirrors Kazi.CLIExitSemanticsTest) ---------------------------

  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "[EMAIL]"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  # The --parallel path refuses a repo's PRIMARY worktree (issue #937), so its
  # pin runs against a LINKED worktree of the fixture repo.
  defp linked_worktree(tmp_dir, base) do
    work = Path.join(tmp_dir, "wt-#{System.unique_integer([:positive])}")

    {_, 0} =
      System.cmd("git", ["worktree", "add", work, "-b", "wt-" <> base_ref(base)],
        cd: base,
        stderr_to_stdout: true
      )

    work
  end

  defp base_ref(base), do: base |> Path.basename() |> String.replace(~r/[^a-z0-9]/, "")

  defp write_goal_file(tmp_dir, workspace, observe_cmd) do
    path = Path.join(tmp_dir, "startup-deadline-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "startup-deadline-fixture"
    name = "startup deadline fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", #{inspect(observe_cmd)}]
    """)

    path
  end

  defp noop_harness(tmp_dir) do
    harness_script(tmp_dir, "noop", "exit 0")
  end

  # A harness that spends `ms` sleeping BEFORE writing the fix — a run whose
  # wall-clock easily outlives the startup deadline once it is past t0.
  defp slow_fixing_harness(tmp_dir, ms) do
    harness_script(
      tmp_dir,
      "slow-fix-#{ms}",
      """
      sleep #{div(ms, 1000)}
      echo "the converged fix" > fixed.txt
      git add fixed.txt
      git commit -q -m "task commit: converged fix"
      exit 0
      """
    )
  end

  defp harness_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "harness-#{name}-#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  # The CLI's --json contract: ONE JSON object on stdout. Capture noise (logger
  # lines, harness output) may precede it, so read the LAST parseable line.
  defp last_json_object(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, object} -> object
        _ -> nil
      end
    end)
    |> tap(fn object ->
      unless object, do: flunk("no JSON object on stdout:\n#{out}")
    end)
  end
end
