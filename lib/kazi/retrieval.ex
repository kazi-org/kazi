defmodule Kazi.Retrieval do
  @moduledoc """
  The injectable semantic-retrieval seam (T4.9a, ADR-0012): given the failing
  predicates and a workspace, return the top-k most relevant prior-context
  `Kazi.Retrieval.Snippet`s to augment the harness prompt.

  ## Off by default — no real backend ships, retrieval AUGMENTS

  Retrieval is an *optional* augmentation layered on top of the deterministic
  contract: the orientation pack (`Kazi.Context`, ADR-0010) and the thin failing-
  evidence projection (ADR-0009). **No real retrieval backend ships by default**:
  the resolved default here is a no-op (`Kazi.Retrieval.NoOp`) that returns `[]`, so
  the default `Kazi.Harness.ClaudeAdapter.build_prompt/3` output is
  **byte-identical** to the pre-retrieval path (ADR-0012's central constraint —
  enabling retrieval must not silently change the default loop). A backend is
  engaged only when a caller explicitly supplies one via opts or per-goal config. A
  supplied backend can wrap **any** tool that exposes an installable CLI/HTTP
  interface for embedding + similarity search; this seam deliberately hardcodes no
  particular tool.

  ## Why a behaviour

  Abstracting retrieval behind a behaviour is what keeps the suite hermetic. A real
  backend embeds the target and does a similarity search — an external, heavyweight,
  non-deterministic dependency. Behind this seam the default path injects a pure
  double, so there is **no embedding model, no index, and no network** in the
  default `mix test`. This mirrors the `Kazi.Context.GraphSource` injectable-seam
  pattern.

  An implementation SHOULD be deterministic given a fixed backend state: the same
  failing set + workspace should yield the same snippets, since enabling retrieval
  otherwise reintroduces prompt non-determinism for that goal (ADR-0012 accepts
  this only because it is opt-in and additive).

  ## Resolution order

  `resolve/1` mirrors the `:context_pack` / `GraphSource` precedence used by the
  adapter: an explicit `:retriever` opt wins; else the `config :kazi, :retriever`
  application env; else the no-op default. A retriever may be a bare module or a
  `{module, init_opts}` tuple (the init opts are forwarded as the callback's
  `opts`), so a test double can carry its fixed result inline.

  ## Cache reuse (T4.9c, ADR-0012 §4)

  `cached_retrieve/4` wraps `retrieve/3` behind the SHA-keyed cache (the SAME
  `Kazi.Context.cache_key/3` key + blast-radius invalidation as the T4.6
  orientation-pack cache), so an unchanged target reuses its snippets instead of
  re-embedding/re-retrieving. The cache is injected via `Kazi.Retrieval.Cache`
  (default `Kazi.ReadModel`); the plain `retrieve/3` is unchanged for callers that
  do not want caching.
  """

  alias Kazi.{Context, PredicateResult}
  alias Kazi.Retrieval.{NoOp, Snippet}

  @default_cache Kazi.ReadModel

  @typedoc """
  A retriever: a module implementing this behaviour, or a `{module, init_opts}`
  tuple whose `init_opts` are forwarded to `retrieve/3`.
  """
  @type t :: module() | {module(), keyword()}

  @doc """
  Retrieves the top-k relevant prior-context snippets for `failing` in `workspace`.

  `failing` is the failing slice of a `Kazi.PredicateVector` —
  `{id, %Kazi.PredicateResult{}}` pairs — the same shape the adapter renders into
  the evidence body, so a backend can query against the failing predicates' terms.
  `opts` is the backend's own options (e.g. a test double's fixed snippet list, or
  the real backend's `:top_k` / index path).

  Returns a (possibly empty) list of `Kazi.Retrieval.Snippet`s. The default
  resolution returns `[]`.
  """
  @callback retrieve(
              failing :: [{Kazi.Predicate.id(), PredicateResult.t()}],
              workspace :: String.t(),
              opts :: keyword()
            ) :: [Snippet.t()]

  @doc """
  Resolves a retriever to a `{module, init_opts}` tuple per the documented
  precedence: explicit `:retriever` opt > `config :kazi, :retriever` > the no-op
  default. Returned shape is always normalised so callers can `apply/3` it directly.

  ## Examples

      iex> Kazi.Retrieval.resolve([])
      {Kazi.Retrieval.NoOp, []}

      iex> Kazi.Retrieval.resolve(retriever: {Some.Mod, [top_k: 3]})
      {Some.Mod, [top_k: 3]}
  """
  @spec resolve(keyword()) :: {module(), keyword()}
  def resolve(opts) when is_list(opts) do
    retriever =
      Keyword.get(opts, :retriever) ||
        Application.get_env(:kazi, :retriever) ||
        NoOp

    normalize(retriever)
  end

  @doc """
  Resolves a retriever (via `resolve/1`) and invokes its `retrieve/3`, returning
  the list of `Kazi.Retrieval.Snippet`s. The volatile entry point the adapter
  calls; with no `:retriever` opt and no config this returns `[]` (the no-op).
  """
  @spec retrieve([{Kazi.Predicate.id(), PredicateResult.t()}], String.t(), keyword()) ::
          [Snippet.t()]
  def retrieve(failing, workspace, opts)
      when is_list(failing) and is_binary(workspace) and is_list(opts) do
    {module, init_opts} = resolve(opts)
    module.retrieve(failing, workspace, init_opts)
  end

  @typedoc """
  Options for `cached_retrieve/4`. Extends the retriever-resolution opts with the
  cache seam:

    * `:cache` — a module implementing `Kazi.Retrieval.Cache` (defaults to
      `Kazi.ReadModel`, the SQLite read-model). Injected for hermetic tests.
    * `:on_retrieve` — a 0-arity function called each time the underlying retriever
      actually runs (a cache miss), so a test can assert a hit did **not**
      re-retrieve. Defaults to a no-op.

  Plus every option `retrieve/3` resolves a retriever from (`:retriever`).
  """
  @type cache_opts :: [cache: module(), on_retrieve: (-> any()), retriever: t()]

  @doc """
  `retrieve/3` behind the SHA-keyed retrieval cache (T4.9c, ADR-0012 §4): reuse the
  cached snippets for an unchanged target instead of re-embedding and re-retrieving.

  This mirrors `Kazi.Context.cached_orientation_pack/4` exactly — same key, same
  blast-radius invalidation — so an iteration that already has a fresh orientation
  pack cached also has its retrieved snippets cached. The flow:

    1. key = `Kazi.Context.cache_key(workspace, git_sha, failing)` (the SAME key the
       orientation-pack cache uses; the snippet cache is a distinct table).
    2. `Cache.get_cached_snippets(key, current_blast_radius)` — on a **fresh hit**
       (an entry exists *and* its stored blast radius equals
       `current_blast_radius`) the cached snippets are returned and the retriever is
       **not** invoked (no re-embed).
    3. On a miss — no entry, or the blast radius changed (the cached snippets are
       stale) — the resolved retriever runs, the fresh snippets are stored under
       `key` with `current_blast_radius`, and returned.

  `current_blast_radius` is the impacted files/symbols the snippets are scoped to
  *now* (the same sorted set `Kazi.Context.Pack.blast_radius/1` yields for the
  orientation pack). At the same `(workspace, git-SHA, failing-set)` the key is
  identical, so a changed blast radius is what marks the cached snippets stale.

  The cache is injected via `opts[:cache]` (default `Kazi.ReadModel`); tests pass an
  in-memory double, keeping this hermetic. The plain `retrieve/3` is unchanged and
  still usable directly when no cache is wanted.
  """
  @spec cached_retrieve(
          [{Kazi.Predicate.id(), PredicateResult.t()}],
          String.t(),
          {String.t(), [String.t()]},
          cache_opts()
        ) :: [Snippet.t()]
  def cached_retrieve(failing, workspace, git_sha_and_radius, opts \\ [])

  def cached_retrieve(failing, workspace, {git_sha, current_blast_radius}, opts)
      when is_list(failing) and is_binary(workspace) and is_binary(git_sha) and
             is_list(current_blast_radius) and is_list(opts) do
    cache = Keyword.get(opts, :cache, @default_cache)
    on_retrieve = Keyword.get(opts, :on_retrieve, fn -> :ok end)
    retriever_opts = Keyword.drop(opts, [:cache, :on_retrieve])

    key = Context.cache_key(workspace, git_sha, failing)

    case cache.get_cached_snippets(key, current_blast_radius) do
      snippets when is_list(snippets) ->
        snippets

      nil ->
        on_retrieve.()
        snippets = retrieve(failing, workspace, retriever_opts)
        _ = cache.put_cached_snippets(key, workspace, git_sha, snippets, current_blast_radius)
        snippets
    end
  end

  # A retriever may be a bare module or a {module, init_opts} tuple.
  @spec normalize(t()) :: {module(), keyword()}
  defp normalize({mod, init_opts}) when is_atom(mod) and is_list(init_opts),
    do: {mod, init_opts}

  defp normalize(mod) when is_atom(mod), do: {mod, []}
end
