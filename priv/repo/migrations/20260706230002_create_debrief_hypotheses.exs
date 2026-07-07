defmodule Kazi.Repo.Migrations.CreateDebriefHypotheses do
  @moduledoc """
  The SELF-REPORT (hypothesis) tier of the economy feedback loop (T48.11,
  ADR-0058 §3): one row per capped item an opted-in debrief answer named as
  "needed but had to discover myself". WRITE-ONLY by design — nothing reads this
  table back into a prompt (see `Kazi.ReadModel.DebriefHypothesis`).
  """

  use Ecto.Migration

  def change do
    create table(:debrief_hypotheses) do
      # The goal this hypothesis belongs to (Kazi.Goal.id — string or atom,
      # stored as text).
      add :goal_ref, :string, null: false

      # The fleet run registry id (Kazi.Runtime's Ecto.UUID); null when the
      # loop is driven without a run identity (e.g. a bare Kazi.Loop in a test).
      add :run_id, :string

      # 0-based per-goal iteration index the debrief answer rode in on.
      add :iteration, :integer, null: false

      # One capped, redacted hypothesis item (Kazi.Harness.Debrief enforces the
      # item-count and per-item byte caps before a row is ever built).
      add :item, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Hypothesis reads (a future T48.10/T48.12 analysis tool) scan by goal in
    # iteration order.
    create index(:debrief_hypotheses, [:goal_ref, :iteration])
    create index(:debrief_hypotheses, [:run_id])
  end
end
