defmodule Kazi.Repo.Migrations.CreateProposedMemories do
  @moduledoc """
  ADR-0063 (Slice 3): persist a memory entry CANDIDATE `Kazi.Memory.Harvest`
  detects at run termination, before any human has reviewed it -- mirrors
  `create_proposed_goals.exs`'s shape (proposal -> review -> transition).

  Nothing writes here except `Kazi.ReadModel.propose_memory/1`; nothing reads
  a row back into a dispatch prompt (harvesting is controller-side only, never
  wired into the harness/dispatch path). A human reviews via `kazi memory
  list-proposed` and transitions the row to `approved` (which additionally
  writes the entry into its routed corpus file, `Kazi.Memory.Promote`) or
  `rejected` (kept for audit, never re-proposed) via `kazi memory approve` /
  `kazi memory reject`.

  Each row is one proposed memory:

    * `proposal_ref` -- the stable review handle (e.g. `mem-<fingerprint>`);
      unique.
    * `fingerprint` -- the detector's deterministic dedup key; unique. Harvest
      re-running on the same facts finds the existing row by this key rather
      than inserting a duplicate (ADR-0063 decision 3's "not re-proposed").
    * `class` -- the ADR-0036 tier the entry routes to: `invariant` /
      `landmine` / `finding` / `benchmark` / `decision` / `architecture`.
    * `content` -- the drafted human-readable entry text (detector-originated
      facts only; ADR-0063 decision 1 -- a model may phrase, never originate).
    * `goal_ref` / `run_id` -- provenance: which goal and run produced this
      candidate (ADR-0063 decision 2).
    * `evidence` -- a machine-readable provenance map (iterations, failing
      predicate ids, error head, outcome) so any belief can be traced back to
      the facts that motivated it.
    * `target_doc` -- the corpus file/dir this class routes to
      (`Kazi.Memory.Promote.target_doc/1`), precomputed at proposal time.
    * `status` -- `proposed` at creation; `approved`/`rejected` are added by
      the promotion workflow. A string so a new state is a code change, not a
      migration.

  Rebuildable read-model projection like the rest of the store: authoritative
  for nothing once approved (the corpus file IS the truth once promoted).
  """

  use Ecto.Migration

  def change do
    create table(:proposed_memories) do
      add :proposal_ref, :string, null: false
      add :fingerprint, :string, null: false
      add :class, :string, null: false
      add :content, :string, null: false
      add :goal_ref, :string, null: false
      add :run_id, :string
      add :evidence, :map, null: false, default: %{}
      add :target_doc, :string, null: false
      add :status, :string, null: false, default: "proposed"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:proposed_memories, [:proposal_ref])
    create unique_index(:proposed_memories, [:fingerprint])
    create index(:proposed_memories, [:status])
    create index(:proposed_memories, [:goal_ref])
  end
end
