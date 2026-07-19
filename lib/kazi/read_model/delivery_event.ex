defmodule Kazi.ReadModel.DeliveryEvent do
  @moduledoc """
  A git-derived delivery fact (T67.2, ADR-0079 §3): one row per plan tick
  (`:task_tick`) and/or the PR that merged it (`:pr_merge`). A pure read
  projection (ADR-0011 §2) written only through the daemon write op (ADR-0068,
  `Kazi.ReadModel.Writer`), joinable to the run registry on `session_uuid` /
  `goal_ref`.

  Nullability is honest-unknown (ADR-0046): `session_uuid`/`goal_ref` are `nil`
  for a delivery no kazi run backs (a fleet-level row), and `trailer_session_id`
  is `nil` unless the repo keeps the `Claude-Session:` trailer this repo strips.

  `dedup_key` is the idempotency key `Kazi.ReadModel.DeliveryProjection` composes
  so a re-scan of the same history produces each row exactly once.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(task_tick pr_merge)

  schema "delivery_events" do
    field(:kind, :string)
    field(:task_id, :string)
    field(:epic, :string)
    field(:done_on, :date)
    field(:pr_number, :integer)
    field(:merge_commit_sha, :string)
    field(:merged_at, :utc_datetime_usec)
    field(:repo_slug, :string)
    field(:session_uuid, :string)
    field(:goal_ref, :string)
    field(:trailer_session_id, :string)
    field(:dedup_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:kind, :merge_commit_sha, :dedup_key]
  @optional [
    :task_id,
    :epic,
    :done_on,
    :pr_number,
    :merged_at,
    :repo_slug,
    :session_uuid,
    :goal_ref,
    :trailer_session_id
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:dedup_key)
  end
end
