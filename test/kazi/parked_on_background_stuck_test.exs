defmodule Kazi.ParkedOnBackgroundStuckTest do
  @moduledoc """
  T68.4 (#1546): a full-cost dispatch that ENDS PARKED on its own backgrounded
  verification jobs (a `mix test` / doc-freshness suite it launched with the Bash
  tool) with ZERO file edits is a fail-fast wedge — grinding cannot converge a
  session that only verifies. The loop stops `:stuck` with the distinct
  `:parked_on_background` cause after ONE wasted arc (never a bigger budget),
  surfaced on `result.cause` / the snapshot so `kazi status` and the attention
  queue name it exactly.

  Distinct from #1072 `:permission_denied` (nothing was refused here — the agent
  ran plenty of tools) and from an ordinary failing-set `:stuck` (it never made
  an edit; it only verified, then parked).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Budget, Goal, Predicate, PredicateResult}

  # The code predicate fails on every observation, so the loop DISPATCHES the
  # agent (rather than converging) — the precondition for the parked wedge.
  defmodule AlwaysFailingCodeProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context), do: PredicateResult.fail(%{id: id})
  end

  # A harness whose dispatch cost real money, changed NO files (no :touched), and
  # whose final message parks on background verification it launched — the exact
  # #1546 terminal shape.
  defmodule ParkedHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result:
           "I'm waiting for two background checks to finish: the full `mix test` " <>
             "suite and the doc-freshness script suite. I'll report results and " <>
             "finalize once both complete.",
         cost_usd: 4.0,
         cost: %{tokens: 120_000}
       }}
    end
  end

  # A harness that spent real money AND actually edited a file — proves the wedge
  # is diff-gated: a dispatch that landed work is making progress, never killed
  # even if its final message also mentions a background job.
  defmodule ProductiveHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: "Edited lib/foo.ex; a background `mix test` is still running.",
         touched: ["lib/foo.ex"],
         cost_usd: 4.0,
         cost: %{tokens: 120_000}
       }}
    end
  end

  defmodule ImmediateIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule ImmediateDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp start_loop(harness, opts) do
    goal =
      Goal.new("parked-on-background",
        predicates: [Predicate.new(:code, :tests)],
        # Generous budget: a pre-fix loop would grind to :over_budget buying the
        # identical parked no-op. The fail-fast must stop far short.
        budget: Budget.new(max_iterations: 20)
      )

    base = [
      goal: goal,
      providers: %{tests: AlwaysFailingCodeProvider},
      harness: harness,
      integrate: ImmediateIntegrate,
      deploy: ImmediateDeploy,
      reobserve_interval_ms: 1,
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  test "a zero-diff dispatch that parks on background jobs stops :stuck with :parked_on_background" do
    {:ok, loop} = start_loop(ParkedHarness, [])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :stopped
    assert result.reason == :stuck

    assert result.cause == %{
             class: :parked_on_background,
             ids: [:code],
             reasons: nil,
             exhausted: nil
           }

    # Stopped after ONE wasted arc, nowhere near the 20-iteration ceiling — the
    # whole point (react after one arc, not by draining the budget).
    assert result.iterations < 20

    snap = Kazi.Loop.snapshot(loop)
    assert snap.cause == result.cause
  end

  test "a dispatch that edited a file is NOT killed even if it mentions a background job" do
    # The productive harness keeps failing the code predicate (the edit didn't fix
    # it), so the loop keeps dispatching until the iteration budget stops it. It
    # must NOT fail-fast on the parked wedge, so it runs to the 20-iteration
    # ceiling instead of stopping after one arc.
    {:ok, loop} = start_loop(ProductiveHarness, [])

    assert {:ok, result} = Kazi.Loop.await(loop, 10_000)

    # It terminated on the budget path, NOT the parked-on-background wedge.
    refute match?(%{class: :parked_on_background}, result.cause)
    assert result.iterations >= 2
  end
end
