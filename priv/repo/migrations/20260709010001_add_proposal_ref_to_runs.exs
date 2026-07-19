defmodule Kazi.Repo.Migrations.AddProposalRefToRuns do
  use Ecto.Migration

  # Session provenance part 2: when a run is registered from an approved
  # proposal (`kazi apply <proposal-ref>`), the proposal_ref it came from is
  # copied onto the run row -- so a run's provenance is traceable back to the
  # proposal (and its session_name) even when the applying session differs
  # from the planning one. Nil for a plain goal-file-path run (unchanged
  # behavior).
  def change do
    alter table(:runs) do
      add(:proposal_ref, :string)
    end
  end
end
