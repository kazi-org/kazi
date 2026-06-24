defmodule Kazi.Pool.Gate do
  @moduledoc """
  The pre-merge VERIFICATION GATE decision (T20.2, ADR-0026 L1).

  ADR-0026 integrates kazi UNDER each `/apply --pool` session: before a pooled
  session rebase-merges its task's PR, it runs the task's predicates with
  `kazi run --json` and lands the PR ONLY when kazi reports convergence. This
  module is the thin, deterministic helper that makes the "block unless
  `converged`" decision a pure function of the run-result JSON, so the gate is
  testable in code rather than only described in prose.

  `decide/1` takes a DECODED `kazi apply --json` terminal result (the object
  documented in `docs/schemas/run-result.md`, schema_version 2; `kazi run --json`
  is the deprecated alias that emits the same object) and returns:

    * `:merge` — the run `converged`; the whole predicate vector held against the
      real world (including any live probe). The session may rebase-merge.
    * `{:block, reason}` — anything else. `reason` is a human-readable,
      copy-pasteable line a session reports on the PR / to the operator and does
      NOT merge:
        - `stuck`        → the same failing set persisted; ESCALATE (investigate).
        - `over_budget`  → a budget ceiling was hit; raise the budget + re-run or
          escalate.
        - `error`        → a pre-loop failure (vacuous goal, unknown harness); fix.
        - an unexpected `schema_version`, a missing/unknown `status`, or a
          non-object input → block (fail CLOSED — never merge on a result the
          gate cannot positively read as `converged`).

  The gate FAILS CLOSED: the only path to `:merge` is an explicit
  `status == "converged"` at the pinned `schema_version`. Every other shape
  blocks, so a malformed or unexpected result can never be mistaken for a pass.

  ## Why a pure decision

  The block-unless-converged rule is the load-bearing logic of the L1 gate. A
  pure `result_map -> :merge | {:block, reason}` function lets an ExUnit test
  assert it directly — a NON-converged fixture blocks with a clear reason, a
  converged one merges — instead of trusting prose. The session shells out to
  `kazi run --json`, decodes the one terminal object, and calls `decide/1`.

  See `docs/pool-verification-gate.md` for the full copy-pasteable procedure
  (acc → predicates → propose → approve → run → this decision).
  """

  # The result-schema contract version this gate is written against (ADR-0023
  # decision 2; bumped to 2 by ADR-0032/T27.3 with the apply/plan verb rename).
  # The gate pins it: a result at a DIFFERENT version blocks rather than being
  # read with stale field assumptions.
  @schema_version 2

  @typedoc "A decoded `kazi run --json` terminal result object (string-keyed)."
  @type result :: %{optional(String.t()) => term()}

  @typedoc """
  The gate decision: `:merge` to rebase-merge, or `{:block, reason}` to hold the
  merge and report `reason` (the session escalates rather than merging).
  """
  @type decision :: :merge | {:block, String.t()}

  @doc """
  Decides whether a pooled session may merge, from a decoded `kazi run --json`
  terminal result.

  Returns `:merge` ONLY when the result is an object at the pinned
  `schema_version` with `status == "converged"`. Every other case returns
  `{:block, reason}` with a copy-pasteable reason — the gate fails CLOSED.

  ## Examples

      iex> Kazi.Pool.Gate.decide(%{"schema_version" => 2, "status" => "converged"})
      :merge

      iex> Kazi.Pool.Gate.decide(%{"schema_version" => 2, "status" => "stuck", "reason" => "stuck"})
      {:block, "kazi reported status=stuck (next_action=investigate): the same predicate set failed across iterations — investigate the failing predicates; do NOT merge"}

      iex> Kazi.Pool.Gate.decide(%{"schema_version" => 2, "status" => "error", "error" => "goal is vacuous"})
      {:block, "kazi reported status=error (next_action=investigate): goal is vacuous — fix the goal/harness; do NOT merge"}

      iex> Kazi.Pool.Gate.decide(%{"schema_version" => 1, "status" => "converged"})
      {:block, "kazi run result schema_version is 1, gate expects 2 — refusing to read an unpinned result; do NOT merge"}
  """
  @spec decide(result()) :: decision()
  def decide(result) when is_map(result) do
    case Map.get(result, "schema_version") do
      @schema_version -> decide_on_status(result)
      other -> {:block, version_reason(other)}
    end
  end

  def decide(_other) do
    {:block,
     "kazi run result is not a JSON object — decode the single terminal " <>
       "run-result line, then re-check; do NOT merge"}
  end

  # The block-unless-converged core: only an explicit `converged` merges; every
  # other status (and any missing/unknown one) blocks with a copy-pasteable line.
  defp decide_on_status(result) do
    case Map.get(result, "status") do
      "converged" ->
        :merge

      "stuck" ->
        {:block, reason("stuck", "investigate", stuck_detail())}

      "over_budget" ->
        {:block, reason("over_budget", "raise_budget", over_budget_detail(result))}

      "error" ->
        {:block, reason("error", "investigate", error_detail(result))}

      nil ->
        {:block,
         "kazi run result has no \"status\" field — cannot confirm convergence; " <>
           "do NOT merge"}

      other when is_binary(other) ->
        {:block,
         "kazi run reported an unrecognized status=#{other} (expected one of " <>
           "converged / stuck / over_budget / error) — do NOT merge"}

      other ->
        {:block, "kazi run result \"status\" is not a string (#{inspect(other)}) — do NOT merge"}
    end
  end

  # Assemble the copy-pasteable block reason: the status, the orchestration hint
  # (next_action), the human detail, and the explicit "do NOT merge".
  defp reason(status, next_action, detail) do
    "kazi reported status=#{status} (next_action=#{next_action}): #{detail}; do NOT merge"
  end

  defp stuck_detail do
    "the same predicate set failed across iterations — investigate the failing predicates"
  end

  defp over_budget_detail(result) do
    case get_in(result, ["budget_spent", "exceeded"]) do
      dim when is_binary(dim) and dim != "" ->
        "budget dimension #{inspect(dim)} was exhausted — raise the budget and re-run, or escalate"

      _ ->
        "a budget ceiling was hit — raise the budget and re-run, or escalate"
    end
  end

  defp error_detail(result) do
    case Map.get(result, "error") do
      msg when is_binary(msg) and msg != "" -> "#{msg} — fix the goal/harness"
      _ -> "a pre-loop failure occurred — read the result's error and fix the goal/harness"
    end
  end

  defp version_reason(other) do
    "kazi run result schema_version is #{inspect(other)}, gate expects " <>
      "#{@schema_version} — refusing to read an unpinned result; do NOT merge"
  end
end
