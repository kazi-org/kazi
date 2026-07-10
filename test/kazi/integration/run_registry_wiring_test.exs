defmodule Kazi.Integration.RunRegistryWiringTest do
  @moduledoc """
  Tier 2 — the integration proof T46.1's reopen demanded (ADR-0057): a real
  `kazi apply` run through the SAME entry point every real user hits
  (`Kazi.CLI.run/2`, shared by the escript and `mix kazi.apply`) leaves a `runs`
  row in the shared read-model. `Kazi.ReadModel.RunRegistryTest` already pinned
  the registry module in isolation — that passed even while the live apply path
  never called it (PR #789, v1.73.0 shipped with an empty `runs` table on a real
  converged run). This test goes through `Kazi.CLI.run/2` instead of calling
  `Kazi.Runtime.run/2` directly, so a regression that re-severs the wiring at
  the CLI layer (not just inside `Kazi.Runtime`) fails here too.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  import ExUnit.CaptureIO
  import Kazi.TestSupport.Eventually

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a converging `kazi apply` run registers, heartbeats, and finishes its runs row",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work],
          adapter_opts: [command: harness_stub],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

    assert run.status == "converged"
    assert run.workspace == work
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.heartbeat_at
    assert %DateTime{} = run.finished_at
    refute RunRegistry.stale?(run)
  end

  test "the run row captures --session-name and the harness envelope's session_id",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_envelope_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--session-name", "wiring-session"],
          adapter_opts: [command: harness_stub],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

    assert run.status == "converged"
    # The operator-assigned label from --session-name.
    assert run.session_name == "wiring-session"

    # Issue #1013 (T53.4): `CLI.run/2` returning does not guarantee every
    # best-effort registry write it fired has landed yet, so poll rather than
    # read once — the assertion content (session name + envelope session_id
    # captured) is unchanged.
    eventually(fn ->
      run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

      # The claude-envelope session_id, parsed by the profile, threaded through
      # the loop's iteration payload, and recorded by the runtime.
      assert run.harness_session_id == "sess-wiring-fixture"
    end)
  end

  test "the run row falls back to CLAUDE_CODE_SESSION_ID when neither --session-name nor KAZI_SESSION_NAME is given",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    original_kazi = System.get_env("KAZI_SESSION_NAME")
    original_claude = System.get_env("CLAUDE_CODE_SESSION_ID")
    System.delete_env("KAZI_SESSION_NAME")
    System.put_env("CLAUDE_CODE_SESSION_ID", "claude-code-session-abc123")

    try do
      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work],
            adapter_opts: [command: harness_stub],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)

      assert code == 0

      run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")
      assert run.session_name == "claude-code-session-abc123"
    after
      if original_kazi,
        do: System.put_env("KAZI_SESSION_NAME", original_kazi),
        else: System.delete_env("KAZI_SESSION_NAME")

      if original_claude,
        do: System.put_env("CLAUDE_CODE_SESSION_ID", original_claude),
        else: System.delete_env("CLAUDE_CODE_SESSION_ID")
    end
  end

  test "an explicit --session-name wins over both KAZI_SESSION_NAME and CLAUDE_CODE_SESSION_ID",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    original_kazi = System.get_env("KAZI_SESSION_NAME")
    original_claude = System.get_env("CLAUDE_CODE_SESSION_ID")
    System.put_env("KAZI_SESSION_NAME", "env-session")
    System.put_env("CLAUDE_CODE_SESSION_ID", "claude-code-session-xyz")

    try do
      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", work, "--session-name", "explicit-session"],
            adapter_opts: [command: harness_stub],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          )
        end)

      assert code == 0

      run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")
      assert run.session_name == "explicit-session"
    after
      if original_kazi,
        do: System.put_env("KAZI_SESSION_NAME", original_kazi),
        else: System.delete_env("KAZI_SESSION_NAME")

      if original_claude,
        do: System.put_env("CLAUDE_CODE_SESSION_ID", original_claude),
        else: System.delete_env("CLAUDE_CODE_SESSION_ID")
    end
  end

  test "a run whose harness reports NO usage envelope persists NULL tokens/cost, and the dispatch count + goal shape (T48.7, ADR-0058 decision 1)",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work],
          adapter_opts: [command: harness_stub],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

    assert run.status == "converged"
    # The stub's plain-text stdout carries no JSON usage envelope, so
    # `Kazi.Loop`'s `usage` stayed `%{}` all run -- honest-unknown, not 0.
    assert run.budget_tokens == nil
    assert run.budget_cached_input_tokens == nil
    assert run.budget_cost_usd == nil
    # T48.4 hasn't landed yet -- always nil for now.
    assert run.outcome_cause_class == nil
    # Loop-tracked, not harness-reported: exactly one dispatch fixed the
    # single failing code predicate.
    assert run.dispatch_count == 1
    assert run.context_tier in 0..4
    assert run.predicate_count == 1
    assert run.predicate_kind_histogram == %{"custom_script" => 1}
  end

  test "a run whose harness DOES report usage persists the actual tokens/cached-tokens/cost (T48.7)",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_usage_reporting_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work],
          adapter_opts: [command: harness_stub],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "run-registry-wiring-fixture")

    assert run.status == "converged"
    # input_tokens(120) + output_tokens(45) + cache_read_input_tokens(300).
    assert run.budget_tokens == 465
    assert run.budget_cached_input_tokens == 300
    assert run.budget_cost_usd == 0.0234
    assert run.dispatch_count == 1
  end

  defp write_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "run-registry-wiring-fixture"
    name = "T46.1 run-registry wiring fixture"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A stub that also prints a claude-style JSON envelope carrying a session_id,
  # so the profile-parse -> loop -> runtime -> registry chain is exercised.
  defp write_envelope_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_envelope_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    echo '{"result":"fixed","session_id":"sess-wiring-fixture"}'
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A stub reporting a full claude-style usage/cost envelope (T48.7), so the
  # profile's `usage_components/1` fold produces a NON-empty `usage` envelope
  # and the read-model projection persists real numbers rather than nil.
  defp write_usage_reporting_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_usage_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    echo '{"result":"fixed","total_cost_usd":0.0234,"usage":{"input_tokens":120,"output_tokens":45,"cache_read_input_tokens":300}}'
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
