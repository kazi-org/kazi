defmodule Kazi.ReadModel.WriterTest do
  @moduledoc """
  T52.1 (ADR-0068): the single client-side write-router seam. Tier 2 — real
  SQLite boundary for the direct branch (a genuine read-model insert), an
  injected `:alive` probe + mock `:remote` for the daemon branch (no real DB
  write), and a counting probe to pin the per-process memoization.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel
  alias Kazi.ReadModel.{ProposedMemory, Writer}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        proposal_ref: "mem-#{System.unique_integer([:positive])}",
        fingerprint: "fp-#{System.unique_integer([:positive])}",
        class: "landmine",
        content: "predicate a repeated 3 times without change",
        goal_ref: "goal-#{System.unique_integer([:positive])}",
        target_doc: "docs/lore.md",
        status: "proposed"
      },
      overrides
    )
  end

  describe "no daemon (direct branch)" do
    test "performs the identical Repo write today's direct call does" do
      a = attrs()

      result = Writer.write(fn -> ReadModel.propose_memory(a) end, probe: fn _ -> :missing end)

      # Byte-identical to calling propose_memory/1 directly: same {:ok, struct}
      # shape, and the row is actually persisted through Kazi.Repo.
      assert {:ok, %ProposedMemory{} = row} = result
      assert row.fingerprint == a.fingerprint
      assert Repo.get_by(ProposedMemory, fingerprint: a.fingerprint).id == row.id
      assert Repo.aggregate(ProposedMemory, :count, :id) == 1
    end

    test "returns the direct writer's value verbatim" do
      assert Writer.write(fn -> {:sentinel, 42} end, probe: fn _ -> :missing end) ==
               {:sentinel, 42}
    end

    test "the real default probe resolves to the direct branch in a daemonless env" do
      # No sock_path/probe injected: exercises Supervisor.default_sock_path/0 +
      # Probe.probe/1. No daemon runs under test, so the direct branch is taken.
      assert Writer.write(fn -> :direct_ran end) == :direct_ran
    end
  end

  describe "daemon alive (remote branch)" do
    test "dispatches to the socket client instead of Repo" do
      test_pid = self()

      result =
        Writer.write(
          fn -> ReadModel.propose_memory(attrs()) end,
          probe: fn _ -> :alive end,
          remote: fn ->
            send(test_pid, :remote_called)
            :routed
          end
        )

      assert result == :routed
      assert_received :remote_called
      # The direct fun would have inserted a row; the daemon branch must not.
      assert Repo.aggregate(ProposedMemory, :count, :id) == 0
    end

    test "remote defaults to the direct writer until a socket client is supplied" do
      # ADR-0068 staging: an alive daemon with no :remote still lands the write
      # directly rather than dropping it while the socket path is being built.
      a = attrs()

      assert {:ok, %ProposedMemory{}} =
               Writer.write(fn -> ReadModel.propose_memory(a) end, probe: fn _ -> :alive end)

      assert Repo.get_by(ProposedMemory, fingerprint: a.fingerprint)
    end
  end

  describe "presence memoization (per process, short TTL)" do
    test "a second write within the TTL does not re-probe" do
      test_pid = self()
      probe = fn _ -> send(test_pid, :probed) && :missing end

      Writer.write(fn -> :ok end, probe: probe, ttl_ms: 60_000)
      Writer.write(fn -> :ok end, probe: probe, ttl_ms: 60_000)

      assert_received :probed
      refute_received :probed
    end

    test "re-probes once the TTL has elapsed" do
      test_pid = self()
      probe = fn _ -> send(test_pid, :probed) && :missing end

      # ttl_ms: 0 expires immediately, so the second write re-probes.
      Writer.write(fn -> :ok end, probe: probe, ttl_ms: 0)
      Writer.write(fn -> :ok end, probe: probe, ttl_ms: 0)

      assert_received :probed
      assert_received :probed
    end

    test "the cache is keyed per socket path" do
      test_pid = self()
      probe = fn sock -> send(test_pid, {:probed, sock}) && :missing end

      Writer.write(fn -> :ok end, probe: probe, sock_path: "/tmp/a.sock", ttl_ms: 60_000)
      Writer.write(fn -> :ok end, probe: probe, sock_path: "/tmp/b.sock", ttl_ms: 60_000)

      assert_received {:probed, "/tmp/a.sock"}
      assert_received {:probed, "/tmp/b.sock"}
    end
  end
end
