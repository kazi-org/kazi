defmodule Kazi.Repo.Migrations.AddRunQualification do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :qualification, :map
    end
  end
end
