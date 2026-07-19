defmodule Kazi.Harness.ProcessContract do
  @moduledoc """
  The controller-owned PROCESS CONTRACT section of the dispatch prompt (T44.4,
  ADR-0055 decision 4b).

  kazi owns a small, versioned block of UNIVERSAL working rules and appends it to
  every dispatch prompt (after the T19.1 orientation prefix, before the work
  item). It carries only harness-agnostic universals — so an `opencode`/`codex`/
  `gemini` agent that never sees a `CLAUDE.md` still works to the same bar — and
  repo-specific style stays in the repo's own `CLAUDE.md`/`AGENTS.md` (the
  contract deliberately does NOT double-carry it).

  ## Cacheable head — byte-stability is the whole point

  The section is rendered from the goal's `[conventions]` config ALONE — never
  from any per-iteration state (iteration count, timestamps, evidence, ordering).
  So it is IDENTICAL BYTES across every iteration of the same goal, which is what
  lets an LLM provider's prompt cache reuse it at near-zero marginal token cost.
  Any per-iteration variance here would defeat the caching this section exists for.

  ## Config (`[conventions]`, → `Goal.conventions`)

    * `process_contract` (default `true`) — `false` DISABLES the section entirely;
      the dispatch prompt then reverts byte-identically to the pre-E44 body.
    * `extra_rules` (default `[]`) — repo-specific lines appended VERBATIM after
      the universal rules (the only sanctioned way to extend the contract).
  """

  # The universal, harness-agnostic working rules (ADR-0055 decision 4b). Versioned
  # WITH kazi — updated by release, never per goal. Keep this list SMALL: the whole
  # section must stay a stable ~½–1 KB cacheable head.
  @rules [
    "Make small, conventional commits, each scoped to a single directory.",
    "Commit as you go on the goal branch — never leave converged work uncommitted.",
    "No stubs, mocks, fakes, or hardcoded returns in production code paths.",
    "Grep docs/lore.md for the area you're about to change before debugging it, and apply any matching rule.",
    "Under parallelism, derive migration/sequence numbers from origin — never from a local max that races a sibling.",
    "Wrap every network call (git/gh push/pull/fetch) in bounded exponential-backoff retry.",
    "Prefer a code graph's structural tools over grep/read when the repo has one."
  ]

  @header "## Process contract (kazi-owned, stable across iterations)"

  @doc """
  Renders the process-contract section for a goal's `conventions`, or `nil` when
  `process_contract` is disabled (so the caller appends nothing and the prompt is
  byte-identical to the pre-E44 body).

  Depends ONLY on `conventions` — no per-iteration input — so two calls with the
  same config always return the same bytes.
  """
  @spec section(Kazi.Goal.conventions() | nil) :: String.t() | nil
  def section(%{process_contract: false}), do: nil

  def section(conventions) when is_map(conventions) do
    extra = extra_rules(conventions)
    lines = @rules ++ extra

    @header <> "\n\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
  end

  def section(nil), do: section(Kazi.Goal.default_conventions())

  # Keep only well-formed non-empty string rules, verbatim and in order. A
  # non-list / non-string entry is dropped rather than crashing the dispatch.
  defp extra_rules(%{extra_rules: rules}) when is_list(rules) do
    Enum.filter(rules, &(is_binary(&1) and &1 != ""))
  end

  defp extra_rules(_conventions), do: []
end
