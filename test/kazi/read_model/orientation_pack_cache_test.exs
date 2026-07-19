defmodule Kazi.ReadModel.OrientationPackCacheTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T4.6, UC-022/UC-006). Stores orientation packs
  through `Kazi.ReadModel`, reads them back, and asserts the round-trip and the
  incremental blast-radius invalidation against a real SQLite read-model. Hermetic:
  per-test Sandbox transaction, no network.
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.Context.{FileRef, Pack, Symbol}
  alias Kazi.{ReadModel, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp sample_pack do
    %Pack{
      origin: :graph,
      token_budget: 4_000,
      files: [FileRef.new("lib/foo.ex"), FileRef.new("lib/bar.ex")],
      symbols: [
        Symbol.new("build/1", "lib/foo.ex",
          kind: :function,
          callers: ["caller/0"],
          callees: ["dep/0"]
        )
      ],
      test_sources: [FileRef.new("test/foo_test.exs", source: "assert Foo.build(1)")]
    }
  end

  describe "put_cached_pack/4 + get_cached_pack/2 — SQLite round-trip" do
    test "stores a pack and reads back an identical struct" do
      pack = sample_pack()
      key = "k-roundtrip"
      radius = Pack.blast_radius(pack)

      assert {:ok, _row} = ReadModel.put_cached_pack(key, "/ws", "sha-1", pack)

      assert ReadModel.get_cached_pack(key, radius) == pack
    end

    test "a pack with empty collections round-trips" do
      pack = %Pack{
        origin: :repo_map,
        token_budget: 4_000,
        files: [],
        symbols: [],
        test_sources: []
      }

      assert {:ok, _} = ReadModel.put_cached_pack("k-empty", "/ws", "sha-1", pack)
      assert ReadModel.get_cached_pack("k-empty", Pack.blast_radius(pack)) == pack
    end

    test "a missing key is a miss (nil)" do
      assert ReadModel.get_cached_pack("k-absent", []) == nil
    end
  end

  describe "incremental blast-radius invalidation" do
    test "a hit is reused while the blast radius is unchanged" do
      pack = sample_pack()
      radius = Pack.blast_radius(pack)
      {:ok, _} = ReadModel.put_cached_pack("k-fresh", "/ws", "sha-1", pack)

      # Same blast radius (any order) -> fresh hit.
      assert ReadModel.get_cached_pack("k-fresh", radius) == pack
      assert ReadModel.get_cached_pack("k-fresh", Enum.shuffle(radius)) == pack
    end

    test "a changed blast radius invalidates the entry (miss)" do
      pack = sample_pack()
      {:ok, _} = ReadModel.put_cached_pack("k-stale", "/ws", "sha-1", pack)

      # The impacted set changed at the same key: the cached pack is stale.
      changed = ["lib/foo.ex", "lib/NEW.ex"]
      assert ReadModel.get_cached_pack("k-stale", changed) == nil
    end
  end

  describe "put_cached_pack/4 upsert" do
    test "re-storing the same key replaces the prior pack and blast radius" do
      pack_v1 = sample_pack()
      {:ok, _} = ReadModel.put_cached_pack("k-upsert", "/ws", "sha-1", pack_v1)

      pack_v2 = %{pack_v1 | files: [FileRef.new("lib/changed.ex")], symbols: []}
      {:ok, _} = ReadModel.put_cached_pack("k-upsert", "/ws", "sha-1", pack_v2)

      # Old blast radius now misses; the new one hits the replaced pack.
      assert ReadModel.get_cached_pack("k-upsert", Pack.blast_radius(pack_v1)) == nil
      assert ReadModel.get_cached_pack("k-upsert", Pack.blast_radius(pack_v2)) == pack_v2

      # Exactly one row per key (upsert, not insert).
      assert Repo.aggregate(Kazi.ReadModel.OrientationPackCache, :count) == 1
    end
  end

  describe "invalidate_cached_pack/1" do
    test "deletes an entry and returns the row count" do
      {:ok, _} = ReadModel.put_cached_pack("k-del", "/ws", "sha-1", sample_pack())

      assert ReadModel.invalidate_cached_pack("k-del") == 1
      assert ReadModel.invalidate_cached_pack("k-del") == 0
      assert ReadModel.get_cached_pack("k-del", []) == nil
    end
  end
end
