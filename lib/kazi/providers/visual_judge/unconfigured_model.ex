defmodule Kazi.Providers.VisualJudge.UnconfiguredModel do
  @moduledoc """
  The default `Kazi.Providers.VisualJudge.Model` implementation (T68.8, #1522):
  no transport wired. Every call returns `{:error, :model_not_configured}`, which
  the provider maps to `:error` (infra, ADR-0002) — a `visual_judge` predicate on
  a deployment that never configured a multimodal transport fails LOUD, never
  green, and never dispatches a fixer against phantom failing work.

  Wire a real implementation via
  `config :kazi, :visual_judge_model, MyApp.VisualJudgeModel` (or the runtime
  `Application.put_env/3`); see `Kazi.Providers.VisualJudge.Model`.
  """

  @behaviour Kazi.Providers.VisualJudge.Model

  @impl true
  def judge(_request), do: {:error, :model_not_configured}
end
