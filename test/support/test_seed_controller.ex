defmodule KaziWeb.TestSeedController do
  @moduledoc """
  Test-only seed/reset endpoints for the Playwright browser harness (T3.6b).

  Compiled ONLY in the test env (`test/support` is on the `:test` elixirc path)
  and routed ONLY when `Mix.env() == :test` (see `KaziWeb.Router`), so this never
  ships in dev or prod — it has no place outside hermetic browser certification.

  The Playwright golden-path spec `POST /test/seed`s fixture iterations into the
  read-model before navigating to `/goals`; the empty-state spec `POST /test/reset`s
  to clear it. The dashboard server boots its read-model in shared-sandbox mode
  (`priv/playwright/server.exs`), so writes here are visible to the LiveView's
  reads across processes while staying inside the test transaction. This is a READ
  fixture for the board — it seeds the read-model, never the loop/harness
  (ADR-0011).
  """
  use KaziWeb, :controller

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}
  alias Kazi.ReadModel.Iteration

  @doc """
  Resets the iterations projection to empty, then seeds a deterministic set of
  goals the golden-path spec asserts on. Returns `200 seeded`.
  """
  def seed(conn, _params) do
    reset_iterations()

    # A converged goal (latest iteration green) — 2/2 predicates, 2 iterations.
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "ship-the-api",
        iteration_index: 0,
        predicate_vector: vector(probe: :fail)
      })

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "ship-the-api",
        iteration_index: 1,
        predicate_vector: vector(probe: :pass),
        converged: true
      })

    # An in-progress goal — 1/2 predicates, 1 iteration.
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "fix-the-flaky-test",
        iteration_index: 0,
        predicate_vector: vector(probe: :fail)
      })

    text(conn, "seeded")
  end

  @doc "Clears the iterations projection so the board renders its empty state."
  def reset(conn, _params) do
    reset_iterations()
    text(conn, "reset")
  end

  defp reset_iterations, do: Kazi.Repo.delete_all(Iteration)

  defp vector(probe: probe_status) do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: predicate(probe_status)
    })
  end

  defp predicate(:pass), do: PredicateResult.pass(%{http_status: 200})
  defp predicate(:fail), do: PredicateResult.fail(%{http_status: 503})
end
