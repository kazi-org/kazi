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

  @default_command "claude"

  @impl true
  def run("", _workspace, _opts), do: {:error, :empty_prompt}

  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    command = command(opts)
    # `--output-format json` (T4.1) makes the harness emit a structured envelope
    # on stdout: real token usage, dollar cost, the agent's final result, and any
    # touched working set. `-p` still drives the non-interactive run.
    args = ["-p", prompt, "--output-format", "json"]

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

    case orientation_prefix(failing, opts) do
      nil -> body
      prefix -> prefix <> "\n\n" <> body
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
