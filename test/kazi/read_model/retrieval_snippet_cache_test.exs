defmodule Kazi.ReadModel.RetrievalSnippetCacheTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T4.9c, UC-022/UC-006). Stores retrieved snippet
  lists through `Kazi.ReadModel`, reads them back, and asserts the round-trip and
  the incremental blast-radius invalidation against a real SQLite read-model,
  mirroring the T4.6 orientation-pack cache. Hermetic: per-test Sandbox
  transaction, no network.
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially.
  use ExUnit.Case, async: false

  alias Kazi.{ReadModel, Repo}
  alias Kazi.Retrieval.Snippet

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp sample_snippets do
    [
      Snippet.new("def build(x), do: x + 1", source: "lib/foo.ex:42"),
      Snippet.new("plain snippet with no source")
    ]
  end

  @radius ["lib/bar.ex", "lib/foo.ex"]

  describe "put_cached_snippets/5 + get_cached_snippets/2 — SQLite round-trip" do
    test "stores snippets and reads back an identical list" do
      snippets = sample_snippets()

      assert {:ok, _row} =
               ReadModel.put_cached_snippets("k-roundtrip", "/ws", "sha-1", snippets, @radius)

      assert ReadModel.get_cached_snippets("k-roundtrip", @radius) == snippets
    end

    test "an empty snippet list round-trips" do
      assert {:ok, _} = ReadModel.put_cached_snippets("k-empty", "/ws", "sha-1", [], @radius)
      assert ReadModel.get_cached_snippets("k-empty", @radius) == []
    end

    test "a missing key is a miss (nil)" do
      assert ReadModel.get_cached_snippets("k-absent", []) == nil
    end
  end

  describe "incremental blast-radius invalidation" do
    test "a hit is reused while the blast radius is unchanged (any order)" do
      snippets = sample_snippets()
      {:ok, _} = ReadModel.put_cached_snippets("k-fresh", "/ws", "sha-1", snippets, @radius)

      assert ReadModel.get_cached_snippets("k-fresh", @radius) == snippets
      assert ReadModel.get_cached_snippets("k-fresh", Enum.shuffle(@radius)) == snippets
    end

    test "a changed blast radius invalidates the entry (miss)" do
      {:ok, _} =
        ReadModel.put_cached_snippets("k-stale", "/ws", "sha-1", sample_snippets(), @radius)

      changed = ["lib/foo.ex", "lib/NEW.ex"]
      assert ReadModel.get_cached_snippets("k-stale", changed) == nil
    end
  end

  describe "put_cached_snippets/5 upsert" do
    test "re-storing the same key replaces the prior snippets and blast radius" do
      {:ok, _} =
        ReadModel.put_cached_snippets("k-upsert", "/ws", "sha-1", sample_snippets(), @radius)

      v2 = [Snippet.new("fresh result", source: "lib/changed.ex")]
      v2_radius = ["lib/changed.ex"]
      {:ok, _} = ReadModel.put_cached_snippets("k-upsert", "/ws", "sha-1", v2, v2_radius)

      # Old blast radius now misses; the new one hits the replaced snippets.
      assert ReadModel.get_cached_snippets("k-upsert", @radius) == nil
      assert ReadModel.get_cached_snippets("k-upsert", v2_radius) == v2

      # Exactly one row per key (upsert, not insert).
      assert Repo.aggregate(Kazi.ReadModel.RetrievalSnippetCache, :count) == 1
    end
  end

  describe "invalidate_cached_snippets/1" do
    test "deletes an entry and returns the row count" do
      {:ok, _} =
        ReadModel.put_cached_snippets("k-del", "/ws", "sha-1", sample_snippets(), @radius)

      assert ReadModel.invalidate_cached_snippets("k-del") == 1
      assert ReadModel.invalidate_cached_snippets("k-del") == 0
      assert ReadModel.get_cached_snippets("k-del", []) == nil
    end
  end

  describe "cached_retrieve/4 over the real read-model (T4.6 cache reuse)" do
    alias Kazi.PredicateResult
    alias Kazi.Retrieval
    alias Kazi.Retrieval.CountingRetriever

    @failing [{:unit, PredicateResult.fail(%{output: "boom"})}]

    test "a fresh hit reuses cached snippets without re-invoking the retriever" do
      retriever = CountingRetriever.new(snippets: [{"x", source: "lib/a.ex"}])

      first = Retrieval.cached_retrieve(@failing, "/ws", {"sha-1", @radius}, retriever: retriever)

      # Same (workspace, sha, failing-set) + unchanged blast radius: cache hit, the
      # retriever must NOT run again (no re-embed of an unchanged target).
      second =
        Retrieval.cached_retrieve(@failing, "/ws", {"sha-1", @radius},
          retriever: retriever,
          on_retrieve: fn -> flunk("retriever re-invoked on a cache hit") end
        )

      assert second == first
      assert CountingRetriever.count() == 1
    end

    test "a changed blast radius re-retrieves through the real cache" do
      retriever = CountingRetriever.new(snippets: ["s"])

      _ = Retrieval.cached_retrieve(@failing, "/ws", {"sha-1", @radius}, retriever: retriever)

      _ =
        Retrieval.cached_retrieve(@failing, "/ws", {"sha-1", ["lib/z.ex"]}, retriever: retriever)

      assert CountingRetriever.count() == 2
    end
  end
end
