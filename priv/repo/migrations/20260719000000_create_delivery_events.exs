defmodule Kazi.Repo.Migrations.CreateDeliveryEvents do
  @moduledoc """
  T67.2 (ADR-0079 decision 3): the `delivery_events` projection table — one row
  per git-derived delivery fact (a plan tick and/or the PR that merged it),
  incremental by last-seen commit and idempotent on re-scan.

  Every column is a join key ADR-0079 §3 names. `session_uuid` and `goal_ref`
  are nullable by construction (honest-unknown, ADR-0046): a purely git-derived
  tick on a trailer-stripped repo — like kazi's own — cannot be joined to a
  session, so it is a fleet-level row with `nil` `session_uuid`. `trailer_session_id`
  is the ADR's optional enrichment, populated only where a repo keeps the
  `Claude-Session:` trailer.

  Idempotency is a non-null `dedup_key` (a composed natural key with empty-string
  sentinels for the nullable parts, since SQLite has no partial unique index over
  a nullable column — the same sentinel trick `run_landed_refs` uses). A re-scan
  of the same history upserts on this key and produces each row exactly once.
  """

  use Ecto.Migration

  def change do
    create table(:delivery_events) do
      # :task_tick (a `- [x] TNN ... Done: <date> (PR #N)` plan line) or
      # :pr_merge (a merged PR referenced by a landing commit).
      add :kind, :string, null: false

      # The delivery join keys (ADR-0079 §3). Any may be nil (honest-unknown).
      add :task_id, :string
      add :epic, :string
      add :done_on, :date
      add :pr_number, :integer
      add :merge_commit_sha, :string, null: false
      add :merged_at, :utc_datetime_usec
      add :repo_slug, :string

      # Session attribution. `session_uuid` is the run-registry-derived spine
      # (nil when no run backs the delivery); `trailer_session_id` is the
      # optional `Claude-Session:` enrichment; `goal_ref` links a kazi run.
      add :session_uuid, :string
      add :goal_ref, :string
      add :trailer_session_id, :string

      # The idempotency key: "kind|task_id|pr_number|merge_commit_sha" with ""
      # sentinels for the nullable parts (SQLite NULLs are distinct in a unique
      # index, which would defeat re-scan idempotency).
      add :dedup_key, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:delivery_events, [:dedup_key])
    create index(:delivery_events, [:session_uuid])
    create index(:delivery_events, [:pr_number])
    create index(:delivery_events, [:epic])
  end
end
