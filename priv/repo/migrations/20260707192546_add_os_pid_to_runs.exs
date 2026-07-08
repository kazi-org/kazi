defmodule Kazi.Repo.Migrations.AddOsPidToRuns do
  use Ecto.Migration

  # T48.15: the OS process id for liveness detection in run reaping. Recorded
  # when a dispatch starts the child process, used to distinguish live vs. dead
  # runs on the attention queue.
  def change do
    alter table(:runs) do
      add(:os_pid, :string)
    end
  end
end
