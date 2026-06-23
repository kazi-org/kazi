defmodule Kazi.Authoring.Clarify do
  @moduledoc """
  The clarify phase of authoring (T11.1/T11.2, UC-029, ADR-0019).

  `kazi propose "<idea>"` used to draft a goal in one shot, so a one-line idea
  became *guessed* acceptance predicates. The clarify phase sits BEFORE the draft:
  it asks the author 2-4 high-leverage questions whose answers make the predicates
  precise -- especially the live-verification target, kazi's differentiator over a
  prose plan that stops at "tests pass locally" (concept §1, ADR-0002). The clarify
  phase is HYBRID (ADR-0019): a deterministic, pure FLOOR of gap-checks here, plus
  harness-drafted candidate questions layered on the same injectable seam (T11.3).

  This module is the **pure core**: the question/answer data shapes
  (`Kazi.Authoring.Clarify.Question`, `Kazi.Authoring.Clarify.Option`), the
  deterministic gap-detection floor (`gaps/2`), and `fold_answers/2` which merges
  the author's answers into a deterministic clarifications block appended to the
  draft prompt. Nothing here does I/O or drives a harness, so it is unit-tested
  directly; the CLI supplies the interactive rendering (T11.6) and the harness
  candidates are merged in by `Kazi.Authoring` (T11.3).

  ## The floor (`gaps/2`)

  Each floor question is emitted only when its signal is ABSENT from the idea (and
  the optional draft), so a fully-specified idea yields zero floor questions:

    * `live-target` -- always ask for the live-verification target unless the idea
      already names a deployed URL / production target or the draft already carries
      an `http_probe`/`prod_log` predicate.
    * `scope` -- always ask for the scope boundary unless the idea states one
      explicitly ("only", "just ...", "no deploy", "scope: ...").
    * `http-status` -- when the idea names an HTTP endpoint but pins no status code,
      ask what status/auth the endpoint must return (so an `http_probe` predicate
      has a concrete `config`).

  ## Folding answers (`fold_answers/2`)

  `fold_answers(questions, answers)` renders the answered questions into a stable
  text block (ordered by the question list, unanswered questions skipped) that
  `Kazi.Authoring.build_prompt/2` appends to the idea. Deterministic: the same
  answers always yield the same block, so the draft stays reproducible.
  """

  alias Kazi.Authoring.Clarify.{Option, Question}

  @typedoc "Answers keyed by `Question.id` -> the chosen option value or free text."
  @type answers :: %{optional(String.t()) => String.t()}

  # Providers kazi can objectively evaluate (mirror of Kazi.Authoring's set). A
  # live-verification predicate uses http_probe (a deployed URL) or prod_log.
  @live_providers ~w(http_probe prod_log)

  @doc """
  Returns the deterministic floor of clarifying questions for `idea`.

  Pure and total. `opts` may carry `:draft` -- a `Kazi.Goal` or a proposal map
  (string-keyed `"predicates"`) -- so a question is suppressed when the draft
  already covers the gap (e.g. it already has a live-verification predicate). A
  fully-specified idea returns `[]`.
  """
  @spec gaps(String.t(), keyword()) :: [Question.t()]
  def gaps(idea, opts \\ []) when is_binary(idea) and is_list(opts) do
    draft = Keyword.get(opts, :draft)

    [
      live_target_question(idea, draft),
      scope_question(idea),
      http_status_question(idea)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Builds the prompt asking the harness to DRAFT candidate clarifying questions
  for `idea` (T11.3, ADR-0019).

  Pure and total. The harness is asked for a JSON array matching the
  `Kazi.Authoring.Clarify.Question` shape, which `parse_candidates/1` validates
  and `merge/2` folds onto the deterministic floor (the floor wins). Used by
  `Kazi.Authoring` to drive the injectable harness; kept here so the contract and
  its parser live together.
  """
  @spec candidate_prompt(String.t()) :: String.t()
  def candidate_prompt(idea) when is_binary(idea) do
    """
    A software idea is being turned into a kazi goal -- a set of machine-checkable
    acceptance predicates. BEFORE drafting them, propose up to 3 short clarifying
    questions whose answers would make the predicates precise (e.g. the exact
    acceptance condition, the live-verification target, scope boundaries). Ask only
    what you cannot infer; prefer multiple-choice.

    Idea:
    #{idea}

    Respond with a SINGLE JSON array and nothing else, of the shape:

      [
        {"id": "<stable-id>", "prompt": "<question>",
         "options": [{"label": "<shown>", "value": "<stable>"}],
         "recommended": "<option value or null>", "allow_free_text": false}
      ]

    Return an empty array [] if the idea is already fully specified.
    """
  end

  @doc """
  Parses a harness `payload` (a JSON array string or an already-decoded list) into
  candidate `Kazi.Authoring.Clarify.Question`s (T11.3).

  Pure, total, and FAIL-SOFT: any item missing a non-empty `id`/`prompt` is
  dropped, and a payload that is not a JSON array (a decode error, an object, nil,
  garbage) yields `[]` -- so a malformed or empty harness response degrades to the
  deterministic floor alone rather than failing the proposal.
  """
  @spec parse_candidates(term()) :: [Question.t()]
  def parse_candidates(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, list} when is_list(list) -> parse_candidates(list)
      _ -> []
    end
  end

  def parse_candidates(list) when is_list(list) do
    list |> Enum.map(&candidate_question/1) |> Enum.reject(&is_nil/1)
  end

  def parse_candidates(_payload), do: []

  @doc """
  Merges the deterministic `floor` with harness `candidates`, the floor
  AUTHORITATIVE (T11.3).

  Floor questions come first and in order; a candidate whose `id` collides with a
  floor question (or with an earlier candidate) is dropped, so the floor's
  must-ask gaps are never shadowed and ids stay unique.
  """
  @spec merge([Question.t()], [Question.t()]) :: [Question.t()]
  def merge(floor, candidates) when is_list(floor) and is_list(candidates) do
    floor_ids = MapSet.new(floor, & &1.id)

    {extra, _seen} =
      Enum.reduce(candidates, {[], floor_ids}, fn %Question{} = q, {acc, seen} ->
        if MapSet.member?(seen, q.id) do
          {acc, seen}
        else
          {[q | acc], MapSet.put(seen, q.id)}
        end
      end)

    floor ++ Enum.reverse(extra)
  end

  @doc """
  Folds `answers` into a deterministic clarifications block for the draft prompt.

  `questions` is the asked set (the floor plus any harness candidates); `answers`
  maps a `Question.id` to the chosen option value or free text. Questions with no
  answer (or a blank answer) are skipped. Order follows `questions`, so the same
  answers always render the same block. Returns `""` when nothing was answered, so
  the caller appends nothing.
  """
  @spec fold_answers([Question.t()], answers()) :: String.t()
  def fold_answers(questions, answers) when is_list(questions) and is_map(answers) do
    questions
    |> Enum.map(fn %Question{} = q -> {q, Map.get(answers, q.id)} end)
    |> Enum.reject(fn {_q, answer} -> is_nil(answer) or answer == "" end)
    |> case do
      [] ->
        ""

      answered ->
        lines =
          Enum.map_join(answered, "\n", fn {q, answer} ->
            "- #{q.prompt} -> #{answer_label(q, answer)}"
          end)

        "Clarifications provided by the author:\n" <> lines
    end
  end

  @doc """
  Renders a `question` as a terminal multiple-choice block (T11.6).

  Pure: returns the prompt, the numbered options (the recommended one starred),
  and a free-text line when allowed -- so the CLI just prints this string and the
  rendering is unit-tested without a TTY.
  """
  @spec render_question(Question.t()) :: String.t()
  def render_question(%Question{} = q) do
    options =
      q.options
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%Option{label: label, value: value}, i} ->
        star = if value == q.recommended, do: " *", else: ""
        "  #{i}) #{label}#{star}"
      end)

    free = if q.allow_free_text, do: "\n  f) something else (type your answer)", else: ""

    "#{q.prompt}\n#{options}#{free}"
  end

  @doc """
  Resolves an author's raw `input` line to an answer value for `question` (T11.6).

  Pure and total -- the tricky parsing the CLI delegates here so it is unit-tested:

    * a blank line -> the recommended option (or the first option's value);
    * a number `N` -> the Nth option's value (1-based, in range);
    * an exact option label or value -> that value;
    * otherwise, when free text is allowed, the input verbatim (a leading `"f "`
      prefix is stripped); else the recommended/first value as a safe default.
  """
  @spec resolve_answer(Question.t(), String.t()) :: String.t()
  def resolve_answer(%Question{} = q, "") do
    q.recommended || default_value(q)
  end

  def resolve_answer(%Question{} = q, input) when is_binary(input) do
    cond do
      value = option_at(q, input) -> value
      value = matched_value(q, input) -> value
      q.allow_free_text -> String.replace_prefix(input, "f ", "")
      true -> q.recommended || default_value(q)
    end
  end

  defp option_at(%Question{options: options}, input) do
    case Integer.parse(input) do
      {n, ""} when n >= 1 and n <= length(options) -> Enum.at(options, n - 1).value
      _ -> nil
    end
  end

  defp matched_value(%Question{options: options}, input) do
    case Enum.find(options, fn %Option{label: l, value: v} -> l == input or v == input end) do
      %Option{value: value} -> value
      nil -> nil
    end
  end

  defp default_value(%Question{options: [%Option{value: value} | _]}), do: value
  defp default_value(%Question{}), do: ""

  # Resolve the chosen value to its option label when it matches a known option;
  # otherwise the raw answer is free text and passes through verbatim.
  defp answer_label(%Question{options: options}, value) do
    case Enum.find(options, fn %Option{value: v} -> v == value end) do
      %Option{label: label} -> label
      nil -> value
    end
  end

  # --- candidate parsing (T11.3) ---------------------------------------------

  # One candidate question from a decoded harness item. Requires a non-empty
  # string id and prompt; options are parsed leniently (well-formed {label,value}
  # entries only). A non-map, or an item missing id/prompt, is dropped (nil).
  defp candidate_question(%{"id" => id, "prompt" => prompt} = raw)
       when is_binary(id) and id != "" and is_binary(prompt) and prompt != "" do
    Question.new(id, prompt,
      options: parse_options(Map.get(raw, "options")),
      recommended: optional_string(Map.get(raw, "recommended")),
      allow_free_text: Map.get(raw, "allow_free_text") == true
    )
  end

  defp candidate_question(_raw), do: nil

  defp parse_options(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"label" => label, "value" => value} when is_binary(label) and is_binary(value) ->
        Option.new(label, value)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_options(_), do: []

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  # --- floor questions -------------------------------------------------------

  # Always ask for the live-verification target unless the idea already names a
  # deployed/production target or the draft already carries a live predicate.
  defp live_target_question(idea, draft) do
    if live_target_present?(idea) or draft_has_live_predicate?(draft) do
      nil
    else
      Question.new("live-target", "What is the live-verification target for this goal?",
        options: [
          Option.new("A deployed URL probed over HTTP", "http_probe"),
          Option.new("Production logs / a runtime signal", "prod_log"),
          Option.new("None for now -- green tests are enough", "tests_only")
        ],
        recommended: "http_probe"
      )
    end
  end

  # Always ask for the scope boundary unless the idea states one explicitly.
  defp scope_question(idea) do
    if scope_present?(idea) do
      nil
    else
      Question.new("scope", "What is in scope for this goal?",
        options: [
          Option.new("Just the core change", "core"),
          Option.new("Core plus automated tests", "core_tests"),
          Option.new("Core, tests, docs, and deploy", "core_tests_docs_deploy")
        ],
        recommended: "core_tests"
      )
    end
  end

  # When the idea names an HTTP endpoint but pins no status code, ask what the
  # endpoint must return so an http_probe predicate has a concrete config.
  defp http_status_question(idea) do
    if mentions_http_endpoint?(idea) and not pins_http_status?(idea) do
      Question.new(
        "http-status",
        "What status (and auth) must the endpoint return to count as done?",
        options: [
          Option.new("200, no authentication required", "200_public"),
          Option.new("200, but only when authenticated", "200_authed"),
          Option.new("Some other status -- I will specify", "other")
        ],
        recommended: "200_public",
        allow_free_text: true
      )
    else
      nil
    end
  end

  # --- signal detectors (pure) -----------------------------------------------

  defp live_target_present?(idea) do
    idea =~ ~r/https?:\/\/|\bdeployed\b|\bproduction\b|\bprod\b|\blive\b/i
  end

  defp draft_has_live_predicate?(nil), do: false

  defp draft_has_live_predicate?(%Kazi.Goal{} = goal) do
    goal
    |> Kazi.Goal.all_predicates()
    |> Enum.any?(fn predicate -> to_string(predicate.kind) in @live_providers end)
  end

  defp draft_has_live_predicate?(%{} = map) do
    case Map.get(map, "predicates") do
      list when is_list(list) ->
        Enum.any?(list, fn
          %{"provider" => provider} -> provider in @live_providers
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp draft_has_live_predicate?(_), do: false

  defp scope_present?(idea) do
    idea =~ ~r/\bonly\b|\bjust\b|no deploy|in scope|out of scope|scope:/i
  end

  defp mentions_http_endpoint?(idea) do
    idea =~ ~r/\bendpoint\b|\bhttp\b|\bapi\b|\broute\b|\bGET\b|\bPOST\b|\/[a-z]/
  end

  defp pins_http_status?(idea) do
    idea =~ ~r/\b[1-5][0-9][0-9]\b/
  end
end
