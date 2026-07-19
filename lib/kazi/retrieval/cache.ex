defmodule Kazi.Retrieval.Cache do
  @moduledoc """
  The injectable retrieval-snippet cache seam (T4.9c, ADR-0012 §4).

  Retrieval — when enabled per goal — embeds the target and similarity-searches the
  failing predicates (the real backend, T4.9b). That is heavyweight, so its result
  is cached, exactly mirroring the T4.6 orientation-pack cache: keyed on
  `Kazi.Context.cache_key/3` (workspace, git-SHA, failing-predicate set) and
  invalidated when the blast radius changes. The production implementation,
  `Kazi.ReadModel`, stores snippet lists in the SQLite read-model; tests inject an
  in-memory double, so no DB is needed to exercise the cache-hit / invalidation
  logic in isolation.

  ## Contract

    * `get_cached_snippets/2` — return the cached `[Kazi.Retrieval.Snippet]` for
      `cache_key` **only on a fresh hit**: an entry exists and its stored blast
      radius still equals the `current_blast_radius` argument. Return `nil` on a
      miss or a blast-radius mismatch (the cached snippets are stale), so the
      caller re-retrieves.
    * `put_cached_snippets/5` — store `snippets` under `cache_key`, recording
      `workspace`/`git_sha` and the `blast_radius` for the next
      `get_cached_snippets/2`'s invalidation check. Idempotent: re-storing the same
      key replaces.

  `Kazi.ReadModel` implements both (`get_cached_snippets/2`,
  `put_cached_snippets/5`). This mirrors `Kazi.Context.Cache` so the two caches
  share a shape — the only difference is the cached payload (a snippet list vs an
  orientation pack) and the explicit `blast_radius` argument on the put (a snippet
  list carries no blast radius of its own, unlike a `Kazi.Context.Pack`).
  """

  alias Kazi.Retrieval.Snippet

  @doc """
  Fetches the cached snippet list for `cache_key`, applying blast-radius
  invalidation against `current_blast_radius`. Returns the snippets on a fresh hit,
  else `nil`.
  """
  @callback get_cached_snippets(
              cache_key :: String.t(),
              current_blast_radius :: [String.t()]
            ) :: [Snippet.t()] | nil

  @doc """
  Stores `snippets` under `cache_key` for `(workspace, git_sha)`, recording
  `blast_radius` for the next `get_cached_snippets/2`'s invalidation check. Returns
  `{:ok, _}` or `{:error, _}`; the caller ignores the return (a cache write is
  best-effort — a failed store just means the next retrieval is a miss).
  """
  @callback put_cached_snippets(
              cache_key :: String.t(),
              workspace :: String.t(),
              git_sha :: String.t(),
              snippets :: [Snippet.t()],
              blast_radius :: [String.t()]
            ) :: {:ok, term()} | {:error, term()}
end
