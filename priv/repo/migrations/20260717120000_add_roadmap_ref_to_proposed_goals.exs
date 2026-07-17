defmodule Kazi.Repo.Migrations.AddRoadmapRefToProposedGoals do
  use Ecto.Migration

  # T45.2 (UC-059): a caller-drafts `kazi plan --project` payload persists a SET of
  # linked proposals sharing one ROADMAP REF, so `kazi status <roadmap-ref>` can
  # resolve the roadmap back to its member proposals. Absent (a single-goal plan)
  # the column stays nil — byte-identical to today's single-proposal behaviour.
  def change do
    alter table(:proposed_goals) do
      add(:roadmap_ref, :string)
    end

    create(index(:proposed_goals, [:roadmap_ref]))
  end
end
