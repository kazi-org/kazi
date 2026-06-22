defmodule Kazi.Context.Cache do
  @moduledoc """
  The injectable orientation-pack cache seam (T4.6, ADR-0010 §4).

  `Kazi.Context.orientation_pack/3` is a pure builder; caching is an **optional
  layer** wrapped around it via this behaviour, so the builder stays pure and the
  cache stays hermetically testable. The production implementation,
  `Kazi.ReadModel`, stores packs in the SQLite read-model keyed on
  `Kazi.Context.cache_key/3`; tests inject an in-memory double, so no DB is needed
  to exercise the cache-hit / invalidation logic in isolation.

  ## Contract

    * `get/2` — return the cached `Kazi.Context.Pack` for `cache_key` **only on a
      fresh hit**: an entry exists and its stored blast radius still equals the
      `current_blast_radius` argument. Return `nil` on a miss or a blast-radius
      mismatch (the cached pack is stale), so the builder rebuilds.
    * `put/4` — store `pack` under `cache_key`, recording `workspace`/`git_sha` and
      the pack's blast radius (`Kazi.Context.Pack.blast_radius/1`) for the next
      `get/2`'s invalidation check. Idempotent: re-storing the same key replaces.

  `Kazi.ReadModel` implements both (`get_cached_pack/2`, `put_cached_pack/4`).
  """

  alias Kazi.Context.Pack

  @doc """
  Fetches the cached pack for `cache_key`, applying blast-radius invalidation
  against `current_blast_radius`. Returns the pack on a fresh hit, else `nil`.
  """
  @callback get_cached_pack(cache_key :: String.t(), current_blast_radius :: [String.t()]) ::
              Pack.t() | nil

  @doc """
  Stores `pack` under `cache_key` for `(workspace, git_sha)`. Returns `{:ok, _}` or
  `{:error, _}`; `Kazi.Context` ignores the return (a cache write is best-effort —
  a failed store just means the next build is a miss).
  """
  @callback put_cached_pack(
              cache_key :: String.t(),
              workspace :: String.t(),
              git_sha :: String.t(),
              pack :: Pack.t()
            ) :: {:ok, term()} | {:error, term()}
end
