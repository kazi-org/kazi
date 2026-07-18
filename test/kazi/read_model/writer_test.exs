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
end
