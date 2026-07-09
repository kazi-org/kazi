defmodule Kazi.Repo.Migrations.AddSessionNameToProposedGoals do
  use Ecto.Migration

  # Session provenance part 2: the session that authored a proposal
  # (`kazi plan --session-name` / KAZI_SESSION_NAME / an auto-detected
  # CLAUDE_CODE_SESSION_ID), so a later approve/apply from a DIFFERENT
  # session can trace a run back to who planned it.
  def change do
    alter table(:proposed_goals) do
      add(:session_name, :string)
    end
  end
end
