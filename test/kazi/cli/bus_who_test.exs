defmodule Kazi.CLI.BusWhoTest do
  @moduledoc """
  T55.11: the `kazi bus who` CLI contract for liveness and filters.

  UNTAGGED parse/help tests (no NATS): `--project`/`--machine` flag threading
  and the `bus who --help` text documenting liveness + the TTL.

  The end-to-end block starts a REAL daemon tree in-test (the
  `Kazi.Daemon.LifecycleTest` pattern: tmp-scoped `KAZI_STATE_DIR`, unique
  names, a per-test nats port -- never a developer's live daemon) and runs
  the actual CLI against it, asserting `who --json` carries `ttl_s` and
  per-session `seen_s`/`liveness`, and that the human render shows the
  liveness column. Requires `nats-server` on PATH (`NatsPrereq`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.NatsPrereq

  # ===========================================================================
  # Untagged: parse/1 -- --project / --machine thread through to bus who
  # ===========================================================================

  describe "parse/1 -- who filters (T55.11)" do
    test "`bus who --project <dir> --machine <host>` parses with both filters" do
      assert {:bus, "who", [], opts} =
               Kazi.CLI.parse(["bus", "who", "--project", "/some/repo", "--machine", "host-a"])

      assert opts[:project] == "/some/repo"
      assert opts[:machine] == "host-a"
    end

    test "`bus who` defaults both filters to nil" do
      assert {:bus, "who", [], opts} = Kazi.CLI.parse(["bus", "who"])
      assert opts[:project] == nil
      assert opts[:machine] == nil
    end
  end

  describe "kazi bus who --help" do
    test "documents liveness, the TTL in seconds, and the filters" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "who", "--help"], []) == 0 end)

      assert output =~ "--project"
      assert output =~ "--machine"
      assert output =~ "active"
      assert output =~ "idle"
      assert output =~ "dead-reaping"
      assert output =~ "#{Kazi.Bus.session_ttl_s()}"
    end
  end

  # ===========================================================================
  # End-to-end: a real in-test daemon tree, the real CLI
  # ===========================================================================

  describe "kazi bus who against an in-test daemon" do
    setup do
      NatsPrereq.ensure!()

      id = System.unique_integer([:positive])
      state_dir = "/tmp/kazi_who_cli_#{id}"
      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      {:ok, sup} =
        Kazi.Daemon.start(
          name: :"who_cli_daemon_#{id}",
          listener_name: :"who_cli_listener_#{id}",
          store_dir: "/tmp/kazi_who_cli_js_#{id}",
          port: free_port()
        )

      on_exit(fn ->
        # The tree can already be mid-shutdown (a failed nats spawn tears it
        # down); a stop on a dying supervisor must not fail the teardown.
        try do
          if Process.alive?(sup), do: Supervisor.stop(sup)
        catch
          :exit, _reason -> :ok
        end

        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")

        File.rm_rf("/tmp/kazi_who_cli_js_#{id}")
        File.rm_rf(state_dir)
      end)

      %{sup: sup}
    end

    # An OS-assigned free port: `System.unique_integer/1` yields SIMILAR
    # values in every concurrently-running beam on this machine, so
    # `base + rem(id, n)` ports collide ACROSS test sessions -- a daemon can
    # then "pass" wait_ready against another session's nats-server and lose
    # it mid-test (econnrefused). Asking the OS eliminates that class.
    defp free_port do
      {:ok, socket} = :gen_tcp.listen(0, [:binary])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      port
    end

    test "the daemon tree supervises the presence sweep", %{sup: sup} do
      child_ids = sup |> Supervisor.which_children() |> Enum.map(fn {id, _, _, _} -> id end)
      assert Kazi.Daemon.PresenceSweep in child_ids
    end

    test "`who --json` carries ttl_s and per-session seen_s + liveness" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "who", "--json"], []) == 0 end)

      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["ok"] == true
      assert decoded["ttl_s"] == Kazi.Bus.session_ttl_s()

      # The CLI's own call upserts its presence, so the roster is non-empty.
      assert [_ | _] = decoded["sessions"]

      for session <- decoded["sessions"] do
        assert is_integer(session["seen_s"])
        assert session["liveness"] in ["active", "idle", "dead-reaping"]
      end
    end

    test "the human render shows the liveness column" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "who"], []) == 0 end)

      assert output =~ "liveness=active"
    end
  end
end
