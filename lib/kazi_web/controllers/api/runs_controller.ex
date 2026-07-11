defmodule KaziWeb.API.RunsController do
  @moduledoc """
  Stateless JSON read of the fleet run registry (issue #1077).

  Mirrors the SAME projection the starmap and `kazi status --json` (no ref)
  already read from — `Kazi.ReadModel.RunRegistry.list/0` — rather than opening
  a second data-access path (ADR-0011: pure read projection, never mutates a
  run/goal/lease). A bare `fetch()` from an operator's own dashboard needs no
  session cookie or CSRF token, so this is mounted under the `:api` pipeline,
  not `:browser`.
  """
  use KaziWeb, :controller

  alias Kazi.ReadModel.RunRegistry

  @doc "Responds with every registered run: run_id, goal_ref, status, heartbeat age, harness, model."
  def index(conn, _params) do
    runs = Enum.map(RunRegistry.list(), &run_json/1)

    json(conn, %{runs: runs})
  end

  defp run_json(run) do
    %{
      run_id: run.run_id,
      goal_ref: run.goal_ref,
      status: run.status,
      heartbeat_age_s: heartbeat_age_seconds(run),
      harness: run.harness,
      model: run.model
    }
  end

  defp heartbeat_age_seconds(%{heartbeat_at: %DateTime{} = heartbeat_at}) do
    DateTime.diff(DateTime.utc_now(), heartbeat_at, :second)
  end

  defp heartbeat_age_seconds(_run), do: nil
end
