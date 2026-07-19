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
  alias Kazi.ReadModel.{Iteration, Run, RunRegistry}

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

  @doc """
  Seeds the run registry with a fleet spanning TWO projects for the Mission
  Control direction-B browser cert (T63.6): the grid must render project-grouped
  sections under ruled headers, with a converged and a running run so the state
  segmented control has something to regroup. Returns `200 seeded-fleet`.
  """
  def seed_fleet(conn, _params) do
    reset_fleet()

    # Project org-alpha/api: one converged, one running.
    seed_run("mc-alpha-ship", "/tmp/pw/org-alpha/api") |> finish("converged")
    seed_run("mc-alpha-fix", "/tmp/pw/org-alpha/api")
    # Project org-beta/web: one running.
    seed_run("mc-beta-ship", "/tmp/pw/org-beta/web")

    text(conn, "seeded-fleet")
  end

  @doc """
  Seeds the run registry with a SINGLE-project fleet (the direction-B edge case):
  the grid must render without a redundant group header. Returns `200
  seeded-fleet-single`.
  """
  def seed_fleet_single(conn, _params) do
    reset_fleet()

    seed_run("mc-solo-a", "/tmp/pw/org-solo/app")
    seed_run("mc-solo-b", "/tmp/pw/org-solo/app")

    text(conn, "seeded-fleet-single")
  end

  @doc "Clears the run registry so the fleet grid renders its empty state."
  def reset_fleet(conn, _params) do
    reset_fleet()
    text(conn, "reset-fleet")
  end

  @doc """
  Seeds the attention fan-in (T63.8): a stuck run (a clickable run-attention
  alert deep-linking to its drill-in) plus one waiting-on-operator session
  (injected via the `waiting_sessions_fetcher` seam the LiveView reads).
  Returns `200 seeded-attention`.
  """
  def seed_attention(conn, _params) do
    reset_fleet()
    reset_iterations()

    run = seed_run("mc-attention-stuck", "/tmp/pw/org-x/svc")
    # A single failing predicate across enough iterations to trip the detector.
    for i <- 0..2 do
      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: "mc-attention-stuck",
          iteration_index: i,
          predicate_vector: vector(probe: :fail)
        })
    end

    finish(run, "stuck")

    Application.put_env(:kazi, :waiting_sessions_fetcher, fn ->
      [
        %{
          "session" => "pw-sess",
          "machine" => "box-1",
          "summary" => "approve the destructive migration",
          "since" => "2026-07-19T00:00:00Z",
          "age_s" => 90
        }
      ]
    end)

    text(conn, "seeded-attention")
  end

  @doc "Clears the attention fan-in so it renders its empty state."
  def reset_attention(conn, _params) do
    reset_fleet()
    reset_iterations()
    Application.put_env(:kazi, :waiting_sessions_fetcher, fn -> [] end)
    text(conn, "reset-attention")
  end

  @doc """
  Seeds a single ACTIVE goal with two recorded iterations and an iteration
  budget for the Mission Control progress-rate panel cert (T63.9, IA Q4): a
  running run whose vector went 3/8 green with two predicates flipped red→green
  across one transition, and a 2-of-10 iteration budget. Returns `200
  seeded-progress`.
  """
  def seed_progress(conn, _params) do
    reset_iterations()
    reset_fleet()

    run = seed_run("mc-prog-goal", "/tmp/pw/org-alpha/api")

    run
    |> Run.changeset(%{"dispatch_count" => 2, "max_iterations" => 10})
    |> Kazi.Repo.update!()

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "mc-prog-goal",
        iteration_index: 0,
        predicate_vector: octo_vector(1)
      })

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: "mc-prog-goal",
        iteration_index: 1,
        predicate_vector: octo_vector(3)
      })

    text(conn, "seeded-progress")
  end

  defp reset_iterations, do: Kazi.Repo.delete_all(Iteration)
  defp reset_fleet, do: Kazi.Repo.delete_all(Run)

  # An 8-predicate vector whose first `passing` predicates are green.
  defp octo_vector(passing) do
    PredicateVector.new(
      for i <- 0..7, into: %{} do
        {:"p#{i}", PredicateResult.new(if(i < passing, do: :pass, else: :fail), %{})}
      end
    )
  end

  # A live-session run (the liveness stub treats a non-"dead" pid as alive, so it
  # lands in the CURRENT scope the dashboard defaults to).
  defp seed_run(goal_ref, workspace) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "pw-#{goal_ref}",
        pid: "#PID<0.1.0>",
        workspace: workspace,
        goal_ref: goal_ref,
        harness: "claude",
        model: "claude-sonnet-5",
        session_os_pid: "424242"
      })

    run
  end

  defp finish(run, status), do: {:ok, _} = RunRegistry.finish(run.run_id, status)

  defp vector(probe: probe_status) do
    PredicateVector.new(%{
      unit: PredicateResult.pass(%{exit: 0}),
      probe: predicate(probe_status)
    })
  end

  defp predicate(:pass), do: PredicateResult.pass(%{http_status: 200})
  defp predicate(:fail), do: PredicateResult.fail(%{http_status: 503})
end
