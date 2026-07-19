defmodule Kazi.Retrieval.InMemorySnippetCache do
  @moduledoc """
  A pure, hermetic `Kazi.Retrieval.Cache` double for tests (T4.9c): an in-memory
  retrieval-snippet cache, so the cache-hit / blast-radius invalidation logic of
  `Kazi.Retrieval.cached_retrieve/4` is exercised with no SQLite, no network — the
  read-model round-trip is covered separately by the real `Kazi.ReadModel` Tier-2
  test.

  Mirrors `Kazi.Context.InMemoryPackCache`. Lives only in `test/` (zero-stub
  policy: no doubles in `lib/`). The backing store is the calling process's
  dictionary, so each test is isolated without an external process and the
  behaviour callbacks stay arity-faithful (no pid threading).

  ## Usage

      cache = Kazi.Retrieval.InMemorySnippetCache.start()
      Kazi.Retrieval.cached_retrieve(failing, ws, {sha, radius}, cache: cache, retriever: r)
  """

  @behaviour Kazi.Retrieval.Cache

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

  @impl Kazi.Retrieval.Cache
  def get_cached_snippets(cache_key, current_blast_radius) do
    store = Process.get(__MODULE__, %{})

    case Map.get(store, cache_key) do
      nil ->
        nil

      {snippets, stored_radius} when is_list(snippets) ->
        if Enum.sort(stored_radius) == Enum.sort(current_blast_radius), do: snippets, else: nil
    end
  end

  @impl Kazi.Retrieval.Cache
  def put_cached_snippets(cache_key, _workspace, _git_sha, snippets, blast_radius)
      when is_list(snippets) and is_list(blast_radius) do
    store = Process.get(__MODULE__, %{})
    Process.put(__MODULE__, Map.put(store, cache_key, {snippets, blast_radius}))
    {:ok, snippets}
  end
end
