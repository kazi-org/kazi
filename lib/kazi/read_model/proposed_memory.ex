defmodule Kazi.ReadModel.ProposedMemory do
  @moduledoc """
  One row of the proposed-memory store (ADR-0063 Slice 3): a candidate memory
  entry `Kazi.Memory.Harvest` detects at run termination, persisted as a
  reviewable artifact before any human approves it -- mirrors
  `Kazi.ReadModel.ProposedGoal`'s proposal/review/transition shape.

  This is a read-model projection like `Kazi.ReadModel.Iteration` -- it
  records a candidate so an operator surface (`kazi memory list-proposed`)
  can list it, review it, and later approve/reject it. It is authoritative
  for nothing once approved: the target corpus file (`docs/lore.md`,
  `docs/devlog.md`, or a drafted ADR) becomes the truth once
  `Kazi.Memory.Promote` writes the entry there.

  Fields:

    * `proposal_ref` -- the proposal's stable review handle (`mem-<fingerprint>`);
      unique. Callers approve/reject against this id.
    * `fingerprint` -- the detector's deterministic dedup key; unique. Harvest
      is idempotent through this column (`Kazi.ReadModel.propose_memory/1`
      finds the existing row rather than duplicating it).
    * `class` -- the ADR-0036 tier this entry routes to.
    * `content` -- the drafted human-readable entry text.
    * `goal_ref` / `run_id` -- provenance: which goal and run produced the
      candidate.
    * `evidence` -- a machine-readable provenance map (iterations, failing
      predicate ids, error head, outcome).
    * `target_doc` -- the corpus file/dir this class routes to
      (`Kazi.Memory.Promote.target_doc/1`), precomputed at proposal time.
    * `status` -- the lifecycle state. `"proposed"` at creation;
      `"approved"` / `"rejected"` are added by the promotion workflow.
      Stored as a string so a new state is a code change, not a migration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # The lifecycle states a proposed memory may carry.
  @statuses ~w(proposed approved rejected)

  # The ADR-0036 tier map a proposed memory's class routes into.
  @classes ~w(invariant landmine finding benchmark decision architecture)

  @doc "The recognised lifecycle states for a proposed memory."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The recognised memory classes (the ADR-0036 tier map)."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  schema "proposed_memories" do
    field(:proposal_ref, :string)
    field(:fingerprint, :string)
    field(:class, :string)
    field(:content, :string)
    field(:goal_ref, :string)
    field(:run_id, :string)
    field(:evidence, :map, default: %{})
    field(:target_doc, :string)
    field(:status, :string, default: "proposed")

    timestamps(type: :utc_datetime_usec)
  end

  @required [:proposal_ref, :fingerprint, :class, :content, :goal_ref, :target_doc, :status]
  @optional [:run_id, :evidence]

  @doc """
  Builds a changeset for inserting a proposed-memory row.

  Validates the required fields and that `class`/`status` are recognised
  values; the `proposal_ref`/`fingerprint` uniqueness is enforced by the DB
  indexes and surfaced here as a changeset error rather than a crash.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:class, @classes)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:proposal_ref, name: :proposed_memories_proposal_ref_index)
    |> unique_constraint(:fingerprint, name: :proposed_memories_fingerprint_index)
  end

  @doc """
  Builds a changeset for a promotion-workflow transition (approve/reject): a
  `status` change only -- every other field is immutable once proposed.
  """
  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(row, attrs) do
    row
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end
