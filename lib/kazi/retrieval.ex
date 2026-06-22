defmodule Kazi.Retrieval do
  @moduledoc """
  The injectable semantic-retrieval seam (T4.9a, ADR-0012): given the failing
  predicates and a workspace, return the top-k most relevant prior-context
  `Kazi.Retrieval.Snippet`s to augment the harness prompt.

  ## Off by default — retrieval AUGMENTS, never replaces

  Retrieval is an *optional* augmentation layered on top of the deterministic
  contract: the orientation pack (`Kazi.Context`, ADR-0010) and the thin failing-
  evidence projection (ADR-0009). ADR-0012's central constraint is that enabling
  retrieval must not silently change the default loop: the resolved default here is
  a no-op (`Kazi.Retrieval.NoOp`) that returns `[]`, so the default
  `Kazi.Harness.ClaudeAdapter.build_prompt/3` output is **byte-identical** to the
  pre-retrieval path. A backend is engaged only when one is explicitly injected via
  opts or configured per goal.

  ## Why a behaviour

  Abstracting retrieval behind a behaviour is what keeps the suite hermetic. The
  real backend (graphify embeddings, T4.9b) embeds the target and does a similarity
  search — an external, heavyweight, non-deterministic dependency. Behind this seam
  the default path injects a pure double, so there is **no embedding model, no
  index, and no network** in the default `mix test` (ADR-0012: the real backend's
  conformance test is integration-tagged and excluded by default, like the NATS
  lease test). This mirrors the `Kazi.Context.GraphSource` injectable-seam pattern.

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
  """

  alias Kazi.PredicateResult
  alias Kazi.Retrieval.{NoOp, Snippet}

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

  # A retriever may be a bare module or a {module, init_opts} tuple.
  @spec normalize(t()) :: {module(), keyword()}
  defp normalize({mod, init_opts}) when is_atom(mod) and is_list(init_opts),
    do: {mod, init_opts}

  defp normalize(mod) when is_atom(mod), do: {mod, []}
end
