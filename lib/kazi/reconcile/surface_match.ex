defmodule Kazi.Reconcile.SurfaceMatch do
  @moduledoc """
  The shared **surface-matching primitive** used by every surface-coverage
  meta-predicate (ADR-0021, decision 3).

  Both coverage checks answer the same structural question — "is this scanned
  `Kazi.Reconcile.SurfaceElement` covered by >=1 token drawn from the intended
  set?" — and differ ONLY in where the tokens come from:

    * `Kazi.Reconcile.Coverage` (T13.5) — tokens from the intended **predicate**
      set (the dead-code / `A \\ I` half): a surface element with no covering
      predicate is dead code.
    * `Kazi.Reconcile.SpecCoverage` (T41.3) — tokens from the **Scenarios** of
      the product's `.feature` behavior specs (ADR-0050/ADR-0054): a surface
      element referenced by no Scenario is undocumented surface.

  Extracting the match here is what makes the two checks *literally* share one
  matching rule while staying independent: each derives its own tokens and calls
  the SAME `covered?/2`, so they can run over the same repo without interfering.

  The match is a deliberately simple, documented, *approximate* string rule — the
  surface scan itself is approximate (`docs/lore.md` L-0006), so a precise matcher
  would be false precision. A token *matches* an identifier when, after trimming,
  the two are equal or either contains the other as a substring (case-sensitive).
  Empty/blank tokens never match; `trim_tokens/1` drops them once, up front.
  """

  alias Kazi.Reconcile.SurfaceElement

  @doc """
  Whether any of `tokens` covers `element` (matches its `identifier`).

  Tokens should already be trimmed via `trim_tokens/1`.
  """
  @spec covered?(SurfaceElement.t(), [String.t()]) :: boolean()
  def covered?(%SurfaceElement{identifier: id}, tokens) do
    Enum.any?(tokens, &token_matches?(&1, id))
  end

  @doc """
  The primitive match: two non-blank strings match when equal or one contains the
  other as a substring (case-sensitive).

  ## Examples

      iex> Kazi.Reconcile.SurfaceMatch.token_matches?("/healthz", "GET /healthz")
      true

      iex> Kazi.Reconcile.SurfaceMatch.token_matches?("Calc.add", "Surface.Calc.add/2")
      true

      iex> Kazi.Reconcile.SurfaceMatch.token_matches?("Other", "Surface.Calc.add/2")
      false
  """
  @spec token_matches?(String.t(), String.t()) :: boolean()
  def token_matches?(token, identifier) do
    token == identifier or String.contains?(identifier, token) or
      String.contains?(token, identifier)
  end

  @doc """
  Normalizes a raw token list once, up front: keeps binaries, trims them, drops
  blanks, de-duplicates. Non-binary entries (e.g. a `nil` config value) are
  dropped, so callers can flat-map loosely-typed sources straight in.
  """
  @spec trim_tokens([term()]) :: [String.t()]
  def trim_tokens(tokens) do
    tokens
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Whether `element` is covered by the allow-list `patterns` (intentional
  un-covered surface, ADR-0021). A pattern is a plain identifier, a `"prefix*"`
  wildcard, or a `"prefix*suffix"` pattern.
  """
  @spec allowed?(SurfaceElement.t(), [String.t()]) :: boolean()
  def allowed?(%SurfaceElement{identifier: id}, patterns) do
    Enum.any?(patterns, &pattern_matches?(&1, id))
  end

  defp pattern_matches?(pattern, id) when is_binary(pattern) do
    case String.split(pattern, "*", parts: 2) do
      [^pattern] -> pattern == id
      [prefix, ""] -> String.starts_with?(id, prefix)
      [prefix, suffix] -> String.starts_with?(id, prefix) and String.ends_with?(id, suffix)
    end
  end

  defp pattern_matches?(_, _), do: false

  @doc "Sorts elements by `SurfaceElement.sort_key/1` for a deterministic report."
  @spec sort([SurfaceElement.t()]) :: [SurfaceElement.t()]
  def sort(elements), do: Enum.sort_by(elements, &SurfaceElement.sort_key/1)
end
