defmodule Kazi.CLI.BusPruneTest do
  @moduledoc """
  Issue #1687 root cause 2 ("no retract/prune/TTL verb; topics are
  immortal"): the `kazi bus prune` CLI contract for `Kazi.Bus.retract/2`.

  UNTAGGED parse/help tests (no NATS): <topic>/--prefix argument threading
  and the `bus prune --help` text.

  The end-to-end block starts a REAL daemon tree in-test (the
  `Kazi.CLI.BusWhoTest` pattern: tmp-scoped `KAZI_STATE_DIR`, unique names, a
  per-test nats port -- never a developer's live daemon) and runs the actual
  CLI against it, proving a pruned topic actually disappears from a later
  `bus board` rather than merely being cleared.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.NatsPrereq

  # ===========================================================================
  # Untagged: parse/1 -- <topic> / --prefix threading
  # ===========================================================================

  describe "parse/1 -- bus prune arguments" do
    test "`bus prune <topic>` parses the topic as a positional argument" do
      assert {:bus, "prune", ["stale-topic"], _opts} =
               Kazi.CLI.parse(["bus", "prune", "stale-topic"])
    end

    test "`bus prune --prefix <prefix>` parses with no positional topic" do
      assert {:bus, "prune", [], opts} =
               Kazi.CLI.parse(["bus", "prune", "--prefix", "attention-"])

      assert opts[:prefix] == "attention-"
    end

    test "`bus prune` with neither <topic> nor --prefix defaults prefix to nil" do
      assert {:bus, "prune", [], opts} = Kazi.CLI.parse(["bus", "prune"])
      assert opts[:prefix] == nil
    end
  end

  describe "kazi bus prune --help" do
    test "documents <topic>, --prefix, and the retract-vs-clear distinction" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "prune", "--help"], []) == 0 end)

      assert output =~ "--prefix"
      assert output =~ "retract"
      assert output =~ "none"
    end
  end

  # Neither a topic nor --prefix must fail on the usage error BEFORE ever
  # reaching for a daemon connection (never a no-daemon error).
  describe "the usage error needs no daemon" do
    test "`bus prune` with no arguments reports the usage error, not a no-daemon error" do
      output = capture_io(:stderr, fn -> assert Kazi.CLI.run(["bus", "prune"]) == 1 end)

      assert output =~ "requires <topic> or --prefix"
    end
  end

  # ===========================================================================
  # End-to-end: a real in-test daemon tree, the real CLI
  # ===========================================================================

  describe "kazi bus prune against an in-test daemon" do
    setup do
      NatsPrereq.ensure!()

      id = System.unique_integer([:positive])
      state_dir = "/tmp/kazi_prune_cli_#{id}"
      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      {:ok, sup} =
        Kazi.Daemon.start(
          name: :"prune_cli_daemon_#{id}",
          listener_name: :"prune_cli_listener_#{id}",
          store_dir: "/tmp/kazi_prune_cli_js_#{id}",
          port: free_port()
        )

      on_exit(fn ->
        try do
          if Process.alive?(sup), do: Supervisor.stop(sup)
        catch
          :exit, _reason -> :ok
        end

        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")

        File.rm_rf("/tmp/kazi_prune_cli_js_#{id}")
        File.rm_rf(state_dir)
      end)

      %{sup: sup}
    end

    defp free_port do
      {:ok, socket} = :gen_tcp.listen(0, [:binary])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      port
    end

    test "`bus prune <topic>` erases the topic -- it drops out of a later board entirely" do
      assert Kazi.CLI.run(["bus", "post", "fact", "main is green", "--topic", "ci"]) == 0

      output_before = capture_io(fn -> assert Kazi.CLI.run(["bus", "board", "--json"]) == 0 end)
      {:ok, before} = Jason.decode(output_before)
      assert Enum.any?(before["board"]["facts"], &(&1["topic"] == "ci"))

      prune_output =
        capture_io(fn -> assert Kazi.CLI.run(["bus", "prune", "ci", "--json"]) == 0 end)

      {:ok, pruned} = Jason.decode(prune_output)
      assert pruned["ok"] == true
      assert pruned["purged"] == ["ci"]

      output_after = capture_io(fn -> assert Kazi.CLI.run(["bus", "board", "--json"]) == 0 end)
      {:ok, after_board} = Jason.decode(output_after)
      refute Enum.any?(after_board["board"]["facts"], &(&1["topic"] == "ci"))
      assert after_board["board"]["total_facts"] == 0
    end

    test "`bus prune --prefix <prefix>` purges every matching topic and leaves others" do
      assert Kazi.CLI.run(["bus", "post", "fact", "a", "--topic", "stale-1"]) == 0
      assert Kazi.CLI.run(["bus", "post", "fact", "b", "--topic", "stale-2"]) == 0
      assert Kazi.CLI.run(["bus", "post", "fact", "c", "--topic", "keep"]) == 0

      prune_output =
        capture_io(fn ->
          assert Kazi.CLI.run(["bus", "prune", "--prefix", "stale-", "--json"]) == 0
        end)

      {:ok, pruned} = Jason.decode(prune_output)
      assert Enum.sort(pruned["purged"]) == ["stale-1", "stale-2"]

      output_after = capture_io(fn -> assert Kazi.CLI.run(["bus", "board", "--json"]) == 0 end)
      {:ok, after_board} = Jason.decode(output_after)
      topics = Enum.map(after_board["board"]["facts"], & &1["topic"])
      assert topics == ["keep"]
    end

    test "pruning a topic with no messages is a no-op, not an error" do
      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["bus", "prune", "never-posted", "--json"]) == 0
        end)

      assert {:ok, %{"ok" => true, "purged" => []}} = Jason.decode(output)
    end
  end
end
