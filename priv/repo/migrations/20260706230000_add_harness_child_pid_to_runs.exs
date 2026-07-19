defmodule Kazi.Repo.Migrations.AddHarnessChildPidToRuns do
  use Ecto.Migration

  # Issue #857: the OS pid of the dispatched harness subprocess, recorded so a
  # fresh apply for the same goal_ref can warn when a previous run's harness
  # child is still alive (a probable orphan racing the resumed run). nil until
  # a dispatch reports one; a prior run's harness_child_pid persists after that
  # run finishes so the check can still fire against it.
  def change do
    alter table(:runs) do
      add(:harness_child_pid, :string)
    end
  end
end
