defmodule Kazi.ReadModel.ProposedGoal do
  @moduledoc """
  One row of the proposed-goal store (T3.5a, ADR-0011): a `Kazi.Goal` drafted
  from a prose idea by `Kazi.Authoring.propose/2`, persisted as a reviewable
  artifact before any human approves it.

  This is a read-model projection like `Kazi.ReadModel.Iteration` — it records a
  proposal so an operator surface (the CLI T3.5c, the Telegram bridge T3.7a) can
  list it, review it, and later approve/reject it (T3.5b). It is authoritative for
  nothing once a proposal is approved into an executable goal.

  Fields:

    * `proposal_ref` — the proposal's stable review handle; unique. Callers
      approve/reject against this id (T3.5b).
    * `idea` — the verbatim prose idea the draft was synthesised from, kept for
      review and audit.
    * `goal_id` — the drafted `Kazi.Goal.id` (the id the goal runs under once
      approved).
    * `status` — the lifecycle state. `"proposed"` at creation; `"approved"` /
      `"rejected"` are added by the approval workflow (T3.5b). Stored as a string
      so a new state is a code change, not a migration.
    * `goal` — the serialized draft `Kazi.Goal` in the canonical goal-file map
      shape `Kazi.Goal.Loader.from_map/1` accepts, so T3.5b rehydrates it into a
      runnable goal through the same validated loader the CLI uses.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # The lifecycle states a proposed goal may carry. T3.5a only writes `:proposed`;
  # the approval workflow (T3.5b) adds the terminal transitions. Listed here so a
  # surface can reason about the set without reaching into the approval code.
  @statuses ~w(proposed approved rejected)

  @doc "The recognised lifecycle states for a proposed goal."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  schema "proposed_goals" do
    field(:proposal_ref, :string)
    field(:idea, :string)
    field(:goal_id, :string)
    field(:status, :string, default: "proposed")
    field(:goal, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @required [:proposal_ref, :idea, :goal_id, :status, :goal]

  @doc """
  Builds a changeset for inserting a proposed-goal row.

  Validates the required fields and that `status` is a recognised lifecycle
  state; the `proposal_ref` uniqueness is enforced by the DB index and surfaced
  here as a changeset error so a duplicate ref is a clean conflict rather than a
  crash.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:proposal_ref, name: :proposed_goals_proposal_ref_index)
  end
end
