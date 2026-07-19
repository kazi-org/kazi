defmodule Kazi.Context do
  @moduledoc """
  The orientation-pack builder (T4.2, ADR-0010): from the failing predicates +
  the target workspace, produce a **bounded, ranked orientation pack** so each
  stateless `claude -p` call starts oriented instead of re-discovering where
  things live every iteration.

  ## Why this exists

  kazi invokes the harness as a fresh, stateless process per iteration and owns
  durable context itself (ADR-0008); the prompt is a thin projection of the
  failing-predicate evidence (ADR-0009). The deliberate cost of statelessness is
  **per-iteration re-exploration**: each fresh agent re-greps, re-reads, and
  re-orients in the workspace because it carries no memory from the last cycle.

  ADR-0010 splits the memory the stateless model discards into two kinds and keeps
  only one:

    * **Map memory** — *where things are* (structure, which files/symbols matter).
      Re-deriving this every iteration is pure loss; this builder injects it.
    * **Conversation memory** — *what we already tried* (the transcript). Dropping
      this is a feature: it is what the regression/stuck guards need gone to avoid
      anchoring on a dead end. This builder never reintroduces it.

  So an orientation pack is map memory only: impacted files/symbols, the failing
  test's source, and its callers/callees — no transcript, no history.

  ## Sources: graph when present, repo-map fallback (the hybrid)

  Per ADR-0010 the pack is built from `code-review-graph` when the target has a
  graph (`.code-review-graph/graph.db`), else an aider-style tree-sitter repo
  map. The graph gives ranked structure and call edges ~10x cheaper than
  grep+read; its weakness is source-level / macro-heavy detail, so source still
  comes from reading files (the intentional hybrid — do not go graph-only).

  The source is injected behind the `Kazi.Context.GraphSource` behaviour so the
  builder is **hermetic in tests** (no network, no live MCP call): pass a stub via
  `opts[:graph_source]`. The default, `Kazi.Context.RepoMapSource`, detects the
  graph and falls back to a pragmatic file-scan repo map — both real, no stub in
  `lib/`.

  ## Determinism (a hard requirement)

  T4.3 injects this pack as a **stable, cacheable prefix** of `build_prompt/2` and
  T4.6 caches it keyed on `(workspace, git-SHA, failing-set)`. Both require that
  the **same inputs produce a byte-identical pack**. So this builder:

    * sorts every collection by a stable key (never relies on map ordering),
    * carries no timestamps, randomness, or absolute-time data,
    * estimates tokens as `ceil(chars / 4)` (no tokenizer dependency), and
    * bounds the pack to an explicit `:token_budget` (default `4_000`),
      truncating lowest-ranked entries first.

  `render/1` turns a pack into the deterministic text T4.3 prepends to the prompt;
  `cache_key/3` is the stable key T4.6 stores it under.

  ## Public surface (for Wave 14)

    * `orientation_pack/3` — build a `Kazi.Context.Pack` from failing predicates +
      workspace.
    * `render/1` — render a pack to deterministic prompt text.
    * `cache_key/3` — the stable cache key for `(workspace, git_sha, failing)`.
    * `cached_orientation_pack/4` — `orientation_pack/3` behind the SHA-keyed
      read-model cache (T4.6): reuse on a fresh hit, build + store on a miss or a
      blast-radius change.
  """

  alias Kazi.Context.{Pack, RepoMapSource, Symbol}
  alias Kazi.{Predicate, PredicateResult}

  @default_token_budget 4_000
  @default_cache Kazi.ReadModel

  @typedoc """
  The failing slice handed in each iteration: `{predicate_id, result}` pairs (the
  output of `Kazi.PredicateVector.failing/1` zipped with their results). The
  evidence map on each result seeds ranking — files and symbols *named in the
  failure output* rank highest, since that is where the fix lives.
  """
  @type failing :: [{Predicate.id(), PredicateResult.t()}]

  @typedoc """
  Build options:

    * `:token_budget` — hard ceiling on the pack's estimated tokens
      (`ceil(chars/4)`); lowest-ranked entries are dropped to fit. Defaults to
      `#{@default_token_budget}`.
    * `:graph_source` — a module implementing `Kazi.Context.GraphSource`, or a
      `{module, init_opts}` tuple. Injected for hermetic tests. Defaults to
      `Kazi.Context.RepoMapSource`.
  """
  @type opts :: [token_budget: pos_integer(), graph_source: module() | {module(), keyword()}]

  @doc """
  Builds a bounded, ranked orientation `Kazi.Context.Pack` from the `failing`
  predicates and the target `workspace`.

  Deterministic and hermetic: with the same inputs and the same `:graph_source`
  it returns a byte-identical pack (`render/1` is stable), and it performs no
  network or live-MCP access — the graph/repo-map seam is injected.

  Ranking, highest first: files and symbols **named in the failure evidence**,
  then their callers/callees (one structural hop), then the rest of the repo map,
  each tier sorted by a stable key. The pack is truncated to `:token_budget`,
  dropping the lowest-ranked entries first.

  The orientation source is injected via `opts[:graph_source]` (see
  `Kazi.Context.GraphSource`); the test suite exercises both the graph-present and
  repo-map-fallback paths over a fixture repo.
  """
  @spec orientation_pack(failing(), String.t(), opts()) :: Pack.t()
  def orientation_pack(failing, workspace, opts \\ [])
      when is_list(failing) and is_binary(workspace) and is_list(opts) do
    budget = Keyword.get(opts, :token_budget, @default_token_budget)
    {source_mod, source_opts} = resolve_source(Keyword.get(opts, :graph_source, RepoMapSource))

    evidence_terms = evidence_terms(failing)
    survey = source_mod.survey(workspace, evidence_terms, source_opts)

    files = rank_files(survey.files, evidence_terms)
    symbols = rank_symbols(survey.symbols, evidence_terms)
    test_sources = stable_sort(survey.test_sources, & &1.path)

    %Pack{
      origin: survey.origin,
      files: files,
      symbols: symbols,
      test_sources: test_sources,
      token_budget: budget
    }
    |> Pack.truncate_to_budget(budget)
  end

  @doc """
  Renders a `Kazi.Context.Pack` to the deterministic orientation text T4.3
  prepends to the prompt as a stable, cacheable prefix (ADR-0010).

  The output is a pure function of the pack: identical packs render to
  byte-identical strings. An empty pack renders to a stable empty-orientation
  marker so the prefix shape never depends on whether the graph had anything.

  ## Examples

      iex> pack = %Kazi.Context.Pack{origin: :repo_map, files: [], symbols: [], test_sources: []}
      iex> Kazi.Context.render(pack) =~ "# Orientation"
      true
  """
  @spec render(Pack.t()) :: String.t()
  def render(%Pack{} = pack), do: Pack.render(pack)

  @doc """
  The stable cache key for an orientation pack, for the SHA-keyed read-model cache
  (T4.6, ADR-0010). Keyed on the workspace, the git SHA, and the failing-predicate
  **set** (order-independent): two iterations at the same SHA failing the same
  predicates share a key, so the cached pack — and its prompt prefix — is reused.

  ## Examples

      iex> failing = [{:b, Kazi.PredicateResult.fail()}, {:a, Kazi.PredicateResult.fail()}]
      iex> k1 = Kazi.Context.cache_key("/ws", "abc123", failing)
      iex> k2 = Kazi.Context.cache_key("/ws", "abc123", Enum.reverse(failing))
      iex> k1 == k2
      true
  """
  @spec cache_key(String.t(), String.t(), failing()) :: String.t()
  def cache_key(workspace, git_sha, failing)
      when is_binary(workspace) and is_binary(git_sha) and is_list(failing) do
    failing_ids =
      failing
      |> Enum.map(fn {id, _result} -> to_string(id) end)
      |> Enum.sort()
      |> Enum.join(",")

    payload = Enum.join([workspace, git_sha, failing_ids], "\n")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  @typedoc """
  Options for `cached_orientation_pack/4`. Extends `t:opts/0` with the cache seam:

    * `:cache` — a module implementing `Kazi.Context.Cache` (defaults to
      `Kazi.ReadModel`, the SQLite read-model). Injected for hermetic tests.
    * `:on_build` — a 0-arity function called each time the pure builder runs (a
      cache miss), so tests can assert a hit did **not** rebuild. Defaults to a
      no-op.

  Plus every option `orientation_pack/3` accepts (`:token_budget`,
  `:graph_source`), forwarded to the builder on a miss.
  """
  @type cache_opts ::
          [
            cache: module(),
            on_build: (-> any())
          ]
          | opts()

  @doc """
  `orientation_pack/3` behind the SHA-keyed read-model cache (T4.6, ADR-0010 §4).

  Caching is an optional layer over the pure builder. The flow:

    1. key = `cache_key(workspace, git_sha, failing)`.
    2. `Cache.get_cached_pack(key, current_blast_radius)` — on a **fresh hit** (an
       entry exists *and* its stored blast radius equals `current_blast_radius`)
       the cached pack is returned and the builder is **not** invoked.
    3. On a miss — no entry, or the blast radius changed (the cached pack is stale)
       — the pure builder runs, the fresh pack is stored under `key`, and returned.

  `current_blast_radius` is the impacted files/symbols the pack is scoped to *now*
  (e.g. the changed working set from the last iteration, T4.1, sorted). It is what
  drives incremental invalidation: at the same `(workspace, git-SHA, failing-set)`
  the key is identical, so a changed blast radius is what marks the cached pack
  stale and forces a rebuild.

  The cache is injected via `opts[:cache]` (default `Kazi.ReadModel`); tests pass
  an in-memory double, keeping this hermetic. The pure `orientation_pack/3` is
  unchanged and still usable directly when no cache is wanted.
  """
  @spec cached_orientation_pack(failing(), String.t(), [String.t()], cache_opts()) :: Pack.t()
  def cached_orientation_pack(failing, workspace, git_sha_and_radius, opts \\ [])

  def cached_orientation_pack(failing, workspace, {git_sha, current_blast_radius}, opts)
      when is_list(failing) and is_binary(workspace) and is_binary(git_sha) and
             is_list(current_blast_radius) and is_list(opts) do
    cache = Keyword.get(opts, :cache, @default_cache)
    on_build = Keyword.get(opts, :on_build, fn -> :ok end)
    builder_opts = Keyword.drop(opts, [:cache, :on_build])

    key = cache_key(workspace, git_sha, failing)

    case cache.get_cached_pack(key, current_blast_radius) do
      %Pack{} = cached ->
        cached

      nil ->
        on_build.()
        pack = orientation_pack(failing, workspace, builder_opts)
        _ = cache.put_cached_pack(key, workspace, git_sha, pack)
        pack
    end
  end

  # --- ranking & evidence extraction -------------------------------------------

  # The terms that drive ranking: every path-like / symbol-like token named in the
  # failing evidence. A file or symbol whose name appears here is where the fix
  # lives, so it ranks highest. Sorted + deduped for determinism.
  defp evidence_terms(failing) do
    failing
    |> Enum.flat_map(fn {id, %PredicateResult{evidence: evidence}} ->
      [to_string(id) | evidence_strings(evidence)]
    end)
    |> Enum.flat_map(&tokenize/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evidence_strings(evidence) do
    evidence
    |> Map.values()
    |> Enum.map(fn
      value when is_binary(value) -> value
      value -> inspect(value)
    end)
  end

  # Pulls path-ish and identifier-ish tokens out of free-form evidence text:
  # file paths (foo/bar.ex), dotted/qualified names, and bare identifiers.
  defp tokenize(text) do
    ~r{[A-Za-z0-9_./:-]+}
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(fn token ->
      trimmed = String.trim_trailing(token, ":")
      # foo.ex:3 -> drop a trailing :line so the path matches
      base = trimmed |> String.split(":") |> List.first()
      [trimmed, base] |> Enum.filter(&(String.length(&1) > 1))
    end)
    |> Enum.uniq()
  end

  # Files named in the evidence rank above the rest; within each tier, sort by
  # path so the order is stable regardless of the source's traversal order.
  defp rank_files(files, evidence_terms) do
    {hit, rest} = Enum.split_with(files, &mentions?(&1.path, evidence_terms))
    stable_sort(hit, & &1.path) ++ stable_sort(rest, & &1.path)
  end

  # Symbols defined in an impacted file, or named in the evidence, rank first;
  # then by {path, name} for a total, stable order.
  defp rank_symbols(symbols, evidence_terms) do
    {hit, rest} =
      Enum.split_with(symbols, fn %Symbol{name: name, path: path} ->
        mentions?(name, evidence_terms) or mentions?(path, evidence_terms)
      end)

    stable_sort(hit, &{&1.path, &1.name}) ++ stable_sort(rest, &{&1.path, &1.name})
  end

  defp mentions?(value, evidence_terms) when is_binary(value) do
    Enum.any?(evidence_terms, fn term ->
      term == value or String.contains?(value, term) or String.contains?(term, value)
    end)
  end

  defp mentions?(_value, _terms), do: false

  defp stable_sort(list, key_fun), do: Enum.sort_by(list, key_fun)

  # A graph_source opt may be a bare module or a {module, init_opts} tuple.
  defp resolve_source({mod, source_opts}) when is_atom(mod) and is_list(source_opts),
    do: {mod, source_opts}

  defp resolve_source(mod) when is_atom(mod), do: {mod, []}
end
