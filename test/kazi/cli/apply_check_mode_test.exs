defmodule Kazi.CLI.ApplyCheckModeTest do
  @moduledoc """
  Issue #805: `kazi apply --check` — a first-class observe-only mode.

  `--check` evaluates a goal's full predicate vector EXACTLY ONCE, through the
  same real provider dispatch a normal `apply` uses at t0, and reports a
  terminal verdict WITHOUT ever starting the convergence loop: no harness is
  dispatched, and no integrate/deploy action runs.

  Two terminal shapes:

    * **all predicates pass** -> `status: "pass"`, exit 0. Unlike a normal
      `apply`, this is the INTENDED success case — the vacuous_goal guard does
      NOT apply, since confirming an already-green vector is the whole point of
      a check (an ADR-0026 merge gate, or a release-qualification read).
    * **any predicate fails** -> `status: "fail"`, non-zero exit, carrying the
      full `predicates[]` vector with captured evidence for the failures (there
      is no later iteration to carry it).

  These are Tier-2 boundary tests: they drive the REAL CLI exec core
  (`Kazi.CLI.run/2`) against a goal-file on disk, with real `test_runner`
  predicates over a real tmp_dir workspace — no harness/integrator/deploy stub
  is injected because none should ever be invoked (proven with a spy adapter
  seam that must stay empty).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — --check argv boundary
  # ===========================================================================

  describe "parse/1 — apply --check" do
    test "--check carries through to opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--check"])

      assert opts[:check] == true
    end

    test "without --check the flag defaults to false" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:check] == false
    end
  end

  # ===========================================================================
  # Tier 2 — all predicates pass: status "pass", exit 0 (NOT vacuous_goal)
  # ===========================================================================

  describe "apply --check — all-pass vector" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "exits 0 with status pass (human)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "fixed.txt"), "already here\n")
      goal_file = write_all_pass_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir, "--check"], []) == 0
        end)

      assert out =~ "CHECK (observe-only, nothing dispatched)"
      assert out =~ "status: pass"
      refute out =~ "vacuous"
    end

    test "--json emits a single object with status pass, dispatched false, exit 0",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "fixed.txt"), "already here\n")
      goal_file = write_all_pass_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--check", "--json"],
                   []
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["mode"] == "check"
      assert payload["status"] == "pass"
      assert payload["dispatched"] == false
      assert payload["next_action"] == "done"

      assert [%{"id" => "code", "verdict" => "pass"}] = payload["predicates"]
      refute Map.has_key?(hd(payload["predicates"]), "evidence")
    end
  end

  # ===========================================================================
  # Tier 2 — a failing predicate: status "fail", non-zero exit, evidence carried
  # ===========================================================================

  describe "apply --check — a failing predicate" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "exits non-zero with status fail (human)", %{tmp_dir: tmp_dir} do
      goal_file = write_failing_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          exit_code =
            Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir, "--check"], [])

          assert exit_code != 0
        end)

      assert out =~ "CHECK (observe-only, nothing dispatched)"
      assert out =~ "status: fail"
    end

    test "--json carries the vector + captured evidence for the failing predicate",
         %{tmp_dir: tmp_dir} do
      goal_file = write_failing_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          exit_code =
            Kazi.CLI.run(
              ["apply", goal_file, "--workspace", tmp_dir, "--check", "--json"],
              []
            )

          assert exit_code != 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["mode"] == "check"
      assert payload["status"] == "fail"
      assert payload["dispatched"] == false
      assert payload["next_action"] == "investigate"

      assert [predicate] = payload["predicates"]
      assert predicate["id"] == "code"
      assert predicate["verdict"] == "fail"
      assert is_map(predicate["evidence"])
    end

    test "never dispatches a harness even against a red vector", %{tmp_dir: tmp_dir} do
      goal_file = write_failing_goal_file(tmp_dir)
      marker = Path.join(tmp_dir, "harness_was_called.txt")

      # A harness command that WOULD create a marker file if ever invoked. A real
      # apply (no --check) against this same goal would dispatch it; --check must
      # not.
      spy_harness = write_spy_harness_script(tmp_dir, marker)

      capture_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", tmp_dir, "--check"],
          adapter_opts: [command: spy_harness]
        )
      end)

      refute File.exists?(marker)
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp write_all_pass_goal_file(tmp_dir) do
    write_goal_file(tmp_dir, "all_pass", """
    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)
  end

  defp write_failing_goal_file(tmp_dir) do
    write_goal_file(tmp_dir, "failing", """
    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f never_created.txt"]
    """)
  end

  defp write_goal_file(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "#{name}_goal.toml")

    File.write!(path, """
    id = "cli-check-#{name}"
    name = "CLI check #{name}"

    [scope]
    workspace = "#{tmp_dir}"

    #{body}
    """)

    path
  end

  defp write_spy_harness_script(tmp_dir, marker) do
    path = Path.join(tmp_dir, "spy_harness.sh")
    File.write!(path, "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(path, 0o755)
    path
  end
end
