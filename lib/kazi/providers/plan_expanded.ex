defmodule Kazi.Providers.PlanExpanded do
  @moduledoc """
  The `:plan_expanded` predicate (T45.3, UC-059): "the phase `<phase-ref>` has been
  planned" — a DETERMINISTIC, READ-MODEL-ONLY check that needs NO harness to
  evaluate.

  This is what makes **planning itself a convergeable goal**. An *outline phase* in
  a roadmap is a goal that carries this predicate plus a dispatchable planning
  work-item: while the phase is unplanned the predicate is `:fail`, so the loop
  routes work at authoring the phase's goal-set (via `kazi plan`, informed by the
  converged frontier's evidence); once the goal-set exists, passes the clarify
  floor, and is approved, the predicate flips `:pass` and the phase is done. A
  standing roadmap apply thus triggers the phase-N+1 planning pass automatically
  once phase N converges.

  The predicate passes iff ALL THREE conditions hold for `<phase-ref>` — a roadmap
  ref (T45.2) or a single proposal ref:

    1. **exists** — the goal-set is present in the read-model.
    2. **floor** — every goal passes the deterministic clarify floor
       (`Kazi.Authoring.Clarify.gaps/2`) with no open gaps.
    3. **approved** — every member proposal is `approved` (the T3.5 approval state
       machine), not merely `proposed`.

  A `:fail` names WHICH condition failed (`evidence.condition` ∈
  `:exists | :floor | :approved`), so the fixer knows whether to author, sharpen,
  or approve the phase. Every check reads the read-model + runs pure functions — no
  `Kazi.HarnessAdapter` call, ever.

  ## Config

    * `phase` — the phase ref (a roadmap ref or a proposal ref) whose goal-set this
      predicate gates. Required.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Authoring.Clarify
  alias Kazi.Goal.Loader
  alias Kazi.ReadModel

  @impl true
  def evaluate(%Predicate{kind: :plan_expanded, config: config}, _context) do
    phase = config[:phase]
    members = resolve_members(phase)
    gaps = floor_gaps(members)
    unapproved = members |> Enum.reject(&(&1.status == "approved")) |> Enum.map(& &1.proposal_ref)

    cond do
      members == [] ->
        PredicateResult.fail(%{condition: :exists, reason: :phase_not_found, phase: phase})

      gaps != [] ->
        PredicateResult.fail(%{
          condition: :floor,
          reason: :open_clarify_gaps,
          phase: phase,
          gaps: gaps
        })

      unapproved != [] ->
        PredicateResult.fail(%{
          condition: :approved,
          reason: :not_approved,
          phase: phase,
          unapproved: unapproved
        })

      true ->
        PredicateResult.pass(%{
          phase: phase,
          goals: Enum.map(members, & &1.goal_id),
          members: length(members)
        })
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # A phase ref resolves to its goal-set: a T45.2 roadmap ref links N member
  # proposals; a plain proposal ref is a goal-set of one. Read-model only.
  defp resolve_members(phase) when is_binary(phase) do
    case ReadModel.list_proposed_goals_by_roadmap(phase) do
      [] ->
        case ReadModel.get_proposed_goal(phase) do
          nil -> []
          proposal -> [proposal]
        end

      members ->
        members
    end
  end

  defp resolve_members(_phase), do: []

  # The deterministic clarify floor re-run over each persisted goal — pure, no
  # harness. A member with any open gap (or a goal map that no longer loads) is a
  # floor failure naming the goal + gap ids.
  defp floor_gaps(members) do
    Enum.flat_map(members, fn member ->
      case Loader.from_map(member.goal) do
        {:ok, goal} ->
          case Clarify.gaps(member.idea || "", draft: goal) do
            [] -> []
            questions -> [%{goal: member.goal_id, gaps: Enum.map(questions, & &1.id)}]
          end

        {:error, _reason} ->
          [%{goal: member.goal_id, gaps: [:unloadable]}]
      end
    end)
  end
end
