defmodule Kazi.PredicateProvider do
  @moduledoc """
  The contract a predicate provider implements: evaluate one `Kazi.Predicate`
  against a context and return a `Kazi.PredicateResult` (ADR-0002).

  Providers are the *pluggable* edge of the controller. A new goal type is a new
  provider, not a core change (ADR-0002): the controller dispatches a predicate
  to the provider registered for its `kind` and trusts the `{status, evidence}`
  it returns — truth about *that* predicate lives in the provider's objective
  check, never in an agent's opinion.

  This module is a **behaviour only** — `@callback` specs, no concrete
  implementation (zero-stub policy; concrete providers are later tasks). Slice 0
  implementations:

    * `:tests` — the test-runner provider (T0.5): runs a configurable command in
      the target workspace and maps exit/output to a `PredicateResult`.
    * `:http_probe` — the live probe provider (T0.5b): requests a URL and asserts
      status/body.

  Later: `:prod_logs` (T1.6), `:browser` (T2.2), `:coverage`, `:custom_script`.

  ## Contract requirements (ADR-0002)

    * Evidence must be rich enough to (a) prove the status and (b) seed a fixer
      agent's context.
    * A provider must distinguish a genuine `:fail` from an `:error` (it could not
      run) — see `Kazi.PredicateResult`. Returning `:fail` for an infra problem
      would dispatch an agent against the wrong thing.
    * Providers should support re-run / quarantine so a flaky result does not
      poison the loop (concept §5); the re-run policy itself lands in Slice 1
      (T1.3), but providers must not assume a single evaluation is authoritative.

  ## Implementing

      defmodule MyApp.TestRunnerProvider do
        @behaviour Kazi.PredicateProvider

        @impl true
        def evaluate(%Kazi.Predicate{kind: :tests} = predicate, context) do
          # ... run the command in context.workspace ...
          Kazi.PredicateResult.pass(%{exit: 0, output: "..."})
        end
      end
  """

  @typedoc """
  Evaluation context threaded from the controller to the provider: the target
  workspace path, the goal scope, and any provider-relevant state. A map so the
  contract does not couple providers to the loop's internal state shape.
  """
  @type context :: map()

  @doc """
  Evaluates `predicate` against `context` and returns its result.

  Must return a `Kazi.PredicateResult` — never raise for an ordinary failing
  predicate (that is a `:fail`) and never raise for an inability to evaluate
  (that is an `:error`). The controller, not the provider, decides what a result
  means for convergence.
  """
  @callback evaluate(predicate :: Kazi.Predicate.t(), context :: context()) ::
              Kazi.PredicateResult.t()
end
