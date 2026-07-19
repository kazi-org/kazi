defmodule Kazi.Capture do
  @moduledoc """
  A **capture recipe** — a named, controller-executed command that produces a
  visual (or other binary) artifact a predicate can consume as evidence
  (ADR-0081, #1521).

  UI goals are gamed by presence: a text/id grep cannot tell "renders" from "the
  id was pinned onto a stock component". A screenshot fixes that only if the
  *controller* produces it — a screenshot the converging worker produces is a
  claim, not evidence (a cached build can lie). A capture recipe is therefore a
  command CONTRACT the controller runs each observe pass, in the run's workspace,
  writing the artifact into the run-keyed evidence store (`Kazi.Sink.Captures`)
  that lives OUTSIDE the workspace the worker edits.

  This module is only the authored `[[capture]]` config struct, parsed from the
  goal-file and carried on `Kazi.Goal.captures`. Execution + the evidence store
  live in `Kazi.Sink.Captures`; the run wiring lives in `Kazi.Runtime` /
  `Kazi.Loop`.

  ## Fields

    * `name` — required; the reference key a predicate uses (`input =
      "capture:<name>"` or `capture = "<name>"`). Unique within a goal.
    * `launch_cmd` / `launch_args` — required command that produces the artifact.
      The injectable `Kazi.Providers.CommandRunner` seam, so a real capture is a
      Playwright script / `xcrun simctl` / headless-render CLI and tests stub it.
    * `reset_cmd` / `reset_args` — optional command run FIRST for a fresh
      environment (e.g. erase a simulator so a cached install cannot answer for
      current code). Absent = no reset.
    * `output` — required; the artifact FILENAME the recipe writes. The controller
      resolves it into the evidence store and passes the absolute destination to
      the recipe, so the recipe writes into controller-owned space, never the
      workspace.
    * `post_launch_wait_ms` — optional settle time after launch before the artifact
      is read (default 0).
    * `timeout_ms` — optional hard deadline for each command (default 60_000).
  """

  @type t :: %__MODULE__{
          name: String.t(),
          launch_cmd: String.t(),
          launch_args: [String.t()],
          reset_cmd: String.t() | nil,
          reset_args: [String.t()],
          output: String.t(),
          post_launch_wait_ms: non_neg_integer(),
          timeout_ms: pos_integer()
        }

  @enforce_keys [:name, :launch_cmd, :output]
  defstruct name: nil,
            launch_cmd: nil,
            launch_args: [],
            reset_cmd: nil,
            reset_args: [],
            output: nil,
            post_launch_wait_ms: 0,
            timeout_ms: 60_000

  @default_timeout_ms 60_000

  @doc """
  Builds a `%Kazi.Capture{}` from a keyword/opts shape (the loader's parsed
  block). Requires `:name`, `:launch_cmd`, `:output`; the rest default.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      launch_cmd: Keyword.fetch!(opts, :launch_cmd),
      launch_args: Keyword.get(opts, :launch_args, []),
      reset_cmd: Keyword.get(opts, :reset_cmd),
      reset_args: Keyword.get(opts, :reset_args, []),
      output: Keyword.fetch!(opts, :output),
      post_launch_wait_ms: Keyword.get(opts, :post_launch_wait_ms, 0),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }
  end
end
