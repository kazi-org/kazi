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
    * `goal` — the drafted `Kazi.Goal` (`:create` mode, acceptance predicates).
    * `proposed_at` — when the proposal was recorded.
  """

  alias Kazi.Goal
  alias Kazi.ReadModel.ProposedGoal

  @type status :: :proposed | :approved | :rejected

  @type t :: %__MODULE__{
          proposal_ref: String.t(),
          idea: String.t(),
          status: status(),
          goal: Goal.t(),
          proposed_at: DateTime.t() | nil
        }

  @enforce_keys [:proposal_ref, :idea, :status, :goal]
  defstruct proposal_ref: nil,
            idea: nil,
            status: :proposed,
            goal: nil,
            proposed_at: nil

  @doc """
  Builds a `Draft` from a persisted `Kazi.ReadModel.ProposedGoal` row and the
  rehydrated `Kazi.Goal`.

  The row carries the proposal metadata (ref, idea, status, timestamp); `goal` is
  the in-memory goal (freshly drafted by `propose/2`, or rehydrated from the row's
  serialized goal-file map by T3.5b). The string `status` column is mapped to its
  atom.
  """
  @spec from_row(ProposedGoal.t(), Goal.t()) :: t()
  def from_row(%ProposedGoal{} = row, %Goal{} = goal) do
    %__MODULE__{
      proposal_ref: row.proposal_ref,
      idea: row.idea,
      status: String.to_existing_atom(row.status),
      goal: goal,
      proposed_at: row.inserted_at
    }
  end
end
