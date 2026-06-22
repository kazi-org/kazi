defmodule Kazi.Retrieval.NoOp do
  @moduledoc """
  The default `Kazi.Retrieval` backend (T4.9a, ADR-0012): retrieval OFF.

  Returning `[]` is the *off state*, not a placeholder — it is the real default
  that makes ADR-0012's central guarantee hold: with no retriever injected or
  configured, `Kazi.Harness.ClaudeAdapter.build_prompt/3` appends no retrieval
  section and its output is byte-identical to the pre-retrieval path. The
  deterministic orientation pack (ADR-0010) and thin evidence (ADR-0009) remain the
  whole prompt. A real similarity backend (graphify embeddings) lands in T4.9b
  behind this same seam; until a goal opts in, the no-op is what runs.
  """

  @behaviour Kazi.Retrieval

  alias Kazi.Retrieval.Snippet

  @impl true
  @spec retrieve(
          [{Kazi.Predicate.id(), Kazi.PredicateResult.t()}],
          String.t(),
          keyword()
        ) :: [Snippet.t()]
  def retrieve(_failing, _workspace, _opts), do: []
end
