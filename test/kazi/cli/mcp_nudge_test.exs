defmodule Kazi.CLI.McpNudgeTest do
  @moduledoc """
  Issue #972: a serial `apply`'s prose report nudges toward `kazi init
  --with-mcp` once per project when the workspace's `.mcp.json` has no `kazi`
  MCP entry — every call absent that entry silently falls back to the more
  expensive JSON-CLI shell-out path, with no signal that this is by omission,
  not choice.

  Each case drives the real CLI (`Kazi.CLI.run/2`) with a single code-only
  predicate (no live/deploy predicate, so per the known "decide/2 converges
  before :integrate on code-only goals" behaviour this converges in one
  iteration with no git repo needed) and a harness stub that creates the
  passing file, so the run reaches `CONVERGED` and its real prose report.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  @nudge_marker "MCP not configured for this project"

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "apply (human report) — no .mcp.json" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "nudges once, then stays silent on a second run against the same workspace", %{
      tmp_dir: tmp_dir
    } do
      goal_file = write_goal_file(tmp_dir)
      runtime_opts = runtime_opts(tmp_dir)

      first =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir], runtime_opts) == 0
        end)

      assert first =~ "CONVERGED"
      assert first =~ @nudge_marker
      assert File.exists?(Path.join([tmp_dir, ".kazi", "mcp_nudge_shown"]))

      File.rm!(Path.join(tmp_dir, "fixed.txt"))

      second =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir], runtime_opts) == 0
        end)

      refute second =~ @nudge_marker
    end
  end

  describe "apply (human report) — .mcp.json exists without a kazi entry" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "nudges", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, ".mcp.json"),
        Jason.encode!(%{"mcpServers" => %{"other" => %{"command" => "other-server"}}})
      )

      goal_file = write_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir], runtime_opts(tmp_dir)) ==
                   0
        end)

      assert out =~ @nudge_marker
    end
  end

  describe "apply (human report) — .mcp.json already has the kazi entry" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "never nudges", %{tmp_dir: tmp_dir} do
      assert {:ok, _outcome, _path} = Kazi.MCP.ClientConfig.ensure_in_dir(tmp_dir)
      goal_file = write_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", goal_file, "--workspace", tmp_dir], runtime_opts(tmp_dir)) ==
                   0
        end)

      refute out =~ @nudge_marker
      refute File.exists?(Path.join([tmp_dir, ".kazi", "mcp_nudge_shown"]))
    end
  end

  describe "apply --json — never prints the nudge" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "the JSON stdout object is pure, and no nudge text leaks in", %{tmp_dir: tmp_dir} do
      goal_file = write_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--json"],
                   runtime_opts(tmp_dir)
                 ) == 0
        end)

      refute out =~ @nudge_marker
      assert {:ok, _payload} = Jason.decode(String.trim(out))
      refute File.exists?(Path.join([tmp_dir, ".kazi", "mcp_nudge_shown"]))
    end
  end

  defp write_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "cli-mcp-nudge"
    name = "CLI MCP nudge"

    [scope]
    workspace = "#{tmp_dir}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp runtime_opts(tmp_dir) do
    [adapter_opts: [command: write_harness_stub(tmp_dir)], reobserve_interval_ms: 5]
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")
    File.write!(path, "#!/bin/sh\necho fixed > fixed.txt\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
