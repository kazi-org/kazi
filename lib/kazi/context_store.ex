defmodule Kazi.ContextStore do
  @moduledoc """
  The context-store seam (T35.1, ADR-0045): budget-fitted retrieval over heavy text
  artifacts and repeated loop evidence.

  ## A distinct layer, off by default

  The context store is a *third* context layer, named and configured separately from
  the other two (ADR-0045 §1):

    * the structural **orientation pack** (`Kazi.Context`, ADR-0010) — *where things
      are* (code-review-graph / repo-map),
    * optional **semantic retrieval** (`Kazi.Retrieval`, ADR-0012) — *embedding
      recall* of prior context,
    * the **context store** (this module) — *heavy docs / logs / specs / transcripts
      under a byte budget*.

  Three names, three jobs; `context_store` and `retrieval` are distinct config keys
  that never alias. Like retrieval, the store is **off by default**: with no store
  injected or configured, `resolve/1` yields `Kazi.ContextStore.NoOp`, whose
  `search/3` returns `{:ok, []}` and whose `index/3` stores nothing — so the default
  loop is byte-identical to today and convergence semantics are unchanged
  (ADR-0045 §6, additive-JSON-only). A backend (the Gist CLI adapter, T35.2) is
  engaged only when explicitly opted in.

  ## The behaviour

  Three callbacks, mirroring the eventual `gist index` / `gist search --budget N` /
  `gist stats` surface (ADR-0045 §2):

    * `index/3` — store `content` under a stable source label (see
      `Kazi.ContextStore.Labels`). The store keeps the bytes; the loop state keeps
      only the label + checksum + byte count (ADR-0045 §3, evidence compression).
    * `search/3` — return only budget-fitting, ranked `Kazi.ContextStore.Snippet`s
      for a query, capped at `budget` bytes.
    * `stats/1` — report the store's byte accounting (`indexed_bytes` /
      `returned_bytes` / `saved_bytes`), the additive `context_store` JSON object
      (ADR-0045 §6) the economy work (ADR-0046) reports its win through.

  ## Resolution order

  `resolve/1` mirrors `Kazi.Retrieval.resolve/1` and the `Kazi.Context.GraphSource`
  precedence: an explicit `:context_store` opt wins; else the
  `config :kazi, :context_store` application env; else the no-op default. A store may
  be a bare module or a `{module, init_opts}` tuple — the init opts are forwarded to
  the callbacks as `opts`, so a test double or a configured backend can carry its
  provider options inline.
  """

  alias Kazi.ContextStore.{Labels, NoOp, Snippet}

  @typedoc """
  A context store: a module implementing this behaviour, or a `{module, init_opts}`
  tuple whose `init_opts` are forwarded to the callbacks.
  """
  @type t :: module() | {module(), keyword()}

  @typedoc """
  The result of indexing one artifact: the source label it was stored under, the
  byte size of the content, and an optional content checksum for staleness checks.
  """
  @type index_result :: %{
          required(:label) => Labels.label(),
          required(:bytes) => non_neg_integer(),
          optional(:checksum) => String.t() | nil
        }

  @typedoc """
  The store's byte accounting — the additive `context_store` JSON object
  (ADR-0045 §6). `:saved_bytes` is `indexed_bytes - returned_bytes`.
  """
  @type stats_map :: %{
          required(:provider) => atom() | String.t(),
          required(:indexed_bytes) => non_neg_integer(),
          required(:returned_bytes) => non_neg_integer(),
          required(:saved_bytes) => integer()
        }

  @doc """
  Indexes `content` under the stable source `label` (see `Kazi.ContextStore.Labels`).

  `opts` is the backend's own options (a test double's recorded state, or the real
  backend's provider config). Returns `{:ok, index_result()}` or `{:error, term()}`.
  The no-op default stores nothing and reports zero bytes.
  """
  @callback index(label :: Labels.label(), content :: String.t(), opts :: keyword()) ::
              {:ok, index_result()} | {:error, term()}

  @doc """
  Returns only the budget-fitting, ranked snippets for `query`, capped at `budget`
  bytes total. Returns `{:ok, [Snippet.t()]}` or `{:error, term()}`. The no-op
  default returns `{:ok, []}`.
  """
  @callback search(query :: String.t(), budget :: non_neg_integer(), opts :: keyword()) ::
              {:ok, [Snippet.t()]} | {:error, term()}

  @doc """
  Reports the store's byte accounting. Returns `{:ok, stats_map()}` or
  `{:error, term()}`.
  """
  @callback stats(opts :: keyword()) :: {:ok, stats_map()} | {:error, term()}

  @doc """
  Resolves a context store to a `{module, init_opts}` tuple per the documented
  precedence: explicit `:context_store` opt > `config :kazi, :context_store` > the
  no-op default. The returned shape is always normalised so callers can `apply/3`
  it directly.

  ## Examples

      iex> Kazi.ContextStore.resolve([])
      {Kazi.ContextStore.NoOp, []}

      iex> Kazi.ContextStore.resolve(context_store: {Some.Store, [budget: 6000]})
      {Some.Store, [budget: 6000]}
  """
  @spec resolve(keyword()) :: {module(), keyword()}
  def resolve(opts) when is_list(opts) do
    store =
      Keyword.get(opts, :context_store) ||
        Application.get_env(:kazi, :context_store) ||
        NoOp

    normalize(store)
  end

  @doc """
  Resolves a store (via `resolve/1`) and invokes its `index/3`. With no
  `:context_store` opt and no config this resolves to the no-op (stores nothing).
  """
  @spec index(Labels.label(), String.t(), keyword()) :: {:ok, index_result()} | {:error, term()}
  def index(label, content, opts \\ [])
      when is_binary(label) and is_binary(content) and is_list(opts) do
    {module, init_opts} = resolve(opts)
    module.index(label, content, init_opts)
  end

  @doc """
  Resolves a store (via `resolve/1`) and invokes its `search/3`. With no
  `:context_store` opt and no config this resolves to the no-op (returns
  `{:ok, []}`).
  """
  @spec search(String.t(), non_neg_integer(), keyword()) ::
          {:ok, [Snippet.t()]} | {:error, term()}
  def search(query, budget, opts \\ [])
      when is_binary(query) and is_integer(budget) and budget >= 0 and is_list(opts) do
    {module, init_opts} = resolve(opts)
    module.search(query, budget, init_opts)
  end

  @doc """
  Resolves a store (via `resolve/1`) and invokes its `stats/1`.
  """
  @spec stats(keyword()) :: {:ok, stats_map()} | {:error, term()}
  def stats(opts \\ []) when is_list(opts) do
    {module, init_opts} = resolve(opts)
    module.stats(init_opts)
  end

  # A store may be a bare module or a {module, init_opts} tuple.
  @spec normalize(t()) :: {module(), keyword()}
  defp normalize({mod, init_opts}) when is_atom(mod) and is_list(init_opts),
    do: {mod, init_opts}

  defp normalize(mod) when is_atom(mod), do: {mod, []}
end
