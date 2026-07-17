defmodule Kazi.Repo.Migrations.AddDiscoveryToProposedGoals do
  use Ecto.Migration

  # T45.6 (UC-059): `kazi plan --discover` attaches best-effort discovery findings
  # (stack, use-cases, surface scan) to a drafted proposal as reviewer evidence,
  # surfaced via `kazi status <proposal-ref> --json`. Absent `--discover` (or on a
  # caller-drafts payload, which bypasses discovery) the column stays nil.
  def change do
    alter table(:proposed_goals) do
      add(:discovery, :map)
    end
  end
end
