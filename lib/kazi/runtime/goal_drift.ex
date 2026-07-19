defmodule Kazi.Runtime.GoalDrift do
  @moduledoc """
  Detects a goal's on-disk bar moving out from under a running convergence loop
  (goal-drift-guard-1415).

  `Kazi.Runtime.run/2` loads a goal-file **once**, at t0, into an in-memory
  `%Kazi.Goal{}` — every convergence check for the rest of the run reads that
  same struct; the loop never re-parses the source path. So editing the
  goal-file on disk mid-run already has **zero** effect on what "converged"
  means: the ORIGINAL bar always wins, by construction. What was missing was
  *detection* — an operator had no way to know the file underneath a run had
  been touched short of eyeballing `git diff` themselves, so a run could report
  `converged` against a bar that no longer matches the file on disk with no
  signal that anything moved.

  `snapshot/1` fingerprints a goal's predicate bar (id + kind + config + guard
  flag, per predicate) the moment it is loaded — the t0 snapshot. `detect/2`
  re-loads the SAME source at any later point (e.g. once the run terminates) and
  reports whether the on-disk bar has drifted from that snapshot: a predicate
  added, removed, or reconfigured. It never mutates convergence — it is purely
  observational, surfaced as the run result's `goal_drifted` field (see
  `docs/schemas/run-result.md`) so an operator is told the ground moved instead
  of silently trusting a result whose backing file no longer matches what was
  reported.
  """

  alias Kazi.{Goal, Predicate}

  @typedoc "The t0 fingerprint: predicate id => a stable hash of its bar-defining fields."
  @type snapshot :: %{Predicate.id() => binary()}

  @typedoc "What drifted: predicate ids added/removed since t0, and ids whose config changed."
  @type diff :: %{added: [Predicate.id()], removed: [Predicate.id()], changed: [Predicate.id()]}

  @doc """
  Fingerprints `goal`'s predicate bar — the t0 snapshot `detect/2` later compares
  against. Only the fields that define what "pass" means (`kind`, `config`,
  `guard?`) are hashed; `description` is prose and does not change the bar.
  """
  @spec snapshot(Goal.t()) :: snapshot()
  def snapshot(%Goal{predicates: predicates}) do
    Map.new(predicates, fn %Predicate{id: id} = predicate -> {id, fingerprint(predicate)} end)
  end

  @doc """
  Compares a t0 `snapshot/1` against the goal file CURRENTLY on disk at
  `source`, and returns `{:drifted, diff}` when it no longer matches, or
  `:unchanged` otherwise.

  Best-effort observability only: a `source` that is not a regular file, or one
  that no longer parses as a loadable goal-file (e.g. a `prop-...` proposal
  ref, or a file mid-edit), reports `:unchanged` rather than raising — drift
  detection can never become a new way for a run to fail.
  """
  @spec detect(snapshot(), String.t() | nil) :: :unchanged | {:drifted, diff()}
  def detect(snapshot, source) when is_binary(source) do
    with true <- File.regular?(source),
         {:ok, %Goal{} = current} <- Goal.Loader.load(source) do
      diff(snapshot, snapshot(current))
    else
      _ -> :unchanged
    end
  end

  def detect(_snapshot, _source), do: :unchanged

  @spec diff(snapshot(), snapshot()) :: :unchanged | {:drifted, diff()}
  defp diff(original, current) do
    original_ids = MapSet.new(Map.keys(original))
    current_ids = MapSet.new(Map.keys(current))

    added = current_ids |> MapSet.difference(original_ids) |> Enum.sort_by(&to_string/1)
    removed = original_ids |> MapSet.difference(current_ids) |> Enum.sort_by(&to_string/1)

    changed =
      original_ids
      |> MapSet.intersection(current_ids)
      |> Enum.filter(fn id -> Map.fetch!(original, id) != Map.fetch!(current, id) end)
      |> Enum.sort_by(&to_string/1)

    if added == [] and removed == [] and changed == [] do
      :unchanged
    else
      {:drifted, %{added: added, removed: removed, changed: changed}}
    end
  end

  defp fingerprint(%Predicate{kind: kind, config: config, guard?: guard?}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({kind, config, guard?}))
    |> Base.encode16(case: :lower)
  end
end
