defmodule Kazi.Repo.Migrations.AddSessionToRuns do
  use Ecto.Migration

  # Session identity on the fleet registry row (ADR-0057 follow-up):
  # `session_name` is the operator-assigned label (`kazi apply --session-name` /
  # KAZI_SESSION_NAME) that tells concurrent runs apart on the starmap rail;
  # `harness_session_id` is the inner harness's own session id (the claude
  # envelope's `session_id`), captured so a run can be resumed interactively
  # (`claude -r <id>`) straight from the dashboard.
  def change do
    alter table(:runs) do
      add(:session_name, :string)
      add(:harness_session_id, :string)
    end
  end
end
