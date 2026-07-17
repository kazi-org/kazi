defmodule Kazi.ReadModel.ProposedGoal do
  @moduledoc """
  One row of the proposed-goal store (T3.5a, ADR-0011): a `Kazi.Goal` drafted
  from a prose idea by `Kazi.Authoring.propose/2`, persisted as a reviewable
  artifact before any human approves it.

  This is a read-model projection like `Kazi.ReadModel.Iteration` — it records a
  proposal so an operator surface (the CLI T3.5c or the dashboard) can
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
    * `session_name` — the operator/orchestrator session that authored this
      proposal (`kazi plan --session-name`, `KAZI_SESSION_NAME`, or an
      auto-detected `CLAUDE_CODE_SESSION_ID`; nil when none resolved). The
      plan → approve → apply lifecycle is DESIGNED to be cross-session (a
      different session may approve or apply what this one planned) -- this
      field is what lets that handoff be traced afterward instead of just
      inferred. `Kazi.Runtime` copies it (plus `proposal_ref`) onto a run's
      `runs` row at registration time, best-effort, by matching `goal_id`.
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
    field(:session_name, :string)
    # T45.2 (UC-059): the shared roadmap ref linking the proposals a single
    # `kazi plan --project` payload drafted. nil for an ordinary single-goal plan.
    field(:roadmap_ref, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:proposal_ref, :idea, :goal_id, :status, :goal]
  @optional [:session_name, :roadmap_ref]

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
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:proposal_ref, name: :proposed_goals_proposal_ref_index)
  end

  @doc """
  Builds a changeset for an approval-workflow transition (T3.5b): a `status`
  change (`approve`/`reject`) and/or a refreshed `goal` payload (`edit`).

  Casts only the mutable lifecycle fields — `proposal_ref`, `idea` and `goal_id`
  are immutable once proposed — and validates `status` is a recognised state. The
  state-machine guard (which prior states may transition to which) is enforced by
  `Kazi.Authoring` before this changeset is built; this only validates the shape
  of the resulting row.
  """
  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(row, attrs) do
    row
    |> cast(attrs, [:status, :goal])
    |> validate_required([:status, :goal])
    |> validate_inclusion(:status, @statuses)
  end
end
