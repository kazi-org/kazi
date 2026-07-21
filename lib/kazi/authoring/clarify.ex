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
    * `naked-grep-predicate` -- ADVISORY (issue #924): when the draft carries a
      `custom_script` predicate whose whole command is a bare, POSITIVE
      `grep`/`grep -q`/`grep -rqiE`-style text-presence match, and no OTHER
      predicate in the draft asserts the corresponding old/stale pattern is
      ABSENT (a negated grep, e.g. `grep -qv`/`grep -L`/`! grep -q`). A naked
      positive grep is satisfiable vacuously -- string-stuffing an unrelated
      file, or matching pre-existing content -- without the feature actually
      being built. This gap is a WARN only: unlike `live-target`/`scope`, it can
      only be computed AFTER a draft exists (predicates are the harness's
      choice, not the idea's), so it never participates in the pre-draft
      `--strict` refusal and never blocks drafting or persisting.
    * `tree-clean-predicate` -- ADVISORY (issue #937 Gap E, T59.10): when the
      draft carries a `custom_script` predicate whose command asserts the WHOLE
      working tree is clean (`test -z "$(git status --porcelain)"` and
      equivalents) with NO pathspec scoping it to the goal's own files. Under
      multi-goal-same-workspace scheduling a sibling goal committing in the same
      tree flips such a predicate to a false-negative verdict (the exact shape
      #937 comment 2 hit). T54.1 fixed kazi's built-in serial landing gate, but a
      hand-written whole-tree-cleanliness acceptance predicate is still
      structurally unsafe. WARN only, like `naked-grep-predicate`: draft-derived,
      so it never participates in the pre-draft `--strict` refusal and never
      blocks drafting or persisting. A path-scoped form
      (`git status --porcelain -- lib/foo`) is safe and never flagged.
    * `landing` -- T44.12 (ADR-0055): when the draft carries CODE predicates but
      no `integration` block. "Landing is part of convergence": without one the
      goal converges and stops, leaving the change on a branch nobody asked for.
      Suppressed by an `integration` block of ANY mode -- including `"none"`,
      which is a deliberate converge-and-stop answer rather than an omission --
      and never asked for a goal with nothing to land (docs-only, live-probe
      only). Like `naked-grep-predicate` it is draft-derived, so it never
      participates in the pre-draft `--strict` refusal.
    * `self-hosting-cli-predicate` -- ADVISORY (T45.10, #1668): when the draft
      carries a `cli`/`custom_script` predicate whose `cmd` names the SAME
      executable the target workspace itself builds (resolved by the caller via
      `Kazi.Authoring.SelfHost.own_binary_name/1` and passed in as the
      `:own_binary_name` opt -- kept out of this pure module, which only takes the
      resolved name as data). Such a predicate observes the INSTALLED/last-built
      binary, never the source tree a fix edits, so it cannot turn green from a
      source change alone until a release happens -- exactly the defect that
      stalled the T45.10 exit-proof at 1/3 predicates. WARN only, like the other
      draft-derived gaps above: it never blocks drafting or persisting, and is
      silent (absent `own_binary_name`) for every ordinary, non-self-hosting
      target workspace.

  ## Folding answers (`fold_answers/2`)

  `fold_answers(questions, answers)` renders the answered questions into a stable
  text block (ordered by the question list, unanswered questions skipped) that
  `Kazi.Authoring.build_prompt/2` appends to the idea. Deterministic: the same
  answers always yield the same block, so the draft stays reproducible.
  """

  alias Kazi.Authoring.Clarify.{Option, Question}
  alias Kazi.Goal.Roadmap

  @typedoc "Answers keyed by `Question.id` -> the chosen option value or free text."
  @type answers :: %{optional(String.t()) => String.t()}

  # Providers kazi can objectively evaluate (mirror of Kazi.Authoring's set). A
  # live-verification predicate uses http_probe (a deployed URL) or prod_log.
  @live_providers ~w(http_probe prod_log)

  @doc """
  Returns the deterministic floor of clarifying questions for `idea`.

  Pure and total. `opts` may carry `:draft` -- a `Kazi.Goal` or a proposal map
  (string-keyed `"predicates"`) -- so a question is suppressed when the draft
  already covers the gap (e.g. it already has a live-verification predicate). It
  may also carry `:own_binary_name` (T45.10, #1668) -- the target workspace's own
  built executable name, when resolved by the caller
  (`Kazi.Authoring.SelfHost.own_binary_name/1`) -- so the `self-hosting-cli-predicate`
  gap can fire; absent, that gap never fires. A fully-specified idea against a
  non-self-hosting workspace returns `[]`.
  """
  @spec gaps(String.t(), keyword()) :: [Question.t()]
  def gaps(idea, opts \\ []) when is_binary(idea) and is_list(opts) do
    draft = Keyword.get(opts, :draft)
    own_binary_name = Keyword.get(opts, :own_binary_name)

    [
      live_target_question(idea, draft),
      scope_question(idea),
      http_status_question(idea),
      naked_grep_question(draft),
      tree_clean_question(draft),
      landing_question(draft),
      self_hosting_question(draft, own_binary_name)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The ROADMAP-SCOPE clarify floor (T45.2, UC-059): flags run over the whole DAG,
  not one goal. Pure; returns `[Question.t()]`.

    * `roadmap-unordered` — N > 1 goals with NO `needs` edges (an unordered pile
      that probably should have been N separate `plan` calls, not a roadmap).
    * `roadmap-frontier-integration-<id>` — a FRONTIER goal (no dependents, terminal
      in the DAG) whose `[integration]` mode is `:none` (ADR-0055): a terminal goal
      that never explicitly lands is a design smell worth surfacing.
  """
  @spec roadmap_gaps(Roadmap.t()) :: [Question.t()]
  def roadmap_gaps(%Roadmap{nodes: nodes, edges: edges}) do
    ([unordered_pile_question(nodes, edges)] ++ frontier_integration_questions(nodes, edges))
    |> Enum.reject(&is_nil/1)
  end

  defp unordered_pile_question(nodes, []) when length(nodes) > 1 do
    Question.new(
      "roadmap-unordered",
      "These #{length(nodes)} goals declare no `needs` relationships. If they are " <>
        "genuinely independent, submit them as separate `plan` calls; otherwise add " <>
        "the `needs` edges that order them into a roadmap."
    )
  end

  defp unordered_pile_question(_nodes, _edges), do: nil

  # A FRONTIER (terminal) goal is one no other goal `needs` — an id that is never an
  # edge `from`. Flag any such goal whose integration mode is `:none`.
  defp frontier_integration_questions(nodes, edges) do
    predecessors = MapSet.new(edges, & &1.from)

    nodes
    |> Enum.reject(&MapSet.member?(predecessors, &1.id))
    |> Enum.filter(fn node -> node.goal.integration.mode == :none end)
    |> Enum.map(fn node ->
      Question.new(
        "roadmap-frontier-integration-#{node.id}",
        "Frontier goal #{inspect(node.id)} declares no `[integration]` mode (ADR-0055): a " <>
          "terminal goal that never explicitly lands is a design smell. Set an integration " <>
          "mode (commit/branch/pr/merge) or confirm converge-and-stop is intended."
      )
    end)
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

  # T44.12 (ADR-0055): a CODE goal with no `[integration]` block converges and then
  # stops, leaving the work on a branch nobody asked for. "Landing is part of
  # convergence" — so an absent landing mode is a gap surfaced in the proposal's
  # `clarify` array, exactly like a missing live-verification target, never
  # silently accepted.
  #
  # Only asked when the draft has CODE predicates: a docs-only or live-probe-only
  # goal has nothing to land, and asking would be noise. Suppressed the moment the
  # draft carries an `integration` block — including `mode: "none"`, which is a
  # deliberate converge-and-stop answer, not an omission.
  #
  # Like `naked-grep-predicate`, this can only be computed AFTER a draft exists
  # (landing is a property of the drafted predicates, not the idea's prose), so it
  # never participates in the pre-draft `--strict` refusal.
  #
  # NOTE: these attributes must be declared BEFORE the function that reads them —
  # Elixir evaluates module attributes in source order, so a use above the
  # definition silently reads nil.
  #
  # The Wave B gate predicates an engineering goal should carry (T44.6/7/8). Named
  # as a SUGGESTION in the question text, not auto-injected: they are separate
  # providers a human opts into, and this floor never writes predicates.
  @gate_providers ~w(no_stubs oss_hygiene docs_updated)

  # Providers whose predicates represent CODE work — the kind that produces a diff
  # to land. A goal made only of live probes or docs checks has nothing to land.
  @code_providers ~w(test_runner custom_script static coverage mutation property cve)

  defp landing_question(draft) do
    if draft_has_integration?(draft) or not draft_has_code_predicate?(draft) do
      nil
    else
      Question.new(
        "landing",
        "How should this goal's converged work LAND? Without an [integration] block it " <>
          "converges and stops, leaving the change on a branch. Engineering goals should " <>
          "also gate on " <> Enum.join(@gate_providers, ", ") <> ".",
        options: [
          Option.new("Open a PR for review", "pr"),
          Option.new("Commit to the run's branch only", "commit"),
          Option.new("Push the branch, no PR", "branch"),
          Option.new("Merge it", "merge"),
          Option.new("Nothing -- converge and stop", "none")
        ],
        recommended: "pr"
      )
    end
  end

  defp draft_has_code_predicate?(nil), do: false

  # No `%Kazi.Goal{}` clause here — deliberately (issue #1277). `landing_question/1`
  # reaches this ONLY as `not draft_has_code_predicate?(draft)`, and only AFTER
  # `draft_has_integration?(draft)` was false. Since `draft_has_integration?` matches
  # ANY `%Kazi.Goal{}` and returns `true` unconditionally, a Goal draft always
  # short-circuits the `or` before this function is called — so a Goal clause here is
  # provably dead code (Elixir 1.20.2+'s cross-call reachability analysis flags it).
  # A `Kazi.Goal` is still an accepted `:draft`; its "has integration?" answer is what
  # suppresses the landing question, so it never needs a code-predicate check here.
  defp draft_has_code_predicate?(%{} = map) do
    case Map.get(map, "predicates") do
      list when is_list(list) ->
        Enum.any?(list, fn
          %{"provider" => provider} -> provider in @code_providers
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp draft_has_code_predicate?(_), do: false

  # An `integration` block of ANY mode answers the question — including "none",
  # which is a deliberate converge-and-stop choice. `Kazi.Goal`'s default is
  # `mode: :none` for a goal-file with no block at all, so a Goal struct cannot
  # distinguish "declared none" from "never asked"; only a caller-drafts map can,
  # and that is exactly where the floor runs (T11/ADR-0023).
  defp draft_has_integration?(nil), do: false

  defp draft_has_integration?(%Kazi.Goal{}), do: true

  defp draft_has_integration?(%{} = map) do
    case Map.get(map, "integration") do
      %{} = block -> map_size(block) > 0
      _ -> false
    end
  end

  defp draft_has_integration?(_), do: false

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

  # When the draft carries a bare, POSITIVE grep-only custom_script predicate and
  # no companion predicate asserts the old pattern is ABSENT, warn (issue #924).
  # Advisory only -- see the naked-grep-predicate floor entry in the moduledoc.
  defp naked_grep_question(draft) do
    commands = custom_script_commands(draft)

    if Enum.any?(commands, &naked_positive_grep?/1) and
         not Enum.any?(commands, &absence_grep?/1) do
      Question.new(
        "naked-grep-predicate",
        "One of this goal's custom_script predicates is a bare grep " <>
          "text-presence check, which can pass vacuously -- string-stuffed " <>
          "into an unrelated file, or an accidental match against " <>
          "pre-existing content -- without the feature actually being " <>
          "built. Pair it with a negative-space companion that asserts the " <>
          "OLD/removed pattern is ABSENT (e.g. `grep -qv <old-pattern>`), " <>
          "swap it for a structural check (parse/AST, not raw text search), " <>
          "or add a minimum-diff floor.",
        options: [
          Option.new("Add a companion absence assertion", "absence_companion"),
          Option.new("Replace it with a structural check", "structural_check"),
          Option.new("Leave as-is -- accept the risk", "accept_risk")
        ],
        recommended: "absence_companion"
      )
    end
  end

  # When the draft carries a custom_script predicate that asserts the WHOLE
  # working tree is clean (unscoped `git status --porcelain` and equivalents),
  # warn (issue #937 Gap E). Advisory only -- see the tree-clean-predicate floor
  # entry in the moduledoc.
  defp tree_clean_question(draft) do
    commands = custom_script_commands(draft)

    if Enum.any?(commands, &whole_tree_clean_command?/1) do
      Question.new(
        "tree-clean-predicate",
        "One of this goal's custom_script predicates asserts the WHOLE working " <>
          "tree is clean (e.g. `test -z \"$(git status --porcelain)\"`). Under " <>
          "shared-workspace scheduling -- several goals reconciling in one " <>
          "checkout -- a SIBLING goal committing in the same tree flips this " <>
          "predicate to a false-negative verdict, even though your goal is done. " <>
          "Scope the check to your goal's own paths (e.g. " <>
          "`git status --porcelain -- lib/foo`), or rely on kazi's identity-based " <>
          "landing gate (T54.1) rather than a hand-written whole-tree check.",
        options: [
          Option.new("Scope the check to the goal's own paths", "scope_paths"),
          Option.new("Rely on kazi's identity-based landing", "kazi_landing"),
          Option.new("Leave as-is -- accept the risk", "accept_risk")
        ],
        recommended: "scope_paths"
      )
    end
  end

  # When the draft carries a `cli`/`custom_script` predicate whose `cmd` names the
  # SAME executable the target workspace itself builds, warn (T45.10, #1668).
  # Advisory only -- see the self-hosting-cli-predicate floor entry in the
  # moduledoc. Silent whenever `own_binary_name` is absent (not a self-hosting
  # workspace, or the caller did not resolve one) -- the common case.
  defp self_hosting_question(_draft, nil), do: nil

  defp self_hosting_question(draft, own_binary_name) do
    case self_hosting_predicate_ids(draft, own_binary_name) do
      [] ->
        nil

      ids ->
        Question.new(
          "self-hosting-cli-predicate",
          "Predicate(s) #{Enum.join(ids, ", ")} shell out to `#{own_binary_name}` -- " <>
            "the SAME executable this workspace itself builds. That measures the " <>
            "INSTALLED/last-built binary, not the source tree a fix edits (#1668): a " <>
            "source change cannot make it observe anything new until a release/" <>
            "rebuild happens. Prefer a hermetic in-process check (e.g. `mix test`, " <>
            "`mix run -e '...'`) to verify the change directly, or add a " <>
            "build/install step to the goal before this predicate runs.",
          options: [
            Option.new("Swap it for a hermetic in-process check", "hermetic_check"),
            Option.new("Add a build/install step before this predicate", "build_step"),
            Option.new("Leave as-is -- accept the risk", "accept_risk")
          ],
          recommended: "hermetic_check"
        )
    end
  end

  # The `{id, cmd}` pair of every `cli`/`custom_script` predicate in `draft` (nil,
  # a `Kazi.Goal`, or a string-keyed proposal map -- mirrors
  # `custom_script_commands/1`'s two accepted shapes), filtered to those whose
  # `cmd` matches `own_binary_name` exactly (an executable-NAME match, unlike the
  # grep signal's text search over the whole command).
  @self_hosting_providers ~w(cli custom_script)

  defp self_hosting_predicate_ids(nil, _own_binary_name), do: []

  defp self_hosting_predicate_ids(%Kazi.Goal{} = goal, own_binary_name) do
    goal
    |> Kazi.Goal.all_predicates()
    |> Enum.filter(fn predicate ->
      to_string(predicate.kind) in @self_hosting_providers and
        to_string(Map.get(predicate.config, :cmd, "")) == own_binary_name
    end)
    |> Enum.map(&to_string(&1.id))
  end

  defp self_hosting_predicate_ids(%{} = map, own_binary_name) do
    case Map.get(map, "predicates") do
      list when is_list(list) ->
        list
        |> Enum.filter(fn entry ->
          Map.get(entry, "provider") in @self_hosting_providers and
            to_string(Map.get(entry, "cmd", "")) == own_binary_name
        end)
        |> Enum.map(&Map.get(&1, "id"))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp self_hosting_predicate_ids(_draft, _own_binary_name), do: []

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
    idea =~
      ~r/\bendpoint\b|\bhttp\b|\bapi\b|\broute\b|\bGET\b|\bPOST\b|(?<![a-zA-Z0-9])\/[a-zA-Z]/
  end

  defp pins_http_status?(idea) do
    idea =~ ~r/\b[1-5][0-9][0-9]\b/
  end

  # --- naked-grep-predicate signal (issue #924) -------------------------------

  # Shell wrappers whose `-c` argument carries the real command, so a
  # `custom_script` predicate declared as `cmd: "sh", args: ["-c", "grep -q ..."]`
  # (the common shape, mirroring the goal.toml convention) is sniffed on its
  # actual script rather than the literal string "sh".
  @shell_wrappers ~w(sh bash zsh)
  # Any shell combinator marks a command as MORE than a single bare grep (a
  # pipeline, a chained command, or a multi-line script), so it is never flagged
  # as "naked" even if it happens to contain a grep call.
  @shell_combinator_re ~r/&&|\|\||;|\n|\|/
  # A short-opt cluster containing a case-sensitive `v` (invert-match) or `L`
  # (files-without-match) -- grep's negation flags.
  @grep_negation_flag_re ~r/^-[A-Za-z]*[vL][A-Za-z]*$/

  # The command text of every `custom_script` predicate in `draft` (nil, a
  # `Kazi.Goal`, or a string-keyed proposal map -- mirrors
  # `draft_has_live_predicate?/1`'s two accepted shapes).
  defp custom_script_commands(nil), do: []

  defp custom_script_commands(%Kazi.Goal{} = goal) do
    goal
    |> Kazi.Goal.all_predicates()
    |> Enum.filter(&(&1.kind == :custom_script))
    |> Enum.map(&command_text(&1.config))
    |> Enum.reject(&is_nil/1)
  end

  defp custom_script_commands(%{} = map) do
    case Map.get(map, "predicates") do
      list when is_list(list) ->
        list
        |> Enum.filter(&(Map.get(&1, "provider") == "custom_script"))
        |> Enum.map(&command_text/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp custom_script_commands(_draft), do: []

  # Resolves a predicate config/map's `cmd`+`args` (atom or string keys) to the
  # actual command text it runs, unwrapping a shell -c script.
  defp command_text(%{} = config) do
    cmd = Map.get(config, :cmd) || Map.get(config, "cmd")
    args = List.wrap(Map.get(config, :args) || Map.get(config, "args") || [])

    if is_binary(cmd), do: script_from(cmd, Enum.filter(args, &is_binary/1))
  end

  defp command_text(_config), do: nil

  defp script_from(cmd, args) do
    if Path.basename(cmd) in @shell_wrappers do
      case args do
        ["-c", script | _rest] -> script
        _ -> Enum.join([cmd | args], " ")
      end
    else
      Enum.join([cmd | args], " ")
    end
  end

  # A bare, POSITIVE grep-only command: a single grep invocation (no pipeline or
  # chained commands) that is not negated. Combinators are checked with quoted
  # spans stripped first, so a `|` inside the grep PATTERN itself (a regex
  # alternation like `'foo|bar'`) is not mistaken for a shell pipeline.
  defp naked_positive_grep?(text) do
    trimmed = String.trim(text)

    grep_command?(trimmed) and not (strip_quoted(trimmed) =~ @shell_combinator_re) and
      not negated_grep?(trimmed)
  end

  # A companion negative-space assertion: a grep invocation that IS negated
  # (asserts the old/stale pattern is absent).
  defp absence_grep?(text) do
    trimmed = String.trim(text)
    grep_command?(trimmed) and negated_grep?(trimmed)
  end

  defp grep_command?(text), do: text =~ ~r/^!?\s*grep\b/

  # Strips single- and double-quoted spans (so a regex alternation like
  # `'foo|bar'` inside a grep pattern is not mistaken for a shell pipe).
  defp strip_quoted(text), do: Regex.replace(~r/'[^']*'|"[^"]*"/, text, "")

  defp negated_grep?(text) do
    String.starts_with?(text, "!") or
      text |> String.split() |> Enum.any?(&(&1 =~ @grep_negation_flag_re))
  end

  # --- whole-tree-clean-predicate signal (issue #937 Gap E, T59.10) ------------

  # A whole-tree cleanliness assertion: `git status` with a porcelain/short
  # format (`--porcelain`, `--short`, `-s`), or `git diff` with `--quiet`/
  # `--exit-code`. `[^|&;\n]*` keeps the match within the single git invocation so
  # an unrelated later pipeline stage is not swept in.
  @git_tree_clean_re ~r/git\s+(status\b[^|&;\n]*(--porcelain|--short|(?<![\w-])-s(?![\w]))|diff\b[^|&;\n]*(--quiet|--exit-code))/

  # A command asserting the WHOLE tree is clean is flagged only when it is NOT
  # scoped to a pathspec. Scoping makes the check safe under shared-workspace
  # scheduling, so a scoped form never triggers the advisory.
  defp whole_tree_clean_command?(text) do
    text =~ @git_tree_clean_re and not tree_scan_path_scoped?(text)
  end

  # A git pathspec scopes the cleanliness check to specific files: either an
  # explicit `-- <path>` separator, or a path-like token (containing a `/`)
  # trailing the porcelain/short flag.
  defp tree_scan_path_scoped?(text) do
    text =~ ~r/\s--\s+[\w.\/*@-]+/ or
      text =~ ~r/(--porcelain|--short|--quiet|--exit-code)\s+[\w.\/*@-]*\/[\w.\/*@-]*/
  end
end
