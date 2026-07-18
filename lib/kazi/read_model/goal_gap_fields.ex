defmodule Kazi.ReadModel.GoalGapFields do
  @moduledoc """
  The three read-model gap fields the T63.3 drill-in/history redesign asked for
  (E63, UC-062, ADR-0011 — projection only, NO new write path).

  The approved T63.3 gap list named three groups of data the redesigned
  `/goals/:goal/drillin` and `/goals/:goal/history` views want but the read-model
  did not project. This struct exposes exactly those three, computed over the
  goal's existing iteration rows (`Kazi.ReadModel.Iteration`) — never a new column
  and never a fabricated value. Absent data is surfaced as explicit `nil`/empty so
  a view can render an honest "unknown" (ADR-0046) rather than inventing one:

    * `narrative_intent` — one entry per recorded iteration, oldest-first, each
      `%{iteration_index, action_kind, action_params}`. `action_kind` is the
      coarse action the loop recorded for that iteration (e.g. `"dispatch_agent"`)
      or `nil` for an observe-only iteration that recorded none. There is NO
      free-text intent field on disk (the gap list is explicit: `action_kind` is a
      coarse enum, not a summary), so this projects the stored action verbatim and
      lets the view paraphrase — it never manufactures a sentence.

    * `predicate_groups` — a `%{predicate_id => group_tag | nil}` map for the
      latest vector's predicate ids. The group is *derived* from the id's own
      naming convention (the prefix before its first delimiter — `.`, `:`, `/`,
      `-`, `_`), which is exactly the inference the mock's row grouping relies on.
      An id with no separable prefix maps to `nil` (honest-unknown), never a
      guessed bucket. This is a display grouping only; it is not the goal-authored
      scoring GROUPS of ADR-0020.

    * `missing_counters` — a per-goal `%{tools_missing, context_missing,
      total_iterations}` tally of how many iterations carry an empty `tools` /
      `context` map (absent counters, T34.3 — "absent ≠ zero"). This tells the
      view how much of a goal's tool/context history is genuinely unavailable so
      it can say so instead of rendering fabricated zeros.

  Built by `Kazi.ReadModel.goal_gap_fields/1`.
  """

  @type narrative_entry :: %{
          iteration_index: non_neg_integer(),
          action_kind: String.t() | nil,
          action_params: map()
        }

  @type missing_counters :: %{
          tools_missing: non_neg_integer(),
          context_missing: non_neg_integer(),
          total_iterations: non_neg_integer()
        }

  @type t :: %__MODULE__{
          goal_ref: String.t(),
          narrative_intent: [narrative_entry()],
          predicate_groups: %{optional(String.t()) => String.t() | nil},
          missing_counters: missing_counters()
        }

  @enforce_keys [:goal_ref, :narrative_intent, :predicate_groups, :missing_counters]
  defstruct [:goal_ref, :narrative_intent, :predicate_groups, :missing_counters]

  # The delimiters an on-disk predicate id may use to separate a surface/category
  # prefix from the rest (guard vs. loader vs. provider, per the gap list). The
  # first one that appears wins; an id with none has no derivable group.
  @group_delimiters ~r/[.\/:_-]/

  @doc """
  Derives the display group tag for a predicate id: the prefix before its first
  delimiter (`.`, `:`, `/`, `-`, `_`), or `nil` when the id has no separable
  prefix. Pure and deterministic — a function of the id string alone, so it is a
  projection, not a fabricated value.
  """
  @spec group_for(String.t()) :: String.t() | nil
  def group_for(predicate_id) when is_binary(predicate_id) do
    case Regex.split(@group_delimiters, predicate_id, parts: 2) do
      [prefix, _rest] when prefix != "" -> prefix
      _ -> nil
    end
  end
end
