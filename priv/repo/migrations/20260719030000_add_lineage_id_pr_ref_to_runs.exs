defmodule Kazi.Repo.Migrations.AddLineageIdPrRefToRuns do
  @moduledoc """
  TKE.5 (`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2, ADR-0086/ADR-0087 lineage):
  resume handle / run-lineage columns on `runs`.

  `lineage_id` is the shared id a chain of runs continuing the same logical
  task (via `--resume-pr`/a lane contract's `resume_pr` field) is recorded
  under — a fresh run's `lineage_id` is its own `run_id`; a resumed run's
  copies the prior landing run's `lineage_id` (`RunRegistry.resolve_lineage_id/2`).

  `pr_ref` is the normalized PR number (no leading `#`) a run either landed
  (a successful in-place `--integration-command` hook invocation, TKE.3,
  recorded via `RunRegistry.record_pr_ref/2`) or resumed against. Indexed —
  `RunRegistry.find_by_pr_ref/1` is the resolution path every `--resume-pr`
  invocation hits before dispatch.

  Both nil on every pre-TKE.5 row (and on any run that never lands/resumes a
  PR) — honest-unknown, no backfill.
  """

  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :lineage_id, :string
      add :pr_ref, :string
    end

    create index(:runs, [:pr_ref])
    create index(:runs, [:lineage_id])
  end
end
