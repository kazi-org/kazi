defmodule Kazi.Providers.Gherkin do
  @moduledoc """
  The `:gherkin` predicate provider (ADR-0071): reconciles a `.feature` file's
  Scenarios into per-scenario verdicts.

  A single goal-file `[[predicate]] provider = "gherkin"` entry is EXPANDED at
  goal-load (`Kazi.Goal.Loader`, via `Kazi.Reconcile.GherkinExpander`) into one
  real sub-predicate per Scenario — and, for a `Scenario Outline`, one per
  Examples row — each carrying `kind: :gherkin`. That load-time expansion
  preserves kazi's one-`[[predicate]]`-to-one-verdict invariant while giving
  `kazi status` per-scenario granularity (ADR-0071 decision 1). Every expanded
  sub-predicate points at the SHARED runner spec (`runner_cmd`/`runner_args`/
  `verdict_format`/`report_path`) copied from the parent entry.

  ## Evaluation is T62.2, not this task

  This module supplies the provider identity the loader binds and the runtime
  dispatches to, and it OWNS the provider's config-key atoms (see below). The
  cucumber-json / scenario_map verdict ingestion — running the shared runner
  once per feature, memoized, and reading each scenario's verdict from the
  parsed report by scenario identity — lands in T62.2. Until then `evaluate/2`
  returns an honest `:unknown` (ADR-0046): kazi never fabricates a verdict it
  did not observe, so an un-ingested scenario is `:unknown`, never a fake pass
  or a spurious fail.

  ## The provider owns its config-key atoms (ADR-0071 decision 6, #1112)

  The loader admits a predicate config key only if its atom already exists
  (`String.to_existing_atom/1`, its atom-exhaustion guard, `Loader.safe_config_key/1`)
  and interns a provider's keys by force-loading the provider module named by the
  predicate's `kind`. So this module names `feature`, `scenario`, `steps`,
  `verdict_format`, `runner_cmd`, `runner_args`, `report_path`, `row_key`, and
  `example` as literal atoms PURELY so `ensure_provider_loaded(:gherkin)` interns
  them at goal-load. Without this the released binary would reject a real
  `provider = "gherkin"` goal as "unknown config key" even though every test
  passed under `mix` (the #1112 / devlog 2026-07-15 trap: `mix` loads sibling
  modules that happen to name the same atoms; the release binary does not).
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  # The provider's own config keys, named as literal atoms so the loader interns
  # them when it force-loads this module (Loader.safe_config_key/1 relies on it).
  # `feature`/`scenario`/`steps` are ALSO in the loader's @gherkin_doc_keys, but
  # naming them here too keeps the ownership honest and self-contained.
  @gherkin_keys [
    :feature,
    :scenario,
    :steps,
    :verdict_format,
    :runner_cmd,
    :runner_args,
    :report_path,
    :row_key,
    :example
  ]

  @doc "The config-key atoms this provider owns (interned at goal-load)."
  @spec config_keys() :: [atom(), ...]
  def config_keys, do: @gherkin_keys

  @impl true
  def evaluate(%Predicate{kind: :gherkin} = predicate, _context) do
    # T62.1 ships only the load-time expansion; verdict ingestion is T62.2. An
    # un-ingested scenario is honestly :unknown (ADR-0046) — never a fabricated
    # pass. The evidence names the scenario and the runner so T62.2's ingestion,
    # and `kazi status` today, read legibly.
    config = predicate.config

    PredicateResult.unknown(%{
      reason: "gherkin verdict ingestion not yet available (T62.2)",
      feature: Map.get(config, :feature),
      scenario: Map.get(config, :scenario),
      runner_cmd: Map.get(config, :runner_cmd),
      runner_args: Map.get(config, :runner_args),
      verdict_format: Map.get(config, :verdict_format)
    })
  end
end
