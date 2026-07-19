defmodule Kazi.Providers.VisualJudge.Model do
  @moduledoc """
  The injectable model seam for the `:visual_judge` provider (T68.8, #1522).

  The provider does NOT embed a concrete multimodal API client. It resolves this
  behaviour's implementation from application env
  (`Application.get_env(:kazi, :visual_judge_model, ...)`) and asks it to judge
  one `{screenshot, references, rubric}` request against a pinned model. That
  keeps the provider:

    * **hermetically testable** — a test injects a stub that returns a recorded
      verdict, so the provider's mapping is pinned WITHOUT a live API call;
    * **transport-agnostic** — the same provider drives whatever multimodal
      backend the deployment wires in, selected per-request by the sealed `model`
      id.

  A real API-backed implementation is deliberately out of hermetic scope (the
  same posture ADR-0081 takes for live capture): kazi ships the seam and the
  default `Kazi.Providers.VisualJudge.UnconfiguredModel`, which returns
  `{:error, :model_not_configured}` so a run that declares a `visual_judge`
  predicate without wiring a transport fails LOUD (`:error`), never green.

  ## The verdict is itemized, never a scalar

  The callback returns `{pass, failures}` — a boolean plus a list of
  `{criterion, observation}` items. This is intentional (ADR/issue #1522): a
  "beauty score" invites threshold-shopping and cannot converge, while itemized
  pass/fail turns "the judge failed" into an actionable critique the worker acts
  on next iteration. An implementation that runs an N-vote majority (`votes`)
  resolves it to one boolean and MAY surface the tally in `failures`/its own
  channel; the provider consumes the resolved verdict.
  """

  @typedoc """
  A judge request. `screenshot`/`references` are raw image BYTES (never workspace
  paths — the judge sees only pixels + the rubric, so a worker cannot prompt-inject
  it via source). `rubric` is the author's pass/fail checklist. `model` is the
  pinned model id (sealed in the goal-file). `votes` is the majority sample count.
  `temperature` is fixed at 0 for reproducibility.
  """
  @type request :: %{
          screenshot: binary(),
          references: [binary()],
          rubric: [String.t()],
          model: String.t(),
          votes: pos_integer(),
          temperature: number()
        }

  @typedoc """
  The structured verdict: `pass` plus the itemized `failures`, each naming the
  rubric `criterion` it violated and the `observation` (the actionable critique
  surfaced to the worker as the predicate's red detail).
  """
  @type verdict :: %{
          required(:pass) => boolean(),
          required(:failures) => [%{criterion: String.t(), observation: String.t()}]
        }

  @callback judge(request()) :: {:ok, verdict()} | {:error, term()}
end
