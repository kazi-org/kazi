defmodule Kazi.Harness.ClaudeAdapter do
  @moduledoc """
  The Slice 0 `Kazi.HarnessAdapter` implementation: drive `claude -p` as a
  non-interactive subprocess *in the target workspace* so the agent's edits land
  in place (ADR-0001, ADR-0003; concept §5).

  This is the thin, vendor-neutral harness boundary made concrete: a subprocess
  invoked with a focused prompt seeded with failing-predicate evidence, run with
  `cd:` set to the workspace, capturing exit status and output as the result the
  loop records and reasons about.

  ## Harness-agnostic by configuration

  The command is configurable (R4 mitigation): pass `:command` in opts, set
  `config :kazi, :harness_command`, or fall back to the default `"claude"`. The
  same shape drives Codex or any other `-p`-style harness, and tests inject a
  stub binary the same way — there is nothing Claude-specific in the wiring.

  ## Structured output + token accounting (T4.1, ADR-0010 §4)

  The harness is invoked with `--output-format json` (alongside `-p`) so each run
  yields a structured envelope — the real token usage, dollar cost, the agent's
  final result text, and (when the harness reports it) the touched working set —
  instead of raw text we would have to scrape. This is what lets the convergence
  loop account for the budget against REAL token spend (T1.4, UC-009) rather than
  an estimate, and it is the first measurement seam for the context-injection work
  (ADR-0010): the rest is tuned against these numbers (ADR-0008, "adopt soon").

  Parsing is best-effort and additive: the raw `output`/`exit`/`command`/
  `workspace` keys are ALWAYS present (back-compat with every prior caller), and
  the structured keys are merged in ONLY when the JSON parses and the field is
  present. A harness that emits non-JSON (or omits a field) degrades to exactly
  the old behaviour — the adapter never crashes on a malformed or surprising
  envelope.

  ## claw-code hygiene (T4.8, ADR-0010; UC-009/UC-022)

  Each stateless dispatch is run under least-privilege, bounded hygiene so a
  single iteration cannot quietly blow the goal's budget or be handed more
  authority than its work needs:

    * **Per-dispatch token/cost ceiling.** `:max_budget_usd` caps what one
      `claude -p` run is allowed to spend on its own API turns (passed through as
      `--max-budget-usd`). This is the harness's *own* hard stop, complementing
      the loop-level `Kazi.Budget` ceiling (T1.4) that accounts spend *across*
      iterations: even before the loop tallies the run, the harness refuses to
      overrun the per-dispatch ceiling.

    * **Evidence truncation.** Failing-predicate evidence and tool-result text
      can balloon (a multi-megabyte test log, a giant diff). `truncate_evidence/2`
      bounds any such blob to a byte budget — keeping a head and a tail around a
      `…truncated…` marker so both the failure signal and its resolution stay
      legible — *before* it reaches the prompt body. Callers truncate evidence at
      the seam; the prompt construction (`build_prompt/2`) is left untouched.

    * **Minimal per-goal tool/permission set.** Rather than the full default tool
      surface, a dispatch passes only the tools and permission mode the goal
      needs (`:allowed_tools`, `:permission_mode`), least privilege by default.

  All three are opt-in via `run/3` opts with back-compatible defaults: with no
  hygiene opts the args are exactly the pre-T4.8 `-p`/`--output-format json`
  shape, so every existing caller and test is unaffected.

  ## Result map

  On a successful invocation (the *process* ran; the agent may or may not have
  fixed anything — that is the predicates' job to judge later):

      {:ok, %{
        # Always present (back-compat):
        output: binary(),       # raw stdout (the JSON envelope verbatim)
        exit: integer(),
        command: binary(),
        workspace: binary(),
        # Present only when the JSON envelope parsed and carried the field:
        result: binary(),                   # the agent's final result text
        tokens: non_neg_integer(),          # total tokens (input + output + cache)
        cost_usd: float(),                  # real dollar cost of the run
        touched: [binary()],                # working set the harness reported touching
        cost: %{tokens: non_neg_integer()}  # token usage in the shape the loop's
                                            # T1.4 budget guard consumes
      }}

  The `:cost => %{tokens: n}` key is the contract the convergence loop reads to
  feed the budget (`Kazi.Loop` `token_estimate/1`); `:tokens`/`:cost_usd` are the
  flat, human-facing mirrors.

  When the harness could not be run at all (e.g. the binary is missing):

      {:error, {:command_not_found, binary()}}
      {:error, :empty_prompt}
  """

  @behaviour Kazi.HarnessAdapter

  alias Kazi.Context
  alias Kazi.Context.Pack
  alias Kazi.PredicateResult
  alias Kazi.Retrieval
  alias Kazi.Retrieval.Snippet

  @default_command "claude"

  # Default byte budget for a single piece of truncated evidence (T4.8). Sized so
  # a head+tail window keeps the failing signal and its resolution legible while
  # bounding a runaway log/diff. Override per-call with `truncate_evidence/2`'s
  # `:max_bytes`. Chosen as a conservative ~8 KiB; the loop's cross-iteration
  # token ceiling (T1.4) is the coarse backstop, this is the fine one.
  @default_evidence_max_bytes 8_192

  # Marker bridging the kept head and tail of truncated evidence. Greppable so a
  # downstream reader (human or harness) can see the cut was intentional.
  @truncation_marker "\n…truncated…\n"

  @impl true
  def run("", _workspace, _opts), do: {:error, :empty_prompt}

  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    command = command(opts)
    # `--output-format json` (T4.1) makes the harness emit a structured envelope
    # on stdout: real token usage, dollar cost, the agent's final result, and any
    # touched working set. `-p` still drives the non-interactive run. The hygiene
    # flags (T4.8) — per-dispatch budget ceiling + minimal tool/permission set —
    # are appended only when opted in, so the no-opts shape is byte-for-byte the
    # pre-T4.8 args (back-compat).
    args = ["-p", prompt, "--output-format", "json"] ++ hygiene_args(opts)

    try do
      {output, exit_status} =
        System.cmd(command, args,
          cd: workspace,
          stderr_to_stdout: true
        )

      base = %{
        output: output,
        exit: exit_status,
        command: command,
        workspace: workspace
      }

      # Best-effort, additive: merge the parsed structured fields over the
      # always-present base. A non-JSON / field-light envelope contributes
      # nothing, so the result degrades to exactly the pre-T4.1 shape.
      {:ok, Map.merge(base, parse_envelope(output))}
    rescue
      error in ErlangError ->
        # :enoent surfaces here when the configured binary is not on PATH —
        # an inability to run the harness, not failing work for the agent.
        case error.original do
          :enoent -> {:error, {:command_not_found, command}}
          other -> {:error, other}
        end
    end
  end

  @doc """
  Builds the focused prompt seeded with failing-predicate evidence (concept §5):
  the work item plus a concise, actionable rendering of what must become true.

  Pure and total so it can be tested directly. `failing` is a list of
  `{id, %Kazi.PredicateResult{}}` pairs — the failing slice of a
  `Kazi.PredicateVector` and their evidence — which the loop hands the adapter so
  the agent gets *only* the failing-predicate evidence as context (concept §86).

  ## Examples

      iex> failing = [{:unit, Kazi.PredicateResult.fail(%{output: "1 test, 1 failure"})}]
      iex> prompt = Kazi.Harness.ClaudeAdapter.build_prompt("Make the suite green", failing)
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
      iex> prompt = Kazi.Harness.ClaudeAdapter.build_prompt("fix it", [], context_pack: pack)
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
      snippets when is_list(snippets) -> render_retrieval(snippets)
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

  # Render the retrieved snippets as a single clearly-delimited section that sits
  # AFTER the orientation prefix and the failing-evidence body. The heading is
  # fixed (greppable, cache-stable) and each snippet renders its source attribution
  # (when present) above a fenced text block.
  @spec render_retrieval([Snippet.t()]) :: String.t()
  defp render_retrieval(snippets) do
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

      iex> Kazi.Harness.ClaudeAdapter.truncate_evidence("short", max_bytes: 1_024)
      "short"

      iex> big = String.duplicate("x", 10_000)
      iex> out = Kazi.Harness.ClaudeAdapter.truncate_evidence(big, max_bytes: 100)
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

  # =============================================================================
  # claw-code hygiene: per-dispatch ceiling + minimal tool/permission set (T4.8)
  # =============================================================================

  # Assemble the optional hygiene flags appended to the `claude -p` argv. Each
  # group is emitted ONLY when its opt is supplied, so the absence of all hygiene
  # opts yields `[]` and the args degrade to exactly the pre-T4.8 shape.
  #
  #   * `:max_budget_usd` -> `--max-budget-usd <amount>`  (per-dispatch ceiling)
  #   * `:allowed_tools`  -> `--allowed-tools <t> <t> …`  (least-privilege set)
  #   * `:permission_mode`-> `--permission-mode <mode>`   (least-privilege mode)
  @spec hygiene_args(keyword()) :: [binary()]
  defp hygiene_args(opts) do
    budget_args(opts) ++ allowed_tools_args(opts) ++ permission_mode_args(opts)
  end

  # Per-dispatch token/cost ceiling: cap claude's OWN per-run spend so one
  # iteration cannot overrun the goal budget before the loop accounts for it.
  defp budget_args(opts) do
    case Keyword.get(opts, :max_budget_usd) do
      nil -> []
      amount when is_number(amount) and amount > 0 -> ["--max-budget-usd", to_string(amount)]
      _ -> []
    end
  end

  # Minimal per-goal tool set (least privilege): pass only the tools the goal
  # needs instead of the full default surface. Accepts a list of tool names or a
  # single comma/space-delimited string; empties contribute nothing.
  defp allowed_tools_args(opts) do
    case normalize_tools(Keyword.get(opts, :allowed_tools)) do
      [] -> []
      tools -> ["--allowed-tools" | tools]
    end
  end

  # Minimal permission mode (least privilege): scope the dispatch's authority.
  # Passed through verbatim as a string so new claude modes need no code change.
  defp permission_mode_args(opts) do
    case Keyword.get(opts, :permission_mode) do
      nil -> []
      mode when is_atom(mode) -> ["--permission-mode", Atom.to_string(mode)]
      mode when is_binary(mode) and mode != "" -> ["--permission-mode", mode]
      _ -> []
    end
  end

  # Coerce the configured tool set into a clean list of non-empty name strings.
  @spec normalize_tools(term()) :: [binary()]
  defp normalize_tools(nil), do: []

  defp normalize_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(tools) when is_binary(tools) do
    tools
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(_other), do: []

  # =============================================================================
  # JSON envelope parsing (T4.1)
  # =============================================================================

  # Parse the harness's `--output-format json` envelope into the additive subset
  # of the result map. Best-effort and total: anything other than a JSON OBJECT —
  # malformed JSON, a bare string, an empty/whitespace stdout — yields `%{}`, so
  # the caller keeps the back-compat base map unchanged and never crashes on a
  # surprising harness. Recognised fields are extracted defensively (each absent
  # or wrong-typed field is simply skipped).
  @spec parse_envelope(binary()) :: map()
  defp parse_envelope(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{} = envelope} -> extract_fields(envelope)
      # A non-object JSON value (string/number/list) or a decode error: nothing
      # structured to extract, degrade to base behaviour.
      _ -> %{}
    end
  end

  # Pull the structured fields out of a decoded JSON object, building the additive
  # map. Each clause adds its key ONLY when the field is present and well-typed,
  # so a partial envelope contributes exactly what it carries.
  @spec extract_fields(map()) :: map()
  defp extract_fields(envelope) do
    %{}
    |> put_result(envelope)
    |> put_tokens(envelope)
    |> put_cost(envelope)
    |> put_touched(envelope)
  end

  # The agent's final result text (the `result` field of a `claude` success
  # envelope). Only surfaced when it is a string.
  defp put_result(acc, %{"result" => result}) when is_binary(result),
    do: Map.put(acc, :result, result)

  defp put_result(acc, _envelope), do: acc

  # Real token usage. `claude` reports a `usage` object broken out by input /
  # output / cache; the budget wants ONE total, so we sum the integer components.
  # Surfaced both flat (`:tokens`) and in the `%{cost: %{tokens: n}}` shape the
  # loop's T1.4 budget guard already consumes (`Kazi.Loop` `token_estimate/1`).
  defp put_tokens(acc, %{"usage" => %{} = usage}) do
    case total_tokens(usage) do
      0 -> acc
      total -> acc |> Map.put(:tokens, total) |> Map.put(:cost, %{tokens: total})
    end
  end

  defp put_tokens(acc, _envelope), do: acc

  # Real dollar cost (`total_cost_usd`), surfaced when present as a number.
  defp put_cost(acc, %{"total_cost_usd" => cost}) when is_number(cost),
    do: Map.put(acc, :cost_usd, cost)

  defp put_cost(acc, _envelope), do: acc

  # The touched working set, if the harness reports one. Not part of every
  # envelope, so this is opportunistic: a list of file paths under any of a few
  # plausible keys, filtered to strings.
  defp put_touched(acc, envelope) do
    case touched_files(envelope) do
      [] -> acc
      files -> Map.put(acc, :touched, files)
    end
  end

  # Sum the integer token components of a `usage` object. Unknown / non-integer
  # values contribute nothing, so a usage object missing a component (or carrying
  # a surprising one) still yields a sane total.
  @spec total_tokens(map()) :: non_neg_integer()
  defp total_tokens(usage) do
    [
      "input_tokens",
      "output_tokens",
      "cache_creation_input_tokens",
      "cache_read_input_tokens"
    ]
    |> Enum.reduce(0, fn key, sum ->
      case Map.get(usage, key) do
        n when is_integer(n) and n >= 0 -> sum + n
        _ -> sum
      end
    end)
  end

  # The working set the harness touched, read defensively from whichever of a few
  # plausible keys is present (the field is not standardised across harness
  # versions). Returns a list of path strings, or `[]` when none is reported.
  @spec touched_files(map()) :: [binary()]
  defp touched_files(envelope) do
    ["touched", "touched_files", "files", "working_set"]
    |> Enum.find_value([], fn key ->
      case Map.get(envelope, key) do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> nil
      end
    end)
  end

  # Resolution order: explicit opt > app config > default. This is the seam that
  # makes the adapter harness-agnostic and lets tests inject a stub binary.
  defp command(opts) do
    Keyword.get(opts, :command) ||
      Application.get_env(:kazi, :harness_command, @default_command)
  end
end
