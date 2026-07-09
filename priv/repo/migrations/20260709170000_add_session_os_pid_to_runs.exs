defmodule Kazi.Repo.Migrations.AddSessionOsPidToRuns do
  use Ecto.Migration

  # The OS pid of the driving agent session (the nearest `claude` ancestor of
  # the kazi process at registration), so the dashboard can tell runs whose
  # session is still alive from dead history. Nullable: runs registered by
  # older binaries (or with no detectable session ancestor) leave it NULL.
  def change do
    alter table(:runs) do
      add(:session_os_pid, :string)
    end
  end
end
