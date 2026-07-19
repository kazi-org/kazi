defmodule Kazi.Memory.Harvest do
  @moduledoc """
  ADR-0063: at run termination (the "debrief" point), deterministically
  detects candidate memory entries from RECORDED FACTS and stores them as
  proposals (`Kazi.ReadModel.ProposedMemory`) -- never directly into the
  corpus. A wrong belief injected straight into the corpus is worse than none
  (it would be recalled into every future relevant dispatch, ADR-0062);
  nothing here writes a corpus file. Promotion of an APPROVED proposal into
  its routed corpus file is `Kazi.Memory.Promote`, driven by a human via
  `kazi memory approve` -- kazi never commits memory on its own authority.

  ## The detector (decision 1: deterministic pattern first)

  The one detector implemented today reads the goal's own persisted
  iteration log (`Kazi.ReadModel.list_iterations/1` -- the same episodic
  facts `Kazi.Memory.AttemptLedger` folds, ADR-0061) and looks for a
  DISPATCH APPROACH -- the same `(failing predicates, touched files,
  normalized error head)` fingerprint `Kazi.Memory.AttemptLedger.fingerprint/3`
  already defines -- repeated at or above `@repeat_threshold` times without
  ever changing the failing set. That is exactly ADR-0063's motivating
  example: "a predicate that wedged three different goals the same way is a
  landmine." Only fires on a non-`:converged` terminal outcome
  (`:stopped`/`:over_budget`) -- a converged run has nothing to harvest.

  No model runs here, ever (this is the ADR-0058 confabulation stance
  restated for permanent state): every candidate's `content` is a template
  filled from the fold's own fields. The ADR permits a bounded model PASS to
  draft phrasing later; origination stays detector-only regardless.

  ## Idempotent, never re-proposed

  Every candidate's `proposal_ref`/`fingerprint` is deterministic
  (derived from the SAME approach fingerprint), so harvesting the same facts
  twice (a resumed goal, a re-run over the same history) finds the existing
  row (`Kazi.ReadModel.propose_memory/1`) instead of duplicating it --
  whether that row is still `proposed` or has already been rejected.

  ## No inner-agent write path

  This module is called controller-side, from `Kazi.Runtime.run/2` after the
  loop reaches a terminal state -- never from `Kazi.Harness` or an action
  module, so the dispatched agent has no path to influence what gets
  proposed. Corpus files remain `[enforcement] read_only_paths` (ADR-0042)
  for the SAME reason during a run.
  """

  alias Kazi.Memory.{AttemptLedger, Promote}
  alias Kazi.ReadModel
  alias Kazi.ReadModel.Iteration

  # A dispatch approach repeated this many times with no change in its
  # failing set is a landmine candidate. Matches the ADR's own example
  # ("wedged three different goals" / "tried at iterations N, M") -- three
  # is already a strong deterministic signal, not a coincidence.
  @repeat_threshold 3

  @doc """
  Runs the harvest detector(s) for one terminated run and stores any
  candidates found as proposals. Best-effort: a detector or persistence
  failure is caught and logged, never raised -- harvesting must never alter
  a run's reported outcome. Returns the list of proposal rows that are new
  or already existed (empty when nothing fired or the read-model is
  unavailable).
  """
  @spec harvest(String.t() | nil, Kazi.Goal.id(), Kazi.Loop.result()) :: [
          ReadModel.ProposedMemory.t()
        ]
  def harvest(run_id, goal_ref, %{outcome: outcome} = _result) when outcome == :converged do
    _ = {run_id, goal_ref}
    []
  end

  def harvest(run_id, goal_ref, %{outcome: outcome} = _result)
      when outcome in [:stopped, :over_budget] do
    goal_ref
    |> ReadModel.list_iterations()
    |> dispatch_attempts()
    |> Enum.group_by(& &1.fingerprint)
    |> Enum.filter(fn {_fingerprint, attempts} -> length(attempts) >= @repeat_threshold end)
    |> Enum.map(&build_candidate(&1, goal_ref, run_id, outcome))
    |> Enum.map(&ReadModel.propose_memory/1)
    |> collect_ok()
  rescue
    _ -> []
  end

  def harvest(_run_id, _goal_ref, _result), do: []

  # ===========================================================================
  # The fold: one attempt per recorded `dispatch_agent` iteration, reusing
  # `AttemptLedger`'s own fingerprint definition so a landmine detected here
  # and an attempt rendered into the prompt (ADR-0061) can never disagree
  # about what counts as "the same approach".
  # ===========================================================================

  defp dispatch_attempts(iterations) do
    iterations
    |> Enum.filter(&(&1.action_kind == "dispatch_agent"))
    |> Enum.map(&build_attempt/1)
  end

  defp build_attempt(%Iteration{iteration_index: index, action_params: params}) do
    failing = params |> fetch([:failing, "failing"], []) |> Enum.map(&to_string/1) |> Enum.sort()
    touched = params |> fetch([:touched, "touched"], []) |> Enum.sort()
    evidence = params |> fetch([:evidence, "evidence"], %{})
    error_head = error_head(evidence, failing)

    %{
      iteration: index,
      failing: failing,
      touched: touched,
      error_head: error_head,
      fingerprint: AttemptLedger.fingerprint(MapSet.new(failing), MapSet.new(touched), error_head)
    }
  end

  defp fetch(map, keys, default) when is_map(map),
    do: Enum.find_value(keys, default, &Map.get(map, &1))

  defp fetch(_map, _keys, default), do: default

  defp error_head(_evidence, []), do: ""

  defp error_head(evidence, [first | _]) do
    key = Enum.find(Map.keys(evidence), fn k -> to_string(k) == first end)

    evidence
    |> Map.get(key)
    |> inspect(limit: 20, printable_limit: 200)
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 80)
  end

  # ===========================================================================
  # Candidate construction -- FACTS ONLY, template-filled, never model prose.
  # ===========================================================================

  defp build_candidate({fingerprint, attempts}, goal_ref, run_id, outcome) do
    sorted = Enum.sort_by(attempts, & &1.iteration)
    first = List.first(sorted)
    iterations = Enum.map(sorted, & &1.iteration)
    class = "landmine"

    content =
      "goal #{goal_ref}: predicate(s) #{Enum.join(first.failing, ", ")} were dispatched " <>
        "#{length(sorted)} times (iterations #{Enum.join(iterations, ", ")}) with the same " <>
        "approach (fingerprint #{fingerprint}) and never changed the failing set -- do not " <>
        "repeat this approach; evidence head: #{first.error_head}."

    %{
      proposal_ref: "mem-#{fingerprint}",
      fingerprint: fingerprint,
      class: class,
      content: content,
      goal_ref: to_string(goal_ref),
      run_id: run_id,
      target_doc: Promote.target_doc(class),
      status: "proposed",
      evidence: %{
        "iterations" => iterations,
        "failing" => first.failing,
        "touched" => first.touched,
        "error_head" => first.error_head,
        "outcome" => to_string(outcome)
      }
    }
  end

  defp collect_ok(results) do
    Enum.flat_map(results, fn
      {:ok, row} -> [row]
      {:error, _reason} -> []
    end)
  end
end
