defmodule Kazi.Authoring.Draft do
  @moduledoc """
  A reviewable draft goal proposed from a prose idea (T3.5a, UC-017, ADR-0011) —
  the structured artifact `Kazi.Authoring.propose/2` returns.

  A draft pairs the persisted proposal's review handle and lifecycle state with
  the in-memory `Kazi.Goal` it drafted, so a caller (the CLI T3.5c or the
  dashboard) can present the predicates for review and later
  approve/reject it (T3.5b) against `proposal_ref`. It is a read-side view of a
  `Kazi.ReadModel.ProposedGoal` row with the goal already rehydrated.

  Fields:

    * `proposal_ref` — the proposal's stable review handle (the id T3.5b
      approves/rejects against).
    * `idea` — the verbatim prose idea the draft was synthesised from.
    * `status` — the lifecycle state as an atom (`:proposed` at creation;
      `:approved` / `:rejected` after T3.5b).
    * `goal` — the drafted `Kazi.Goal` (`:create` mode, acceptance predicates),
      or `nil` when the stored goal-file map no longer loads (see `loadable?`).
    * `goal_id` — the goal id string, sourced from the persisted row so it is
      available even when `goal` is `nil` (an unloadable row still names the
      goal it was drafted under).
    * `loadable?` — whether the stored goal-file map rehydrated into `goal`.
      `true` for every draft except a `reject/2` of a proposal whose goal no
      longer loads under the current predicate schema (#945): rejection is a
      pure lifecycle transition and must not require the goal to load.
    * `proposed_at` — when the proposal was recorded.
  """

  alias Kazi.Goal
  alias Kazi.ReadModel.ProposedGoal

  @type status :: :proposed | :approved | :rejected

  @type t :: %__MODULE__{
          proposal_ref: String.t(),
          idea: String.t(),
          status: status(),
          goal: Goal.t() | nil,
          goal_id: String.t(),
          loadable?: boolean(),
          proposed_at: DateTime.t() | nil
        }

  @enforce_keys [:proposal_ref, :idea, :status, :goal_id]
  defstruct proposal_ref: nil,
            idea: nil,
            status: :proposed,
            goal: nil,
            goal_id: nil,
            loadable?: true,
            proposed_at: nil

  @doc """
  Builds a `Draft` from a persisted `Kazi.ReadModel.ProposedGoal` row and its
  rehydrated `Kazi.Goal`, or `nil` when the row's stored goal-file map no
  longer loads (#945 — a `reject/2` of a stale proposal reports success without
  requiring the goal to load). `goal_id` and `loadable?` are derived: `goal_id`
  from the row (always present) so it survives even when `goal` is `nil`;
  `loadable?` is `not is_nil(goal)`. The string `status` column is mapped to
  its atom.
  """
  @spec from_row(ProposedGoal.t(), Goal.t() | nil) :: t()
  def from_row(%ProposedGoal{} = row, goal) when is_nil(goal) or is_struct(goal, Goal) do
    %__MODULE__{
      proposal_ref: row.proposal_ref,
      idea: row.idea,
      status: String.to_existing_atom(row.status),
      goal: goal,
      goal_id: row.goal_id,
      loadable?: not is_nil(goal),
      proposed_at: row.inserted_at
    }
  end
end
