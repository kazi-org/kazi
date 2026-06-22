defmodule Kazi.Repo do
  @moduledoc """
  Ecto repo for kazi's local read-model — a SQLite (WAL) materialized
  projection of the `kazi.events` log (concept §7).

  This store is authoritative for *nothing*: it holds predicate/iteration
  history and convergence analytics, is rebuildable from the event log, and is
  the read side of the CQRS split (JetStream is the only coordination truth,
  ETS is the live cache, Git owns code). Queries that feed the LiveView console
  and convergence analytics read from here; writes are projections, never the
  source of truth.
  """

  use Ecto.Repo,
    otp_app: :kazi,
    adapter: Ecto.Adapters.SQLite3
end
