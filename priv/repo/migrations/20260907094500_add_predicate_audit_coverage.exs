defmodule Kazi.Repo.Migrations.AddPredicateAuditCoverage do
  use Ecto.Migration

  def change do
    alter table(:predicate_audits) do
      add :coverage, :map
    end
  end
end
