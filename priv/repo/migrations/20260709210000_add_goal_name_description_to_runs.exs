defmodule Kazi.Repo.Migrations.AddGoalNameDescriptionToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add(:goal_name, :string)
      add(:goal_description, :string)
    end
  end
end
