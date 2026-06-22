defmodule Kazi.Context.InMemoryPackCache do
  @moduledoc """
  A pure, hermetic `Kazi.Context.Cache` double for tests (T4.6): an in-memory
  orientation-pack cache, so the cache-hit / blast-radius invalidation logic of
  `Kazi.Context.cached_orientation_pack/4` is exercised with no SQLite, no
  network — the read-model round-trip is covered separately by the real
  `Kazi.ReadModel` Tier-2 test.

  Lives only in `test/` (zero-stub policy: no doubles in `lib/`). The backing store
  is the calling process's dictionary, so each test is isolated without an external
  process and the behaviour callbacks stay arity-faithful (no pid threading).

  ## Usage

      cache = Kazi.Context.InMemoryPackCache.start()
      Kazi.Context.cached_orientation_pack(failing, ws, {sha, radius}, cache: cache)
  """

  @behaviour Kazi.Context.Cache

  alias Kazi.Context.Pack

  @doc """
  Starts a fresh in-memory cache for the test and returns this module (to pass as
  `:cache`). The backing store is the calling process's dictionary, so each test is
  isolated without an external process.
  """
  @spec start() :: module()
  def start do
    Process.put(__MODULE__, %{})
    __MODULE__
  end

  @impl Kazi.Context.Cache
  def get_cached_pack(cache_key, current_blast_radius) do
    store = Process.get(__MODULE__, %{})

    case Map.get(store, cache_key) do
      nil ->
        nil

      {%Pack{} = pack, stored_radius} ->
        if Enum.sort(stored_radius) == Enum.sort(current_blast_radius), do: pack, else: nil
    end
  end

  @impl Kazi.Context.Cache
  def put_cached_pack(cache_key, _workspace, _git_sha, %Pack{} = pack) do
    store = Process.get(__MODULE__, %{})
    Process.put(__MODULE__, Map.put(store, cache_key, {pack, Pack.blast_radius(pack)}))
    {:ok, pack}
  end
end
