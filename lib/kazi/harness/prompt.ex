defmodule Kazi.Harness.Prompt do
  @moduledoc """
  Harness-neutral prompt construction (ADR-0016): the work item plus a concise,
  actionable rendering of what must become true, seeded with failing-predicate
  evidence (concept §5).

  This module is **vendor-neutral by construction** — it builds the prompt text
  every `Kazi.HarnessAdapter` dispatches, and `Kazi.Loop` reuses the SAME renderer
  so the prompt is byte-identical regardless of which harness (Claude, opencode,
  Codex, …) the generic `Kazi.Harness.CliAdapter` drives. Nothing here is
  Claude-specific; the per-harness divergence (argv assembly, stdout parsing)
  lives in the harness profile (`Kazi.Harness.Profile`), not in prompt text.

  Three pieces are public:

    * `build_prompt/2` / `build_prompt/3` — the focused dispatch prompt: the work
      item, the failing-predicate evidence, an optional **stable orientation
      prefix** (ADR-0010 §3), and an optional **retrieval section** (ADR-0012),
      both purely additive.
    * `render_retrieval_section/1` — renders retrieved snippets as one
      clearly-delimited section, shared with `Kazi.Loop` so there is one renderer
      and no drift.
    * `truncate_evidence/2` — bounds a piece of evidence/tool-result text to a
      byte budget at the seam, before it reaches the prompt body (T4.8).

  All functions are PURE and total so they can be tested directly. No function
  here shells out — running the harness is the adapter's job.
  """

  alias Kazi.Context
  alias Kazi.Context.Pack
  alias Kazi.PredicateResult
  alias Kazi.Retrieval
  alias Kazi.Retrieval.Snippet

  # Default byte budget for a single piece of truncated evidence (T4.8). Sized so
  # a head+tail window keeps the failing signal and its resolution legible while
  # bounding a runaway log/diff. Override per-call with `truncate_evidence/2`'s
  # `:max_bytes`. Chosen as a conservative ~8 KiB; the loop's cross-iteration
  # token ceiling (T1.4) is the coarse backstop, this is the fine one.
  @default_evidence_max_bytes 8_192

  # Marker bridging the kept head and tail of truncated evidence. Greppable so a
  # downstream reader (human or harness) can see the cut was intentional.
  @truncation_marker "\n…truncated…\n"

  @doc """
  Builds the focused prompt seeded with failing-predicate evidence (concept §5):
  the work item plus a concise, actionable rendering of what must become true.

  Pure and total so it can be tested directly. `failing` is a list of
  `{id, %Kazi.PredicateResult{}}` pairs — the failing slice of a
  `Kazi.PredicateVector` and their evidence — which the loop hands the adapter so
  the agent gets *only* the failing-predicate evidence as context (concept §86).

  ## Examples

      iex> failing = [{:unit, Kazi.PredicateResult.fail(%{output: "1 test, 1 failure"})}]
      iex> prompt = Kazi.Harness.Prompt.build_prompt("Make the suite green", failing)
      iex> prompt =~ "Make the suite green" and prompt =~ "unit" and prompt =~ "1 failure"
      true
  """
  @spec build_prompt(String.t(), [{Kazi.Predicate.id(), PredicateResult.t()}]) :: String.t()
  def build_prompt(work_item, failing) when is_binary(work_item) and is_list(failing) do
    build_prompt(work_item, failing, [])
  end

  @doc """
  Builds the focused prompt with an optional **stable orientation prefix**
  prepended to the failing-evidence body (T4.3, ADR-0010 §3).

  The orientation prefix is the rendered `Kazi.Context.Pack` — kazi's pre-computed
  map memory of *where this work lives* (impacted files/symbols, the failing
  test's source). It is the cacheable **head** of the prompt; the
  failing-evidence section (`render_failing/1`/`render_evidence/1`) is the
  volatile **tail**, byte-for-byte the same as `build_prompt/2` produces. Splitting
  the prompt this way lets the harness's prompt cache hit the prefix across
  iterations that share a `(git-sha, failing-set)` (ADR-0010): for the same
  inputs the prefix is byte-identical, because the pack carries no timestamps,
  run ids, or randomness (the determinism `Kazi.Context.orientation_pack/3`
  guarantees, preserved end-to-end here).

  The prefix is supplied through `opts`, and is **purely additive** — with no
  context opt this returns exactly what `build_prompt/2` returns:

    * `:context_pack` — a pre-built `Kazi.Context.Pack` (e.g. the cached pack from
      T4.6). Rendered as-is; takes precedence over `:workspace`.
    * `:workspace` — a target directory; the pack is built on demand via
      `Kazi.Context.orientation_pack/3` from `failing` + this workspace.
      `:graph_source` and `:token_budget` are threaded through to the builder
      (so tests inject a hermetic source — no network, no live MCP).

  An empty pack still renders to a stable empty-orientation marker, so the prefix
  shape never depends on whether the source found anything — keeping the head
  cacheable even on a sparse workspace.

  ## Optional retrieval section (T4.9a, ADR-0012)

  When a `Kazi.Retrieval` backend is injected via `:retriever` (or configured), its
  top-k snippets are appended as a clearly-delimited
  `## Relevant prior context (retrieved)` section AFTER the orientation prefix and
  the failing-evidence body — augmenting, never replacing them. Retrieval is OFF by
  default: the resolved default is the no-op (`Kazi.Retrieval.NoOp`, returns `[]`),
  and an empty result appends NOTHING, so with no `:retriever` opt this returns
  exactly what `build_prompt/2` returns — byte-identical to the pre-retrieval path.

    * `:retriever` — a `Kazi.Retrieval` module or `{module, init_opts}` tuple. The
      backend's `retrieve/3` is called with `failing`, the dispatch `:workspace`
      (or `""` when none is supplied), and `init_opts`.

  ## Examples

      iex> pack = %Kazi.Context.Pack{origin: :repo_map, files: [Kazi.Context.FileRef.new("lib/a.ex")]}
      iex> prompt = Kazi.Harness.Prompt.build_prompt("fix it", [], context_pack: pack)
      iex> prompt =~ "# Orientation" and prompt =~ "lib/a.ex" and prompt =~ "fix it"
      true
  """
  @spec build_prompt(String.t(), [{Kazi.Predicate.id(), PredicateResult.t()}], keyword()) ::
          String.t()
  def build_prompt(work_item, failing, opts)
      when is_binary(work_item) and is_list(failing) and is_list(opts) do
    body = build_evidence_prompt(work_item, failing)

    prompt =
      case orientation_prefix(failing, opts) do
        nil -> body
        prefix -> prefix <> "\n\n" <> body
      end

    case retrieval_section(failing, opts) do
      nil -> prompt
      section -> prompt <> "\n\n" <> section
    end
  end

  # The failing-evidence prompt: the work item plus the rendered failing-predicate
  # evidence. This IS `build_prompt/2`'s output verbatim — the volatile tail the
  # orientation prefix sits in front of, kept unchanged so callers (and the prompt
  # cache) see the same evidence section with or without a prefix.
  @spec build_evidence_prompt(String.t(), [{Kazi.Predicate.id(), PredicateResult.t()}]) ::
          String.t()
  defp build_evidence_prompt(work_item, failing) do
    header =
      "#{work_item}\n\n" <>
        "The following predicates are currently failing. Make each one pass. " <>
        "Change the code under test, not the checks themselves.\n"

    body =
      failing
      |> Enum.map(&render_failing/1)
      |> Enum.join("\n")

    case body do
      "" -> String.trim_trailing(header)
      _ -> header <> "\n" <> body
    end
  end

  # Resolve the orientation prefix from opts, additively: a pre-built
  # `:context_pack` wins; else build one from `:workspace` + `failing`; else no
  # prefix at all (back-compat with `build_prompt/2`). The rendered prefix is a
  # pure function of the pack, so it is byte-identical for the same inputs.
  @spec orientation_prefix([{Kazi.Predicate.id(), PredicateResult.t()}], keyword()) ::
          String.t() | nil
  defp orientation_prefix(failing, opts) do
    case context_pack(failing, opts) do
      %Pack{} = pack -> Context.render(pack)
      nil -> nil
    end
  end

  @spec context_pack([{Kazi.Predicate.id(), PredicateResult.t()}], keyword()) :: Pack.t() | nil
  defp context_pack(failing, opts) do
    case Keyword.get(opts, :context_pack) do
      %Pack{} = pack ->
        pack

      nil ->
        case Keyword.get(opts, :workspace) do
          workspace when is_binary(workspace) ->
            Context.orientation_pack(failing, workspace, pack_opts(opts))

          _ ->
            nil
        end
    end
  end

  # Thread only the orientation-builder options through to
  # `Kazi.Context.orientation_pack/3`, so the adapter does not reshape the pack.
  defp pack_opts(opts), do: Keyword.take(opts, [:graph_source, :token_budget])

  # =============================================================================
  # Optional retrieval section (T4.9a, ADR-0012)
  # =============================================================================

  # Resolve the optional retrieval augmentation, additively: run the resolved
  # `Kazi.Retrieval` backend (explicit `:retriever` opt > config > the no-op
  # default) and render any snippets it returns. The no-op default returns `[]`, so
  # with no retriever this is `nil` and NOTHING is appended — keeping the default
  # output byte-identical to the pre-retrieval path (ADR-0012's central constraint).
  @spec retrieval_section([{Kazi.Predicate.id(), PredicateResult.t()}], keyword()) ::
          String.t() | nil
  defp retrieval_section(failing, opts) do
    case Retrieval.retrieve(failing, retrieval_workspace(opts), opts) do
      [] -> nil
      snippets when is_list(snippets) -> render_retrieval_section(snippets)
    end
  end

  # The workspace the retriever queries against. Reuses the same `:workspace` opt
  # the orientation builder reads; absent it, retrieval runs workspace-less (a
  # backend that needs one returns `[]`). Never crashes the pure prompt builder.
  defp retrieval_workspace(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) -> workspace
      _ -> ""
    end
  end

  @doc """
  Renders retrieved `Kazi.Retrieval.Snippet`s as a single clearly-delimited
  section (T4.9a, ADR-0012): a fixed `## Relevant prior context (retrieved)`
  heading (greppable, cache-stable) over each snippet's source attribution (when
  present) above a fenced text block.

  Public so the convergence loop (`Kazi.Loop`, T4.9c) appends the SAME section to
  its dispatch prompt that `build_prompt/3` produces — one renderer, no drift. The
  caller is responsible for placing it AFTER the orientation prefix and the
  failing-evidence body (it augments, never replaces them).
  """
  @spec render_retrieval_section([Snippet.t()]) :: String.t()
  def render_retrieval_section(snippets) when is_list(snippets) do
    "## Relevant prior context (retrieved)\n\n" <>
      "Similarity-retrieved snippets that may relate to the failing predicates. " <>
      "Use them as hints; the failing evidence above is authoritative.\n\n" <>
      Enum.map_join(snippets, "\n\n", &render_snippet/1)
  end

  defp render_snippet(%Snippet{text: text, source: nil}),
    do: "```\n" <> text <> "\n```"

  defp render_snippet(%Snippet{text: text, source: source}),
    do: "### " <> source <> "\n```\n" <> text <> "\n```"

  defp render_failing({id, %PredicateResult{status: status, evidence: evidence}}) do
    "## Failing predicate: #{id} (#{status})\n" <> render_evidence(evidence)
  end

  defp render_evidence(evidence) when map_size(evidence) == 0,
    do: "(no evidence captured)"

  defp render_evidence(evidence) do
    evidence
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{stringify(value)}" end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  # =============================================================================
  # claw-code hygiene: evidence truncation (T4.8, UC-009/UC-022)
  # =============================================================================

  @doc """
  Bounds a piece of evidence (or any tool-result text) to a byte budget,
  preserving the head and tail around a `…truncated…` marker.

  Pure and total so it can be tested directly and applied at the seam *before*
  evidence reaches the prompt body — the prompt construction (`build_prompt/2`)
  is left untouched. Oversized evidence (a multi-megabyte test log, a giant
  diff) would otherwise blow the per-dispatch token ceiling and drown the actual
  failure signal; keeping a head and a tail retains both the failure and the
  context around its resolution.

  `max_bytes` is the inclusive ceiling on the returned string's byte size
  (`#{@default_evidence_max_bytes}` by default). Input at or under the budget is
  returned verbatim. A budget too small to fit even the marker degrades to a
  plain head-truncation to the budget — never larger than asked.

  Truncation is byte-oriented (the budget is a token/size proxy) but the cut is
  nudged off any multi-byte UTF-8 boundary so the head and tail stay valid
  strings.

  ## Examples

      iex> Kazi.Harness.Prompt.truncate_evidence("short", max_bytes: 1_024)
      "short"

      iex> big = String.duplicate("x", 10_000)
      iex> out = Kazi.Harness.Prompt.truncate_evidence(big, max_bytes: 100)
      iex> byte_size(out) <= 100 and out =~ "…truncated…"
      true
  """
  @spec truncate_evidence(binary(), keyword()) :: binary()
  def truncate_evidence(evidence, opts \\ []) when is_binary(evidence) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_evidence_max_bytes)
    truncate_to(evidence, max_bytes)
  end

  # Within budget: return verbatim.
  defp truncate_to(evidence, max_bytes) when byte_size(evidence) <= max_bytes,
    do: evidence

  defp truncate_to(evidence, max_bytes) do
    marker_size = byte_size(@truncation_marker)

    if max_bytes <= marker_size do
      # No room for a head+tail+marker window — degrade to a head-only cut that
      # still honours the ceiling. Slice on a codepoint boundary so we never emit
      # a half a multi-byte char, then guarantee we are at or under the budget.
      head_only(evidence, max_bytes)
    else
      # Split the remaining budget into a head and a tail around the marker; bias
      # the extra odd byte to the head (the failure usually leads).
      budget = max_bytes - marker_size
      tail_bytes = div(budget, 2)
      head_bytes = budget - tail_bytes

      head = take_head(evidence, head_bytes)
      tail = take_tail(evidence, tail_bytes)
      head <> @truncation_marker <> tail
    end
  end

  # Largest valid-UTF-8 prefix of `evidence` no longer than `n` bytes.
  @spec take_head(binary(), non_neg_integer()) :: binary()
  defp take_head(_evidence, 0), do: ""

  defp take_head(evidence, n) do
    case evidence do
      <<head::binary-size(^n), _rest::binary>> -> trim_trailing_partial_codepoint(head)
      _ -> evidence
    end
  end

  # Largest valid-UTF-8 suffix of `evidence` no longer than `n` bytes.
  @spec take_tail(binary(), non_neg_integer()) :: binary()
  defp take_tail(_evidence, 0), do: ""

  defp take_tail(evidence, n) do
    size = byte_size(evidence)

    if n >= size do
      evidence
    else
      skip = size - n
      <<_dropped::binary-size(^skip), tail::binary>> = evidence
      trim_leading_partial_codepoint(tail)
    end
  end

  # Head-only fallback when the budget cannot fit the marker: a UTF-8-safe prefix
  # at or under `max_bytes`.
  @spec head_only(binary(), non_neg_integer()) :: binary()
  defp head_only(_evidence, max_bytes) when max_bytes <= 0, do: ""
  defp head_only(evidence, max_bytes), do: take_head(evidence, max_bytes)

  # Drop a trailing byte sequence that is a truncated (incomplete) UTF-8
  # codepoint, so a byte-sliced head is always a valid String. At most 3 bytes of
  # a multi-byte sequence can dangle.
  @spec trim_trailing_partial_codepoint(binary()) :: binary()
  defp trim_trailing_partial_codepoint(bin) do
    if String.valid?(bin), do: bin, else: trim_trailing_partial_codepoint(chop_last_byte(bin))
  end

  # Drop a leading partial-codepoint continuation so a byte-sliced tail is valid.
  @spec trim_leading_partial_codepoint(binary()) :: binary()
  defp trim_leading_partial_codepoint(bin) do
    if String.valid?(bin), do: bin, else: trim_leading_partial_codepoint(chop_first_byte(bin))
  end

  defp chop_last_byte(<<>>), do: <<>>

  defp chop_last_byte(bin) do
    n = byte_size(bin) - 1
    <<head::binary-size(^n), _last>> = bin
    head
  end

  defp chop_first_byte(<<>>), do: <<>>
  defp chop_first_byte(<<_first, rest::binary>>), do: rest
end
