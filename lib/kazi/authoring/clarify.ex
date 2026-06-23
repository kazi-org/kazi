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

  # Resolve the chosen value to its option label when it matches a known option;
  # otherwise the raw answer is free text and passes through verbatim.
  defp answer_label(%Question{options: options}, value) do
    case Enum.find(options, fn %Option{value: v} -> v == value end) do
      %Option{label: label} -> label
      nil -> value
    end
  end

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
