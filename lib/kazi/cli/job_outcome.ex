defmodule Kazi.CLI.JobOutcome do
  @moduledoc """
  The additive `job_outcome` field on `apply --json`'s terminal result (TKE.7,
  `docs/plans/E-KAZI-ENTRYPOINT.md` §1.3): kazi's own `status` vocabulary
  (`converged` / `stuck` / `over_budget` / `error` / `tampered`) does not line
  up 1:1 with a dispatcher's exit-code vocabulary (`done` / `blocked` /
  `checkpointed` / `refused`, e.g. hq's `CONTRACT.md`) — this module names that
  mapping ONCE so a dispatcher never has to invent and hand-maintain it itself.

  Computed the SAME principled way `next_action/1` (`Kazi.CLI`) already is: a
  pure function of already-rendered terminal-result fields, no new semantics
  invented ad hoc:

    * `status: "converged"` with nothing to land, or a successful landing
      (`integration.landed` absent or `true`) -> `:done`.
    * `status: "converged"` with `integration.landed: false` (a resumable
      PR/branch survives) -> `:checkpointed`.
    * `status: "stuck"` or `"over_budget"` with committed progress
      (`has_commits: true`) -> `:checkpointed`.
    * the same two statuses with zero committed progress -> `:blocked`.
    * `status: "error"` or `"tampered"` -> `:refused`.

  Pure: no I/O, no `Kazi.CLI` coupling — the caller extracts the handful of
  already-computed fields this needs and passes them in as a plain map, so
  this is unit-testable in complete isolation (mirrors `Kazi.Loop.CauseClass`
  / `Kazi.Economy.KPIs`).

  Deliberately closed over exactly the five statuses `docs/schemas/run-result.md`
  documents (`### status`) — an unrecognized status is a caller bug, not a
  value this module silently papers over, so `classify/1` has no catch-all
  clause and raises `FunctionClauseError` on anything else.

  `status: "error"` only ever arises from the SEPARATE pre-loop Error object
  (`run_error_json/3` in `Kazi.CLI`) — `Kazi.CLI`'s own `run_result_json/6`
  never produces it (its `status` is always one of `converged`/`stuck`/
  `over_budget`/`tampered`). This module still classifies `"error"` for a
  complete, principled mapping (the full vocabulary `next_action/1` and
  `docs/schemas/run-result.md` name), but today's wiring surfaces
  `job_outcome` only on the run-result shape, mirroring `single_node`'s own
  absence from the Error object.
  """

  @typedoc "kazi's terminal status string, as rendered on `apply --json`'s `status` field."
  @type status :: String.t()

  @typedoc "hq's exit-code vocabulary (`CONTRACT.md`)."
  @type outcome :: :done | :blocked | :checkpointed | :refused

  @typedoc """
  The plain-map input `classify/1` reads:

    * `:status` — one of `"converged"`, `"stuck"`, `"over_budget"`, `"error"`,
      `"tampered"` (the same strings `run_result_json/6`'s `status` field, and
      `run_error_json/3`'s hardcoded `"error"`, already render).
    * `:integration_landed` — the terminal result's `integration.landed`
      value (`true` / `false`), or `nil` when no `integration` object is
      present at all (an in-place run, or nothing was ever ahead of the
      base). Only consulted when `status` is `"converged"`.
    * `:has_commits` — whether the run left committed progress ahead of the
      declared base. Only consulted when `status` is `"stuck"` or
      `"over_budget"`.
  """
  @type inputs :: %{
          status: status(),
          integration_landed: boolean() | nil,
          has_commits: boolean()
        }

  @doc """
  Maps a terminal result's `status` (+ `integration.landed` / commits-ahead,
  where relevant) onto hq's exit-code vocabulary.

  ## Examples

      iex> Kazi.CLI.JobOutcome.classify(%{status: "converged", integration_landed: nil, has_commits: false})
      :done

      iex> Kazi.CLI.JobOutcome.classify(%{status: "converged", integration_landed: true, has_commits: false})
      :done

      iex> Kazi.CLI.JobOutcome.classify(%{status: "converged", integration_landed: false, has_commits: false})
      :checkpointed

      iex> Kazi.CLI.JobOutcome.classify(%{status: "stuck", integration_landed: nil, has_commits: true})
      :checkpointed

      iex> Kazi.CLI.JobOutcome.classify(%{status: "stuck", integration_landed: nil, has_commits: false})
      :blocked

      iex> Kazi.CLI.JobOutcome.classify(%{status: "over_budget", integration_landed: nil, has_commits: true})
      :checkpointed

      iex> Kazi.CLI.JobOutcome.classify(%{status: "over_budget", integration_landed: nil, has_commits: false})
      :blocked

      iex> Kazi.CLI.JobOutcome.classify(%{status: "error", integration_landed: nil, has_commits: false})
      :refused

      iex> Kazi.CLI.JobOutcome.classify(%{status: "tampered", integration_landed: nil, has_commits: false})
      :refused

  """
  @spec classify(inputs()) :: outcome()
  def classify(%{status: "converged", integration_landed: false}), do: :checkpointed
  def classify(%{status: "converged"}), do: :done

  def classify(%{status: status, has_commits: true}) when status in ["stuck", "over_budget"],
    do: :checkpointed

  def classify(%{status: status, has_commits: false}) when status in ["stuck", "over_budget"],
    do: :blocked

  def classify(%{status: status}) when status in ["error", "tampered"], do: :refused
end
