defmodule Kazi.CLI.JobOutcomeTest do
  @moduledoc """
  Pure unit coverage for `Kazi.CLI.JobOutcome.classify/1` (TKE.7,
  `docs/plans/E-KAZI-ENTRYPOINT.md` §1.3), in complete isolation from
  `Kazi.CLI` — no CLI dispatch, no git, no goal-file. Mirrors the isolation
  style of `Kazi.Loop.CauseClassTest`.

  Table-driven over EVERY `(status, integration_landed, has_commits)`
  combination the plan's acceptance criteria names, per TKE.7's own GREEN
  text. `Kazi.CLI.JobOutcomeWiringTest` covers the CLI-side gating (present
  only on a lane-mode run, absent otherwise) through the real `Kazi.CLI.run/2`
  entrypoint.
  """
  use ExUnit.Case, async: true

  doctest Kazi.CLI.JobOutcome

  alias Kazi.CLI.JobOutcome

  describe "status: converged" do
    test "nothing to land (no integration object at all) -> done" do
      assert JobOutcome.classify(%{
               status: "converged",
               integration_landed: nil,
               has_commits: false
             }) == :done
    end

    test "a successful landing (integration.landed: true) -> done" do
      assert JobOutcome.classify(%{
               status: "converged",
               integration_landed: true,
               has_commits: false
             }) == :done
    end

    test "an unlanded-but-resumable landing (integration.landed: false) -> checkpointed" do
      assert JobOutcome.classify(%{
               status: "converged",
               integration_landed: false,
               has_commits: false
             }) == :checkpointed
    end

    test "has_commits is irrelevant once converged" do
      for has_commits <- [true, false] do
        assert JobOutcome.classify(%{
                 status: "converged",
                 integration_landed: nil,
                 has_commits: has_commits
               }) == :done

        assert JobOutcome.classify(%{
                 status: "converged",
                 integration_landed: false,
                 has_commits: has_commits
               }) == :checkpointed
      end
    end
  end

  describe "status: stuck / over_budget" do
    for status <- ["stuck", "over_budget"] do
      test "#{status} with committed progress -> checkpointed" do
        assert JobOutcome.classify(%{
                 status: unquote(status),
                 integration_landed: nil,
                 has_commits: true
               }) == :checkpointed
      end

      test "#{status} with zero committed progress -> blocked" do
        assert JobOutcome.classify(%{
                 status: unquote(status),
                 integration_landed: nil,
                 has_commits: false
               }) == :blocked
      end

      test "#{status}'s integration_landed is irrelevant to the blocked/checkpointed split" do
        for landed <- [true, false, nil] do
          assert JobOutcome.classify(%{
                   status: unquote(status),
                   integration_landed: landed,
                   has_commits: true
                 }) == :checkpointed

          assert JobOutcome.classify(%{
                   status: unquote(status),
                   integration_landed: landed,
                   has_commits: false
                 }) == :blocked
        end
      end
    end
  end

  describe "status: error / tampered" do
    for status <- ["error", "tampered"] do
      test "#{status} is always refused, regardless of integration/commits" do
        for landed <- [true, false, nil], has_commits <- [true, false] do
          assert JobOutcome.classify(%{
                   status: unquote(status),
                   integration_landed: landed,
                   has_commits: has_commits
                 }) == :refused
        end
      end
    end
  end

  describe "an unrecognized status" do
    test "raises rather than silently inventing an outcome" do
      assert_raise FunctionClauseError, fn ->
        JobOutcome.classify(%{status: "paused", integration_landed: nil, has_commits: false})
      end
    end
  end
end
