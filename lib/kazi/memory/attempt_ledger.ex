defmodule Kazi.Memory.AttemptLedger do
  @moduledoc """
  The episodic memory layer (ADR-0060 layer 2, ADR-0061): a **deterministic
  fold** over the read-model's recorded iteration history for one goal, never
  a document an agent authors.

  Every iteration the loop already RECORDS what happened — the per-iteration
  predicate vector history (`Kazi.Loop.history/0`) and the dispatch log (which
  failing predicates each dispatch targeted). None of that was projected
  forward before this module: the dispatch prompt described only the present
  error, so the inner model could not tell "first attempt at this predicate"
  from "fifth attempt; the previous four all touched the same file and did not
  change the verdict."

  This module closes that gap with FACTS ONLY (ADR-0058's confabulation
  stance, restated by ADR-0061 decision 5): every field is derived from a
  `Kazi.PredicateVector` or a `Kazi.Action`'s recorded params — never from
  model/transcript prose. It is a **projection, not a document**: recomputable
  from the read-model at any time, nothing new to keep consistent.

  ## The fold (decision 1)

  `fold/2` walks the dispatch log (each entry the failing-predicate set + the
  evidence a dispatch was seeded with) and, for each dispatch, derives:

    * `failing` — the predicate ids the dispatch targeted;
    * `touched` — the files the dispatch's action reported touching (empty
      when the caller has none to report — touched-file capture per dispatch
      is additive and never required for the fold to run);
    * `error_head` — a normalized head of the seeding evidence, keyed off the
      lowest-sorted failing id so the derivation is deterministic;
    * `fingerprint` — decision 3's crude repeat-attempt key (see
      `fingerprint/3`);
    * `effect` — `:no_change` when the SAME failing set persists to the next
      recorded observation, `:changed` when it shrank/changed/graded-improved,
      `:unknown` when there is no later observation yet (the dispatch is still
      in flight).

  Attempts sharing a fingerprint are grouped into one ledger `entry`, carrying
  every iteration it recurred at and a repeat count — the substrate for the
  ADR's headline line: "approach F was tried at iterations N, M and did not
  change predicate P's verdict."

  ## Repeat detection is crude on purpose (decision 3)

  Two attempts are "the same approach" when their `(failing-predicate set,
  touched-file set, error-fingerprint)` triple matches — no semantic
  similarity, no model in the loop. A false "this looks repeated" costs one
  rendered line; a missed repeat costs a wasted dispatch. Crude and cheap
  wins.

  ## Same fold, two readers (decision 4)

  `failing_sets/1` is the shared derivation `Kazi.Loop.StuckDetector` reads
  too, so the controller's stuck/no-progress policy and the ledger rendered
  into the dispatch prompt can never disagree about what the history says.

  ## Bounded rendering (decision 2)

  `render/2` renders a bounded `ATTEMPT LEDGER` prompt section, most-recent
  and most-repeated entries first, hard-capped by an approximate token budget
  (default `#{800}` tokens — a context-tier lever, ADR-0047). An empty ledger
  renders to `""`, so a goal with no repeated history adds NO section (the
  prompt stays byte-identical to today).

  ## Purity

  No I/O, no process state, no clock. The loop reads history/dispatch log off
  its own state and calls this module; this module only decides what the fold
  and its rendering look like — independently unit-testable.
  """

  alias Kazi.{Action, Predicate, PredicateVector}

  @typedoc "Decision 3's crude repeat-attempt key — a short deterministic hex digest."
  @type fingerprint :: String.t()

  @typedoc "How a single dispatch attempt's target predicate set evolved by the next observation."
  @type effect :: :no_change | :changed | :unknown

  @typedoc """
  One ledger entry — every recorded attempt sharing the same `fingerprint`,
  folded together. `iterations` is oldest-first; `repeats` is its length.
  """
  @type entry :: %{
          fingerprint: fingerprint(),
          failing: MapSet.t(Predicate.id()),
          touched: MapSet.t(String.t()),
          error_head: String.t(),
          iterations: [non_neg_integer()],
          repeats: pos_integer(),
          effect: effect()
        }

  @typedoc "The per-iteration vector history the fold reads (`Kazi.Loop.history/0`'s shape)."
  @type history :: [{non_neg_integer(), PredicateVector.t()}]

  @typedoc """
  The dispatch log the fold reads: `{iteration_index, action}` pairs where
  `iteration_index` is the observation index that seeded the dispatch and
  `action` is the recorded `:dispatch_agent` `Kazi.Action` (its `params` carry
  `:failing`, `:evidence`, and optionally `:touched`).
  """
  @type dispatch_log :: [{non_neg_integer(), Action.t()}]

  @typep vectors :: %{non_neg_integer() => PredicateVector.t()}

  # Rough chars-per-token heuristic (matches the coarse estimates used
  # elsewhere in the prompt-shaping code, e.g. `Kazi.Harness.Prompt`) — good
  # enough for a soft rendering cap, not a tokenizer.
  @chars_per_token 4

  @default_max_tokens 800

  @doc """
  The shared failing-set fold (decision 4): one `MapSet` of failing predicate
  ids per recorded observation, oldest-first — exactly the derivation
  `Kazi.Loop.StuckDetector` needs for its window logic. Both the ledger and the
  stuck detector read this SAME fold, so controller policy and inner-model
  context can never disagree about what the history says.

  ## Examples

      iex> alias Kazi.{PredicateVector, PredicateResult}
      iex> fail = PredicateVector.new(%{a: PredicateResult.fail()})
      iex> Kazi.Memory.AttemptLedger.failing_sets([{0, fail}])
      [MapSet.new([:a])]
  """
  @spec failing_sets(history()) :: [MapSet.t(Predicate.id())]
  def failing_sets(history) when is_list(history) do
    Enum.map(history, fn {_index, %PredicateVector{} = vector} ->
      MapSet.new(PredicateVector.failing(vector))
    end)
  end

  @doc """
  Decision 3's crude repeat-attempt fingerprint: a short deterministic digest
  of the `(failing-predicate set, touched-file set, error-fingerprint)`
  triple. Set order never matters (both sets are sorted before hashing), so
  two attempts presented in different enumeration order still fingerprint
  identically.

  ## Examples

      iex> a = Kazi.Memory.AttemptLedger.fingerprint(MapSet.new([:x]), MapSet.new(["f.ex"]), "boom")
      iex> b = Kazi.Memory.AttemptLedger.fingerprint(MapSet.new([:x]), MapSet.new(["f.ex"]), "boom")
      iex> a == b
      true
  """
  @spec fingerprint(MapSet.t(Predicate.id()), MapSet.t(String.t()), String.t()) :: fingerprint()
  def fingerprint(failing, touched, error_head) do
    key =
      Enum.join(
        [
          failing |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(","),
          touched |> Enum.sort() |> Enum.join(","),
          error_head
        ],
        "|"
      )

    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  @doc """
  Folds `history` + `dispatch_log` into the episodic attempt ledger (decision
  1). Deterministic: the same inputs always produce the same entries in the
  same order. `history` is not assumed sorted; `dispatch_log` entries are
  processed in `iteration_index` order.

  `history` may span multiple runs of the SAME goal concatenated together —
  the fold has no notion of a run boundary, so cross-run inclusion (decision
  1's "prior runs of the same goal are included") is exactly what the caller
  hands it: query the read-model by goal identity, not run id, and every
  attempt made in any past run folds in alongside the current one.

  Returns `[]` for an empty dispatch log — an empty ledger renders to no
  section (see `render/2`).
  """
  @spec fold(history(), dispatch_log()) :: [entry()]
  def fold(history, dispatch_log \\ []) when is_list(history) and is_list(dispatch_log) do
    vectors = Map.new(history)

    dispatch_log
    |> Enum.sort_by(fn {index, _action} -> index end)
    |> Enum.map(fn {index, %Action{} = action} -> build_attempt(index, action, vectors) end)
    |> group_by_fingerprint()
  end

  @doc """
  Renders `entries` as a bounded `ATTEMPT LEDGER` prompt section (decision 2)
  — most-recent, most-repeated entries first, capped to an approximate
  `:max_tokens` budget (default `#{@default_max_tokens}`, a
  `Kazi.Context.Tier`-scale parameter). Returns `""` for an empty ledger, so a
  goal with no repeated history contributes NO section — the caller (the loop)
  omits the section entirely, keeping the prompt byte-identical to before the
  ledger existed.

  A repeated entry whose failing set persisted unchanged renders the ADR's
  headline "do not repeat it" line; every other entry renders a plainer
  attempt note.
  """
  @spec render([entry()], keyword()) :: String.t()
  def render(entries, opts \\ [])
  def render([], _opts), do: ""

  def render(entries, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    max_chars = max(max_tokens, 1) * @chars_per_token

    lines =
      entries
      |> Enum.sort_by(fn e -> {-List.last(e.iterations), -e.repeats} end)
      |> Enum.map(&render_line/1)
      |> fit_lines(max_chars)

    case lines do
      [] ->
        ""

      lines ->
        "# Attempt ledger (kazi-recorded facts; no model prose)\n" <> Enum.join(lines, "\n")
    end
  end

  # ===========================================================================
  # Internal — the fold
  # ===========================================================================

  @spec build_attempt(non_neg_integer(), Action.t(), vectors()) ::
          %{
            iteration: non_neg_integer(),
            failing: MapSet.t(Predicate.id()),
            touched: MapSet.t(String.t()),
            error_head: String.t(),
            fingerprint: fingerprint(),
            effect: effect()
          }
  defp build_attempt(index, %Action{params: params}, vectors) do
    failing = params |> Map.get(:failing, []) |> MapSet.new()
    touched = params |> Map.get(:touched, []) |> MapSet.new()
    evidence = Map.get(params, :evidence, %{})
    error_head = error_head(failing, evidence)

    %{
      iteration: index,
      failing: failing,
      touched: touched,
      error_head: error_head,
      fingerprint: fingerprint(failing, touched, error_head),
      effect: effect(index, failing, vectors)
    }
  end

  # A short, normalized head of the seeding evidence — deterministic (keyed off
  # the lowest-sorted failing id, never enumeration order) and facts-only (the
  # evidence map the loop already recorded, never model prose).
  @spec error_head(MapSet.t(Predicate.id()), map()) :: String.t()
  defp error_head(failing, evidence) do
    case failing |> Enum.map(&to_string/1) |> Enum.sort() do
      [] ->
        ""

      [first | _] ->
        id = Enum.find(Map.keys(evidence), fn k -> to_string(k) == first end)

        evidence
        |> Map.get(id)
        |> inspect(limit: 20, printable_limit: 200)
        |> String.downcase()
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 80)
    end
  end

  # Whether the failing set this attempt targeted persisted, unchanged, to the
  # NEXT recorded observation (`index + 1`) — the observable effect ADR-0061
  # decision 1 asks for. No later observation recorded yet ⇒ `:unknown` (the
  # dispatch is still in flight, not yet re-observed).
  @spec effect(non_neg_integer(), MapSet.t(Predicate.id()), vectors()) :: effect()
  defp effect(index, failing, vectors) do
    case Map.fetch(vectors, index + 1) do
      :error ->
        :unknown

      {:ok, next_vector} ->
        next_failing = MapSet.new(PredicateVector.failing(next_vector))
        if MapSet.equal?(failing, next_failing), do: :no_change, else: :changed
    end
  end

  @spec group_by_fingerprint([map()]) :: [entry()]
  defp group_by_fingerprint(attempts) do
    attempts
    |> Enum.group_by(& &1.fingerprint)
    |> Enum.map(fn {fp, group} ->
      sorted = Enum.sort_by(group, & &1.iteration)
      first = List.first(sorted)

      %{
        fingerprint: fp,
        failing: first.failing,
        touched: first.touched,
        error_head: first.error_head,
        iterations: Enum.map(sorted, & &1.iteration),
        repeats: length(sorted),
        effect: overall_effect(sorted)
      }
    end)
  end

  # A fingerprint that ever showed :changed made SOME progress, however brief —
  # surface that over a stale :no_change reading from an earlier occurrence.
  # Otherwise: persistently unchanged wins over merely "still pending".
  @spec overall_effect([map()]) :: effect()
  defp overall_effect(attempts) do
    cond do
      Enum.any?(attempts, &(&1.effect == :changed)) -> :changed
      Enum.all?(attempts, &(&1.effect == :no_change)) -> :no_change
      true -> :unknown
    end
  end

  # ===========================================================================
  # Internal — rendering
  # ===========================================================================

  @spec render_line(entry()) :: String.t()
  defp render_line(%{repeats: repeats, effect: :no_change} = entry) when repeats > 1 do
    "- approach #{entry.fingerprint} was tried at iterations #{join_iterations(entry)} " <>
      "and did not change predicate(s) #{join_failing(entry)}'s verdict -- do not repeat it."
  end

  defp render_line(entry) do
    "- approach #{entry.fingerprint} touched predicate(s) #{join_failing(entry)} " <>
      "at iteration(s) #{join_iterations(entry)} (#{entry.effect})."
  end

  defp join_iterations(%{iterations: iterations}), do: Enum.join(iterations, ", ")

  defp join_failing(%{failing: failing}),
    do: failing |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")

  # Bound the rendered lines to a char budget by dropping lines from the tail
  # (they are already sorted most-recent/most-repeated first) until the joined
  # section fits. Always keeps at least one line once there is any, mirroring
  # `Kazi.Loop.Digest`'s fit-to-budget shape.
  @spec fit_lines([String.t()], pos_integer()) :: [String.t()]
  defp fit_lines(lines, max_chars), do: fit_lines(lines, max_chars, length(lines))

  defp fit_lines(_lines, _max_chars, 0), do: []

  defp fit_lines(lines, max_chars, take) do
    kept = Enum.take(lines, take)

    if byte_size(Enum.join(kept, "\n")) <= max_chars or take == 1 do
      kept
    else
      fit_lines(lines, max_chars, take - 1)
    end
  end
end
