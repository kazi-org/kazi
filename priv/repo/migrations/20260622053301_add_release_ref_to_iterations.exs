defmodule Kazi.Repo.Migrations.AddReleaseRefToIterations do
  @moduledoc """
  T3.3c release tagging: persist the release ref recorded on a successful deploy
  so the artifact that was shipped is queryable from the read-model (UC-015). A
  release ref (a git tag by default) names *what* was deployed, distinct from the
  live service URL the iteration's evidence already carries.

  Additive, backward-compatible column on the existing iteration / evidence log:
  a nullable string. Iterations that did not deploy (or pre-date this migration)
  leave it null.
  """

  use Ecto.Migration

  def change do
    alter table(:iterations) do
      # The release ref recorded on a successful deploy (T3.3c). Nullable: most
      # iterations are not deploys, so the column is empty for them.
      add :release_ref, :string
    end
  end
end
