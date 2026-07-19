defmodule Kazi.Repo.Migrations.CreatePredicateAudits do
  @moduledoc """
  T68.9 (issue #1501): the `predicate_audits` read-model projection — one row
  per goal recording the most recent sampled predicate mutation audit (the
  verification-of-verification score). A READ projection (ADR-0011); its writer
  is `Kazi.ReadModel.record_predicate_audit/1`.

  `sensitivity` is `constrained / tested`, the 0.0–1.0 estimate of how much the
  converged predicate set actually constrains the workspace (higher is better).
  It is nullable with NO default: honest-unknown (ADR-0046) — an audit that
  found nothing to test (`tested == 0`) records NULL, never a fabricated 0.

  Last-write-wins per `goal_ref`: a fresh audit of the same goal UPSERTS on the
  unique `goal_ref`, so the row is always the latest sample, not an accumulating
  log.
  """

  use Ecto.Migration

  def change do
    create table(:predicate_audits) do
      add :goal_ref, :string, null: false

      # Audit counts: `tested` converged predicates were sabotaged; `constrained`
      # flipped red (caught it); `survived` stayed green (weak/gamed).
      add :tested, :integer, null: false
      add :constrained, :integer, null: false
      add :survived, :integer, null: false

      # constrained / tested; NULL when tested == 0 (nothing to audit).
      add :sensitivity, :float

      # The surviving predicate ids (JSON array of strings) — the actionable
      # evidence a fixer strengthens.
      add :survivors, :string

      add :sampled_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:predicate_audits, [:goal_ref])
  end
end
