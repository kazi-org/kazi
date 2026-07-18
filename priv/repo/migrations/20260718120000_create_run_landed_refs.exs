defmodule Kazi.Repo.Migrations.CreateRunLandedRefs do
  @moduledoc """
  T62.6 (issue #1241, part 2): persist the per-group `landed: {branch, pr,
  merge_commit}` refs a `--parallel` run computes at landing time, so
  `kazi status <run-ref>` can show the same per-group landing detail AFTER the
  run has exited — not only the immediate `apply --parallel` invocation's own
  JSON/human output.

  One row per (run_ref, partition_id): the run-ref is the goal id `kazi status`
  looks a run up by; `partition_id` is the collective's stable per-group id (so
  a multi-group run stores one landed-ref row per group). A single-goal run
  landing through the SAME shape stores one row with a nil `partition_id`.
  Re-recording a run's landing UPSERTS (a re-run of the same goal overwrites its
  prior landed refs rather than accumulating stale rows).
  """

  use Ecto.Migration

  def change do
    create table(:run_landed_refs) do
      # The run handle `kazi status <ref>` looks up (the goal id).
      add :run_ref, :string, null: false

      # The collective's stable per-group id (T44.10's partition id). Empty
      # string for a single-goal (non-parallel) landing — SQLite has no partial
      # unique index over a nullable column, so the unique key uses "" as the
      # single-group sentinel rather than NULL.
      add :partition_id, :string, null: false, default: ""

      # The T44.3/T44.10 landed-ref shape: the group's landing branch, its PR
      # handle, and the merge commit. Any can be nil (honest-unknown, ADR-0046):
      # a stub/degraded integrator may surface only a subset.
      add :branch, :string
      add :pr, :string
      add :merge_commit, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_landed_refs, [:run_ref, :partition_id])
    create index(:run_landed_refs, [:run_ref])
  end
end
