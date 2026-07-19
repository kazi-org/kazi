defmodule Kazi.CLI.BusStatusTest do
  @moduledoc """
  T55.12: the `kazi bus tell` / `bus status` / `bus who` delivery-visibility
  contract at the CLI surface.

  UNTAGGED parse/help tests (no NATS): `bus status` argument parsing and the
  help text `bus tell`/`bus status`/`bus who` present.

  The end-to-end block starts a REAL daemon tree in-test (the
  `Kazi.CLI.BusWhoTest` pattern: tmp-scoped `KAZI_STATE_DIR`, unique names, a
  per-test nats port -- never a developer's live daemon) and runs the actual
  CLI against it. Requires `nats-server` on PATH (`NatsPrereq`), which CI
  installs -- so unlike the `:nats`-tagged client tests, these acceptance
  criteria are verified by CI.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.TestSupport.NatsPrereq

  # ===========================================================================
  # Untagged: parse/1 and help
  # ===========================================================================

  describe "parse/1 -- bus status (T55.12)" do
    test "`bus status <id>` parses the id as a positional" do
      assert {:bus, "status", ["4127"], _opts} = Kazi.CLI.parse(["bus", "status", "4127"])
    end

    test "`bus status <id> --json` threads --json through" do
      assert {:bus, "status", ["4127"], opts} =
               Kazi.CLI.parse(["bus", "status", "4127", "--json"])

      assert opts[:json] == true
    end

    test "`bus status --help` resolves to status's own help, not the generic usage" do
      assert {:bus_help, "status"} = Kazi.CLI.parse(["bus", "status", "--help"])
    end
  end

  describe "bus status --help" do
    test "documents the two states and what consumed does NOT mean" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "status", "--help"], []) == 0 end)

      assert output =~ "kazi bus status <id>"
      assert output =~ "pending"
      assert output =~ "consumed"
      # The honesty bar: an ack cannot know whether the session acted.
      assert output =~ "Consumes nothing"
    end
  end

  describe "bus tell --help" do
    test "states that success means queued, not seen" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "tell", "--help"], []) == 0 end)

      assert output =~ "bus status <id>"
      assert output =~ "QUEUED, not seen"
    end

    test "no longer over-claims that a tell cannot queue to a session that isn't there" do
      # The field report caught this exact claim while `tell` resolved happily
      # against a `dead-reaping` row. The help now separates the ERROR case
      # from the WARNING case instead of promising the warning away.
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "tell", "--help"], []) == 0 end)

      refute output =~ "can never silently queue to a session that isn't there"
      assert output =~ "dead-reaping"
      assert output =~ "WARNING"
    end
  end

  describe "bus who --help" do
    test "documents the inbox depth column" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "who", "--help"], []) == 0 end)

      assert output =~ "inbox"
    end
  end

  # ===========================================================================
  # End-to-end against a real daemon (CI installs nats-server)
  # ===========================================================================

  describe "delivery visibility end-to-end" do
    setup do
      NatsPrereq.ensure!()

      id = System.unique_integer([:positive])
      state_dir = "/tmp/kazi_status_cli_#{id}"
      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      {:ok, sup} =
        Kazi.Daemon.start(
          name: :"status_cli_daemon_#{id}",
          listener_name: :"status_cli_listener_#{id}",
          store_dir: "/tmp/kazi_status_cli_js_#{id}",
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

        File.rm_rf("/tmp/kazi_status_cli_js_#{id}")
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

    test "tell --json carries the message id, and the TTY line names it" do
      recipient = register(unique_name())

      json = tell_json(recipient, "hello")

      assert json["ok"] == true
      assert is_integer(json["id"])
      assert json["recipient"] == recipient
      assert json["liveness"] == "active"

      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["bus", "tell", recipient, "again", "--session-name", "sender"], []) ==
                   0
        end)

      assert output =~ "told #{recipient} (id "
    end

    test "status flips pending -> consumed after the recipient reads" do
      recipient = register(unique_name())
      id = tell_json(recipient, "read me")["id"]

      assert status_json(id)["state"] == "pending"

      capture_io(fn ->
        assert Kazi.CLI.run(["bus", "read", "--json", "--session-name", recipient], []) == 0
      end)

      after_read = status_json(id)
      assert after_read["state"] == "consumed"
      assert after_read["recipient"] == recipient
    end

    test "the status TTY line names the id, state, and recipient" do
      recipient = register(unique_name())
      id = tell_json(recipient, "render me")["id"]

      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["bus", "status", to_string(id), "--session-name", "sender"], []) ==
                   0
        end)

      assert output =~ "#{id} pending recipient=#{recipient}"
    end

    test "who shows the recipient's un-read inbox depth, and the TTY column with it" do
      recipient = register(unique_name())

      for n <- 1..2, do: tell_json(recipient, "queued #{n}")

      session = who_json() |> Enum.find(&(&1["session"] == recipient))
      assert session["inbox"] == 2

      output =
        capture_io(fn ->
          assert Kazi.CLI.run(["bus", "who", "--all", "--session-name", "sender"], []) == 0
        end)

      assert output =~ "inbox=2"

      capture_io(fn ->
        assert Kazi.CLI.run(["bus", "read", "--json", "--session-name", recipient], []) == 0
      end)

      drained = who_json() |> Enum.find(&(&1["session"] == recipient))
      assert drained["inbox"] == 0
    end

    test "telling an unknown session errors naming the live roster, and sends nothing" do
      known = register(unique_name())

      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(
                   ["bus", "tell", "nobody-here", "lost", "--session-name", "sender"],
                   []
                 ) ==
                   1
        end)

      assert output =~ "unknown recipient"
      assert output =~ known
    end

    test "status on an id that is not in the stream is a one-line error" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "status", "999999", "--session-name", "sender"], []) == 1
        end)

      assert output =~ "no message with id 999999"
    end

    test "status on a broadcast post says so rather than inventing a verdict" do
      capture_io(fn ->
        assert Kazi.CLI.run(["bus", "post", "fact", "broadcast", "--session-name", "poster"], []) ==
                 0
      end)

      read =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["bus", "read", "--json", "--full", "--session-name", "poster"],
                   []
                 ) == 0
        end)

      fact = read |> Jason.decode!() |> Map.fetch!("messages") |> List.first()

      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(
                   ["bus", "status", to_string(fact["id"]), "--session-name", "sender"],
                   []
                 ) == 1
        end)

      assert output =~ "is a broadcast"
    end

    test "a non-integer id is a usage error, never a bus round-trip" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "status", "not-an-id"], []) == 1
        end)

      assert output =~ "positive integer"
    end

    # =========================================================================
    # Helpers -- each drives the REAL CLI, so they pin the shipped surface.
    # =========================================================================

    defp unique_name, do: "worker-#{System.unique_integer([:positive])}"

    # Put a session on the roster under its own name: any bus call upserts
    # presence for the calling session.
    defp register(name) do
      capture_io(fn ->
        assert Kazi.CLI.run(["bus", "who", "--json", "--session-name", name], []) == 0
      end)

      name
    end

    defp tell_json(recipient, text) do
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["bus", "tell", recipient, text, "--json", "--session-name", "sender"],
                 []
               ) == 0
      end)
      |> Jason.decode!()
    end

    defp status_json(id) do
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["bus", "status", to_string(id), "--json", "--session-name", "sender"],
                 []
               ) == 0
      end)
      |> Jason.decode!()
    end

    defp who_json do
      capture_io(fn ->
        assert Kazi.CLI.run(["bus", "who", "--json", "--all", "--session-name", "sender"], []) ==
                 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("sessions")
    end
  end
end
