defmodule Kazi.Context.GraphSource do
  @moduledoc """
  The injectable orientation source seam (T4.2, ADR-0010): given a workspace and
  the terms named in the failing evidence, return a `Kazi.Context.Survey` of
  candidate files, symbols, and test sources.

  Abstracting the source behind a behaviour is what keeps `Kazi.Context` hermetic:
  the real default, `Kazi.Context.RepoMapSource`, detects `.code-review-graph` and
  shells out to the graph (or scans the filesystem); tests inject a pure double so
  there is **no network or live-MCP call** in the suite (ADR-0010 acceptance:
  hermetic). Per ADR-0010 the source is the "graph when present, else tree-sitter
  repo map" decision point.

  An implementation MUST be deterministic: the same workspace + terms must yield an
  equal survey, since the pack built from it is a cacheable, byte-identical prompt
  prefix (T4.3). `Kazi.Context` re-sorts everything anyway, but a source that
  returned different *content* per call would break the cache.
  """

  alias Kazi.Context.Survey

  @doc """
  Surveys `workspace` for orientation material relevant to `evidence_terms`
  (path/identifier tokens pulled from the failing predicates' evidence), returning
  a `Kazi.Context.Survey`. `opts` is the source's own init options (e.g. the
  injected file list of a test double, or the graph CLI path).
  """
  @callback survey(workspace :: String.t(), evidence_terms :: [String.t()], opts :: keyword()) ::
              Survey.t()
end
