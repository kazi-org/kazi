defmodule Kazi.ContextCacheTest do
  @moduledoc """
  Tier 1 — the optional cache layer of `Kazi.Context.cached_orientation_pack/4`
  (T4.6, ADR-0010 §4), exercised against an in-memory `Kazi.Context.Cache` double
  and a static graph source. Hermetic: no SQLite, no network. The real SQLite
  round-trip is covered by `Kazi.ReadModel.OrientationPackCacheTest`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context
  alias Kazi.Context.{InMemoryPackCache, Pack, StaticGraphSource}
  alias Kazi.PredicateResult

  @workspace "/fixture/ws"
  @sha "abc123"

  defp failing(output), do: [{:unit, PredicateResult.fail(%{output: output})}]

  defp source do
    StaticGraphSource.new(
      origin: :graph,
      files: ["lib/foo.ex", "lib/bar.ex"],
      symbols: [{"build/1", "lib/foo.ex", [callers: ["caller/0"]]}],
      test_sources: [{"test/foo_test.exs", [source: "assert Foo.build(1)"]}]
    )
  end

  # The blast radius the fresh pack would be scoped to (impacted files + symbol
  # paths), used as the current radius the cache invalidation compares against.
  defp current_radius(failing) do
    Context.orientation_pack(failing, @workspace, graph_source: source())
    |> Pack.blast_radius()
  end

  describe "cache miss — builds and stores" do
    test "a cold cache builds the pack and returns it" do
      cache = InMemoryPackCache.start()
      f = failing("boom in lib/foo.ex")

      pack =
        Context.cached_orientation_pack(f, @workspace, {@sha, current_radius(f)},
          cache: cache,
          graph_source: source()
        )

      assert pack == Context.orientation_pack(f, @workspace, graph_source: source())
    end
  end

  describe "cache hit — reuses without rebuilding" do
    test "a second call at the same key reuses the cached pack (builder not re-invoked)" do
      cache = InMemoryPackCache.start()
      f = failing("boom in lib/foo.ex")
      radius = current_radius(f)
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      bump = fn -> Agent.update(agent, &(&1 + 1)) end

      opts = [cache: cache, graph_source: source(), on_build: bump]

      pack1 = Context.cached_orientation_pack(f, @workspace, {@sha, radius}, opts)
      pack2 = Context.cached_orientation_pack(f, @workspace, {@sha, radius}, opts)

      # Identical result, and the builder ran exactly once (the second call hit).
      assert pack1 == pack2
      assert Agent.get(agent, & &1) == 1
    end
  end

  describe "incremental blast-radius invalidation" do
    test "a changed blast radius forces a rebuild (the cached pack is stale)" do
      cache = InMemoryPackCache.start()
      f = failing("boom in lib/foo.ex")
      radius = current_radius(f)
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      bump = fn -> Agent.update(agent, &(&1 + 1)) end

      opts = [cache: cache, graph_source: source(), on_build: bump]

      # Prime the cache.
      Context.cached_orientation_pack(f, @workspace, {@sha, radius}, opts)
      assert Agent.get(agent, & &1) == 1

      # Same key (same sha + failing set), but the blast radius changed -> miss ->
      # rebuild.
      changed = ["lib/foo.ex", "lib/NEW.ex"]
      Context.cached_orientation_pack(f, @workspace, {@sha, changed}, opts)
      assert Agent.get(agent, & &1) == 2
    end

    test "a different failing set is a different key (independent cache entries)" do
      cache = InMemoryPackCache.start()
      {:ok, agent} = Agent.start_link(fn -> 0 end)
      bump = fn -> Agent.update(agent, &(&1 + 1)) end
      opts = [cache: cache, graph_source: source(), on_build: bump]

      f1 = failing("a")
      f2 = [{:probe, PredicateResult.fail(%{output: "b"})}]

      Context.cached_orientation_pack(f1, @workspace, {@sha, current_radius(f1)}, opts)
      Context.cached_orientation_pack(f2, @workspace, {@sha, current_radius(f2)}, opts)

      # Two distinct keys -> two builds.
      assert Agent.get(agent, & &1) == 2
    end
  end
end
