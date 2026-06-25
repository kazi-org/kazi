defmodule Kazi.ContextStore.Labels do
  @moduledoc """
  Stable, SHA-scoped source labels for the context store (T35.1, ADR-0045 §4).

  A *source label* is the key under which a text artifact is indexed in the store
  (`Kazi.ContextStore`). Labels are the invalidation contract: they are built
  deterministically from the artifact's coordinates — git SHA, goal id, iteration,
  predicate id — so that

    * the **same** coordinates always produce the **same** label (an unchanged
      artifact re-indexes in place rather than accumulating duplicates), and
    * a **changed** coordinate (a new git SHA after an edit, the next iteration,
      another predicate) produces a **different** label, so stale content keyed to
      the old SHA falls out of the working set cleanly (ADR-0045 "Risk — stale
      context": git SHA in the label, invalidate changed files each iteration).

  These helpers are pure string builders — no I/O, no store dependency — so they are
  usable by both the outer controller (which indexes authoritative artifacts) and by
  callers assembling a query, and they are trivially deterministic.

  The label shapes (ADR-0045 §4):

      kazi:workspace:<git_sha>:docs:<path>
      kazi:goal:<goal_id>:predicate:<predicate_id>:rationale
      kazi:run:<goal_id>:iter:<n>:test-log
      kazi:run:<goal_id>:iter:<n>:harness-stderr
      kazi:run:<goal_id>:stuck:failure-cluster
  """

  @prefix "kazi"

  @typedoc "A built source label — the key an artifact is indexed under."
  @type label :: String.t()

  @doc """
  Label for a workspace document, scoped to the git SHA so an edited file
  (new SHA) keys to a new label and the old content invalidates.

  ## Examples

      iex> Kazi.ContextStore.Labels.workspace_doc("abc123", "docs/concept.md")
      "kazi:workspace:abc123:docs:docs/concept.md"

      iex> Kazi.ContextStore.Labels.workspace_doc("abc123", "x") ==
      ...>   Kazi.ContextStore.Labels.workspace_doc("def456", "x")
      false
  """
  @spec workspace_doc(String.t(), String.t()) :: label()
  def workspace_doc(git_sha, path) when is_binary(git_sha) and is_binary(path) do
    join(["workspace", git_sha, "docs", path])
  end

  @doc """
  Label for a predicate's rationale, scoped to the goal and predicate ids.

  ## Examples

      iex> Kazi.ContextStore.Labels.predicate_rationale("g1", "tests_pass")
      "kazi:goal:g1:predicate:tests_pass:rationale"
  """
  @spec predicate_rationale(String.t(), String.t()) :: label()
  def predicate_rationale(goal_id, predicate_id)
      when is_binary(goal_id) and is_binary(predicate_id) do
    join(["goal", goal_id, "predicate", predicate_id, "rationale"])
  end

  @doc """
  Label for an iteration's captured test log, scoped to goal and iteration number.

  ## Examples

      iex> Kazi.ContextStore.Labels.run_test_log("g1", 3)
      "kazi:run:g1:iter:3:test-log"
  """
  @spec run_test_log(String.t(), non_neg_integer()) :: label()
  def run_test_log(goal_id, iter) when is_binary(goal_id) and is_integer(iter) and iter >= 0 do
    join(["run", goal_id, "iter", iter, "test-log"])
  end

  @doc """
  Label for an iteration's captured harness stderr, scoped to goal and iteration.

  ## Examples

      iex> Kazi.ContextStore.Labels.run_harness_stderr("g1", 3)
      "kazi:run:g1:iter:3:harness-stderr"
  """
  @spec run_harness_stderr(String.t(), non_neg_integer()) :: label()
  def run_harness_stderr(goal_id, iter)
      when is_binary(goal_id) and is_integer(iter) and iter >= 0 do
    join(["run", goal_id, "iter", iter, "harness-stderr"])
  end

  @doc """
  Label for a run's stuck-state failure cluster — the compact bundle assembled for
  ADR-0035 escalation replay (ADR-0045 §5). Scoped to the goal id.

  ## Examples

      iex> Kazi.ContextStore.Labels.stuck_failure_cluster("g1")
      "kazi:run:g1:stuck:failure-cluster"
  """
  @spec stuck_failure_cluster(String.t()) :: label()
  def stuck_failure_cluster(goal_id) when is_binary(goal_id) do
    join(["run", goal_id, "stuck", "failure-cluster"])
  end

  @spec join([String.t() | non_neg_integer()]) :: label()
  defp join(parts) do
    [@prefix | parts]
    |> Enum.map_join(":", &to_string/1)
  end
end
