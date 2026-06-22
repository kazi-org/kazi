defmodule Kazi.Repo.Migrations.CreateProposedGoals do
  @moduledoc """
  T3.5a (ADR-0011): persist a goal *proposed* from a prose idea before any human
  has reviewed it. `Kazi.Authoring.propose/2` drives the harness to draft a
  `Kazi.Goal` (acceptance predicates) from an idea and stores it here as status
  `proposed` — a reviewable artifact, not yet a runnable goal.

  This is the one WRITE path the Slice-3 operator surfaces share (CLI T3.5c,
  Telegram T3.7a): each authors a draft through the same `Kazi.Authoring` API,
  never a back-door into a running reconciliation (ADR-0011 §2).

  Each row is one proposed goal:

    * `proposal_ref` — the stable id of the proposal (its review handle); unique.
    * `idea` — the verbatim prose idea the draft was synthesised from, kept for
      review/audit.
    * `goal_id` — the drafted `Kazi.Goal.id` (the id the goal runs under once
      approved).
    * `status` — the lifecycle state: `proposed` now; `approved`/`rejected` are
      added by the approval workflow (T3.5b). A string so new states need no
      migration.
    * `goal` — the serialized draft `Kazi.Goal` in the canonical goal-file map
      shape `Kazi.Goal.Loader.from_map/1` accepts, so T3.5b can rehydrate it into
      a runnable goal through the same validated loader the CLI uses.

  Rebuildable read-model projection like the rest of the store (concept §7):
  authoritative for nothing once approved into an executable goal.
  """

  use Ecto.Migration

  def change do
    create table(:proposed_goals) do
      # The proposal's review handle: a stable id callers approve/reject against
      # (T3.5b). Unique — one row per proposal.
      add :proposal_ref, :string, null: false

      # The verbatim prose idea the draft was synthesised from, kept for review
      # and audit of what was asked for vs. what was drafted.
      add :idea, :string, null: false

      # The drafted goal's id (the id it will run under once approved).
      add :goal_id, :string, null: false

      # Lifecycle state: "proposed" at creation; the approval workflow (T3.5b)
      # transitions it to "approved"/"rejected". A string so adding a state is a
      # code change, not a migration.
      add :status, :string, null: false, default: "proposed"

      # The serialized draft Kazi.Goal in the goal-file map shape
      # Kazi.Goal.Loader.from_map/1 accepts (SQLite stores :map as JSON text), so
      # T3.5b rehydrates it into a runnable goal through the same validated loader.
      add :goal, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One proposal per ref; the review handle is unique.
    create unique_index(:proposed_goals, [:proposal_ref])

    # Surfaces list proposals by lifecycle state (e.g. "show me what's pending");
    # index the column they filter on.
    create index(:proposed_goals, [:status])
  end
end
