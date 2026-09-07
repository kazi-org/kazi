defmodule Kazi.Repo.Migrations.AddUsageProvenance do
  use Ecto.Migration

  def change do
    for table <- [:runs, :iterations] do
      alter table(table) do
        add :usage, :map
        add :usage_provenance, :map
      end
    end
  end
end
