defmodule Kazi.ReadModel.WriterTest do
  @moduledoc """
  T52.1 (ADR-0068): the single client-side write-router seam. Tier 2 — real
  SQLite boundary for the direct branch (a genuine read-model insert), an
  injected `:alive` probe + mock `:remote` for the daemon branch (no real DB
  write), and a counting probe to pin the per-process memoization.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kazi.ReadModel
  alias Kazi.ReadModel.{MemoryIndexFile, OrientationPackCache, ProposedMemory, Writer}
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

    test "write/2's remote defaults to the direct writer when none is supplied" do
      # The write/2 seam contract (T52.1): an alive daemon with no :remote still
      # runs the direct closure rather than dropping the write. T52.5 supplies
      # real :remote closures at the typed helpers (insert/update/...); this pins
      # the raw seam with a pure closure so it does not itself route (which would
      # read the injected-:alive presence cache and dial a nonexistent socket).
      assert Writer.write(fn -> :landed_direct end, probe: fn _ -> :alive end) ==
               :landed_direct
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

  describe "write-time version-stamp-and-refuse (T52.7, no daemon)" do
    # Stamp the direct db's kazi_schema_meta row (the same table Migrate reads),
    # so the default db_stamped_version path — not just an injected integer —
    # exercises the real skew read against the file.
    defp stamp_db!(version) do
      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TABLE IF NOT EXISTS kazi_schema_meta (version INTEGER NOT NULL)",
        []
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM kazi_schema_meta", [])

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO kazi_schema_meta (version) VALUES (?1)",
        [version]
      )
    end

    defp proposed_changeset, do: ProposedMemory.changeset(%ProposedMemory{}, attrs())

    test "an older binary refuses every write against a newer-stamped file and persists nothing" do
      stamp_db!(20_990_101_000_000)

      log =
        capture_log(fn ->
          # binary_version below the file's stamp -> :client_older -> refuse.
          result =
            Writer.insert(proposed_changeset(), [],
              probe: fn _ -> :missing end,
              binary_version: 1
            )

          assert result == {:error, :read_model_unavailable}
        end)

      # Guard-style visible degrade, naming both schema versions + the remedy.
      assert log =~ "read-model schema v20990101000000 is newer than this binary (v1)"
      assert log =~ "upgrade kazi"

      # NO Repo write: the row does not appear, the run proceeds (no crash/hang).
      assert Repo.aggregate(ProposedMemory, :count, :id) == 0
    end

    test "an equal-or-newer binary writes direct and persists" do
      a = attrs()

      # binary_version at/above the file's stamp -> :equal/:client_newer -> direct.
      result =
        %ProposedMemory{}
        |> ProposedMemory.changeset(a)
        |> Writer.insert([],
          probe: fn _ -> :missing end,
          binary_version: 20_990_101_000_000,
          db_stamped_version: 20_990_101_000_000
        )

      assert {:ok, %ProposedMemory{} = row} = result
      assert Repo.get_by(ProposedMemory, fingerprint: a.fingerprint).id == row.id
    end

    test "delete_all preserves its count contract on refuse (returns 0, deletes nothing)" do
      assert Writer.delete_all(OrientationPackCache, %{cache_key: "k"},
               probe: fn _ -> :missing end,
               binary_version: 1,
               db_stamped_version: 20_990_101_000_000
             ) == 0
    end

    test "query! returns :ok on refuse and issues no Repo statement" do
      assert Writer.query!("DELETE FROM memory_chunks_fts WHERE path = ?", ["p"],
               probe: fn _ -> :missing end,
               binary_version: 1,
               db_stamped_version: 20_990_101_000_000
             ) == :ok
    end

    test "insert! degrades without raising on refuse" do
      changeset =
        MemoryIndexFile.changeset(%MemoryIndexFile{}, %{
          workspace_root: "/w",
          path: "p.md",
          content_hash: "h"
        })

      assert Writer.insert!(changeset, [],
               probe: fn _ -> :missing end,
               binary_version: 1,
               db_stamped_version: 20_990_101_000_000
             ) == {:error, :read_model_unavailable}
    end

    test "an unstamped (nil) file writes direct — a brand-new db is never refused" do
      a = attrs()

      result =
        %ProposedMemory{}
        |> ProposedMemory.changeset(a)
        |> Writer.insert([],
          probe: fn _ -> :missing end,
          binary_version: 1,
          db_stamped_version: nil
        )

      assert {:ok, %ProposedMemory{}} = result
      assert Repo.get_by(ProposedMemory, fingerprint: a.fingerprint)
    end

    test "the skew decision is memoized per process (one degrade line per TTL window)" do
      log =
        capture_log(fn ->
          for _ <- 1..3 do
            Writer.delete_all(OrientationPackCache, %{cache_key: "k"},
              probe: fn _ -> :missing end,
              binary_version: 1,
              db_stamped_version: 20_990_101_000_000,
              ttl_ms: 60_000
            )
          end
        end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "running without persistence"))
      assert length(lines) == 1
    end

    test "an alive daemon never refuses an older client (additive write API, T52.5)" do
      # :client_older against an alive daemon must route remote, not refuse: the
      # skew check lives only in the no-daemon branch.
      result =
        Writer.write(fn -> :direct end,
          probe: fn _ -> :alive end,
          binary_version: 1,
          db_stamped_version: 20_990_101_000_000,
          remote: fn -> :routed end
        )

      assert result == :routed
    end
  end

  describe "client-newer-than-daemon skew degrade (T52.8, ADR-0068 point 3)" do
    test "an older daemon degrades visibly without any socket write (the ping handshake path)" do
      test_pid = self()

      log =
        capture_log(fn ->
          # binary_version ABOVE the daemon's ping schema_vsn -> :client_newer ->
          # the daemon is OLDER. Read via a stubbed T52.2 ping handshake.
          result =
            Writer.insert(proposed_changeset(), [],
              probe: fn _ -> :alive end,
              binary_version: 20_990_101_000_000,
              ping: fn _ ->
                send(test_pid, :pinged)
                {:ok, %{"ok" => true, "schema_vsn" => 1}}
              end,
              remote: fn ->
                send(test_pid, :remote_called)
                :routed
              end
            )

          # Same shaped degrade as the T52.7 refuse — one degrade shape for callers.
          assert result == {:error, :read_model_unavailable}
        end)

      # The daemon WAS probed via the handshake, but NO socket write was issued.
      assert_received :pinged
      refute_received :remote_called

      # Exact single-line operator choice naming both versions + the restart remedy.
      assert log =~
               "daemon is older than this client (schema v1 < v20990101000000); " <>
                 "restart it (`kazi daemon restart`) or continue without persistence"

      # One line, operator-readable, no stacktrace.
      degrade_lines =
        log |> String.split("\n") |> Enum.filter(&(&1 =~ "daemon is older than this client"))

      assert length(degrade_lines) == 1
      refute log =~ "** ("
      refute log =~ "stacktrace"

      # No persistence: the run proceeds (no deadlock, no hang), nothing written.
      assert Repo.aggregate(ProposedMemory, :count, :id) == 0
    end

    test "a newer daemon writes through the socket (additive-within-major)" do
      test_pid = self()

      # binary_version BELOW the daemon's schema_vsn -> :client_older -> the daemon
      # is newer; the older client keeps writing through the additive API (T52.5).
      result =
        Writer.write(fn -> :direct end,
          probe: fn _ -> :alive end,
          binary_version: 1,
          ping: fn _ -> {:ok, %{"schema_vsn" => 20_990_101_000_000}} end,
          remote: fn ->
            send(test_pid, :remote_called)
            :routed
          end
        )

      assert result == :routed
      assert_received :remote_called
    end

    test "an equal-schema daemon writes through" do
      result =
        Writer.write(fn -> :direct end,
          probe: fn _ -> :alive end,
          binary_version: 20_990_101_000_000,
          daemon_schema_vsn: 20_990_101_000_000,
          remote: fn -> :routed end
        )

      assert result == :routed
    end

    test "a daemon that reports no schema_vsn writes through (never a silent block)" do
      # An old daemon (no schema_vsn) or a failed ping must not deadlock a newer
      # client: absent a POSITIVE older reading, the write goes through.
      for reply <- [{:ok, %{"ok" => true}}, {:error, :closed}] do
        assert Writer.write(fn -> :direct end,
                 probe: fn _ -> :alive end,
                 binary_version: 20_990_101_000_000,
                 ping: fn _ -> reply end,
                 remote: fn -> :routed end
               ) == :routed
      end
    end

    test "the daemon-skew decision is memoized per process (one degrade line, one ping per TTL window)" do
      test_pid = self()

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            Writer.write(fn -> :direct end,
              probe: fn _ -> :alive end,
              binary_version: 20_990_101_000_000,
              ping: fn _ ->
                send(test_pid, :pinged)
                {:ok, %{"schema_vsn" => 1}}
              end,
              remote: fn -> :routed end,
              ttl_ms: 60_000
            )
          end
        end)

      lines =
        log |> String.split("\n") |> Enum.filter(&(&1 =~ "daemon is older than this client"))

      assert length(lines) == 1

      # The handshake fired at most once across the burst, not per write.
      assert_received :pinged
      refute_received :pinged
    end
  end
end
