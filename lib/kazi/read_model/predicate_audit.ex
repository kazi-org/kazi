defmodule Kazi.ReadModel.PredicateAudit do
  @moduledoc """
  A row in the `predicate_audits` projection (T68.9, issue #1501): the most
  recent sampled predicate mutation audit for a goal — the
  verification-of-verification score `Kazi.Audit.PredicateSensitivity` produces.
  See `priv/repo/migrations/20260719020000_create_predicate_audits.exs`.

  Last-write-wins on `goal_ref`: a fresh audit upserts the row, so it always
  holds the LATEST sample. `sensitivity` (`constrained / tested`) is `nil` when
  the audit found nothing to test — honest-unknown (ADR-0046), never a
  fabricated 0. `survivors` is a JSON-encoded list of the predicate ids that
  stayed green under the sabotage (the actionable weak/gamed predicates).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "predicate_audits" do
    field(:goal_ref, :string)
    field(:tested, :integer)
    field(:constrained, :integer)
    field(:survived, :integer)
    field(:sensitivity, :float)
    field(:survivors, :string)
    field(:sampled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:goal_ref, :tested, :constrained, :survived, :sampled_at]
  @optional [:sensitivity, :survivors]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:goal_ref, name: :predicate_audits_goal_ref_index)
  end
end
