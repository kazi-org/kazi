defmodule Kazi.Loop.Counters do
  @moduledoc """
  Per-iteration `context` + `tools` counters for the iteration event (T34.3,
  ADR-0046 §2).

  These make the ADR-0010/0045 caching claims FALSIFIABLE: a working stable
  orientation prefix should show the orientation cache flip `miss → hit` across
  iterations (rising cached reads) while the agent's `file_reads`/`search_calls`
  fall. Two complementary maps, attached to each iteration event:

    * **`context`** — what kazi spent on context for the dispatch that fed this
      iteration. kazi BUILDS the prompt, so it knows these exactly (no harness
      cooperation needed): the orientation/retrieval cache state (whether kazi
      re-sent a byte-identical prefix the inner harness's own cache can hit) and
      the per-section token estimates.

          %{ orientation_cache: "hit"|"miss"|"disabled",
             retrieval_cache:   "hit"|"miss"|"disabled",
             orientation_tokens: 0, evidence_tokens: 0, retrieval_tokens: 0 }

    * **`tools`** — what the agent DID, parsed from the harness result's tool-use
      stream where the harness exposes one:

          %{ tool_calls: 0, file_reads: 0, search_calls: 0, graph_calls: 0 }

  ## Reported vs. unreported (the honest-unknown rule, ADR-0046 §6)

  The two maps follow OPPOSITE presence rules because their signals differ:

    * `context` is ALWAYS fully populated — kazi owns the prompt, so a `0` here is
      a real, measured zero (e.g. orientation off ⇒ `orientation_tokens: 0` and
      `orientation_cache: "disabled"`), never "unknown".
    * `tools` is populated ONLY when the harness surfaced a tool-use signal
      (`result[:tool_uses]`). With a signal, every bucket is reported (an unused
      category is a real `0`); WITHOUT one (e.g. Claude's `--output-format json`
      envelope carries no per-tool breakdown) the map is EMPTY — absent, not
      zero-filled. A reader must treat an empty `tools` as "the harness reported
      no tool data", never "the agent made zero tool calls".

  Pure: no I/O. The cache-state comparison takes the PREVIOUS dispatch's prefix
  strings (threaded by `Kazi.Loop`); token estimates use the same tokenizer-free
  `ceil(chars / 4)` approximation the orientation pack uses (ADR-0010).
  """

  # Average chars-per-token, matching `Kazi.Context.Pack` (ADR-0010): good enough
  # to size a prompt section without pulling a tokenizer dependency.
  @chars_per_token 4

  @typedoc "An orientation/retrieval cache verdict for a dispatch."
  @type cache_state :: String.t()

  @typedoc "The per-iteration context counters (always fully populated)."
  @type context :: %{
          orientation_cache: cache_state(),
          retrieval_cache: cache_state(),
          orientation_tokens: non_neg_integer(),
          evidence_tokens: non_neg_integer(),
          retrieval_tokens: non_neg_integer()
        }

  @typedoc "The per-iteration tool counters (empty when the harness reported none)."
  @type tools :: %{optional(atom()) => non_neg_integer()}

  @doc """
  The context counters for a dispatch whose sections are `orientation` (the
  rendered prefix or `nil` when off), `evidence`, and `retrieval` (or `nil`),
  given the PREVIOUS dispatch's `prev_orientation` / `prev_retrieval` for the
  cache-hit comparison.

  The cache state is `"disabled"` when the section was not sent, `"hit"` when this
  dispatch re-sent a byte-identical section the inner harness's prompt cache can
  reuse (same blast radius ⇒ stable prefix, T19.2), and `"miss"` otherwise (the
  first dispatch, or a changed section). Token counts are `ceil(chars / 4)`; an
  absent section is a real `0`.
  """
  @spec context(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) ::
          context()
  def context(orientation, evidence, retrieval, prev_orientation, prev_retrieval) do
    %{
      orientation_cache: cache_state(orientation, prev_orientation),
      retrieval_cache: cache_state(retrieval, prev_retrieval),
      orientation_tokens: estimate_tokens(orientation),
      evidence_tokens: estimate_tokens(evidence),
      retrieval_tokens: estimate_tokens(retrieval)
    }
  end

  @doc """
  The all-zero / all-disabled context map for an iteration with NO preceding
  dispatch (the first observation): no context was spent, every cache is off.
  """
  @spec empty_context() :: context()
  def empty_context, do: context(nil, nil, nil, nil, nil)

  @doc """
  The tool counters parsed from a harness `result`, classified into
  `tool_calls` / `file_reads` / `search_calls` / `graph_calls`.

  Reads `result[:tool_uses]` — a list of tool-use names (strings) or block maps
  carrying a `"name"`/`:name`/`"tool"` — that a profile surfaced from its envelope.
  When present, EVERY bucket is reported (an unused category is a real `0`). When
  absent (the harness exposed no tool-use stream), returns `%{}` — the counters
  are unreported, not zero (ADR-0046 honest-unknown).
  """
  @spec tools(Kazi.HarnessAdapter.result() | map()) :: tools()
  def tools({:ok, %{} = result}), do: tools(result)
  def tools({:error, _}), do: %{}

  def tools(%{} = result) do
    case Map.get(result, :tool_uses) do
      uses when is_list(uses) -> classify(uses)
      _ -> %{}
    end
  end

  def tools(_), do: %{}

  @doc """
  Estimate a string's token count as `ceil(chars / 4)` (ADR-0010). `nil` and the
  empty string are `0`.
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    chars = String.length(text)
    div(chars + @chars_per_token - 1, @chars_per_token)
  end

  # A section's cache verdict: not sent ⇒ "disabled"; byte-identical to the prior
  # dispatch's section ⇒ "hit" (the inner harness's prompt cache can reuse it);
  # otherwise ⇒ "miss" (a fresh or changed prefix the cache cannot hit).
  @spec cache_state(String.t() | nil, String.t() | nil) :: cache_state()
  defp cache_state(nil, _prev), do: "disabled"
  defp cache_state(current, current) when is_binary(current), do: "hit"
  defp cache_state(current, _prev) when is_binary(current), do: "miss"

  # Bucket a tool-use stream by tool name. A non-empty stream yields all four
  # counters (an unused category is a measured 0); an empty list still yields the
  # zeros, since presence of the (empty) stream IS a report of "no tool calls".
  @spec classify([term()]) :: tools()
  defp classify(uses) do
    names = uses |> Enum.map(&tool_name/1) |> Enum.reject(&is_nil/1)

    %{
      tool_calls: length(names),
      file_reads: Enum.count(names, &file_read?/1),
      search_calls: Enum.count(names, &search?/1),
      graph_calls: Enum.count(names, &graph?/1)
    }
  end

  # Normalize one tool-use entry to its tool name: a bare string, or a block map
  # carrying it under "name"/:name/"tool". Anything else is dropped (nil).
  @spec tool_name(term()) :: String.t() | nil
  defp tool_name(name) when is_binary(name), do: name

  defp tool_name(%{} = block) do
    case block["name"] || block[:name] || block["tool"] || block[:tool] do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp tool_name(_), do: nil

  # File-read tools across harness tool taxonomies.
  defp file_read?(name) do
    String.downcase(name) in ["read", "view", "read_file", "openfile", "cat"]
  end

  # Search / grep tools (the "rediscovery" calls a stable prefix should reduce).
  defp search?(name) do
    String.downcase(name) in ["grep", "glob", "search", "search_files", "find", "ripgrep"]
  end

  # Code-graph / semantic-navigation tools (the code-review-graph MCP surface).
  defp graph?(name) do
    n = String.downcase(name)

    String.contains?(n, "graph") or String.contains?(n, "semantic_search") or
      String.contains?(n, "impact_radius") or String.contains?(n, "review_context")
  end
end
