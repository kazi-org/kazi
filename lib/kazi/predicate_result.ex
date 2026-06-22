defmodule Kazi.PredicateResult do
  @moduledoc """
  The outcome of evaluating one `Kazi.Predicate`: a `{status, evidence}` pair
  (ADR-0002).

  ADR-0002 defines a provider as returning `{pass | fail, evidence}`. This struct
  widens `status` to also cover the two states a real controller must
  distinguish from a genuine `fail`:

    * `:error`   — the provider itself could not run (binary missing, network
      down, malformed config). This is *not* failing work for the agent to fix;
      conflating it with `:fail` would dispatch an agent against an infra
      problem.
    * `:unknown` — not yet evaluated, or deliberately not evaluated this
      iteration (e.g. quarantined as flaky — concept §5). Carries no claim about
      the predicate.

  Only `:pass` counts toward convergence; `:fail` is real work; `:error` and
  `:unknown` are neither pass nor actionable failing work. The controller — not
  the agent — interprets these (concept §5).

  `evidence` is the *proof*: enough structured data to (a) justify the status and
  (b) seed a fixer agent's context (ADR-0002 consequences). It is provider-shaped
  (exit code + output for `:tests`; HTTP status + body for `:http_probe`) and
  carried as a map.
  """

  @typedoc """
  The evaluation status.

    * `:pass`    — the predicate holds; counts toward convergence.
    * `:fail`    — the predicate does not hold; this is the work-list.
    * `:error`   — the provider could not evaluate (infra/config problem).
    * `:unknown` — not (yet) evaluated; carries no claim.
  """
  @type status :: :pass | :fail | :error | :unknown

  @typedoc """
  Structured proof for the status, shaped by the provider. Examples: `%{exit:
  0, output: "...", duration_ms: 1200}` for a test run; `%{http_status: 200,
  body: "...", url: "..."}` for an http probe.
  """
  @type evidence :: map()

  @type t :: %__MODULE__{
          status: status(),
          evidence: evidence()
        }

  @enforce_keys [:status]
  defstruct status: nil, evidence: %{}

  @valid_statuses [:pass, :fail, :error, :unknown]

  @doc "The list of valid statuses, in convergence-relevance order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @valid_statuses

  @doc """
  Builds a result with the given `status` and optional `evidence`.

  `status` must be one of #{inspect(@valid_statuses)}; any other value raises
  `FunctionClauseError` (the guard rejects it).

  ## Examples

      iex> Kazi.PredicateResult.new(:pass, %{exit: 0}).status
      :pass

      iex> Kazi.PredicateResult.new(:fail).evidence
      %{}
  """
  @spec new(status(), evidence()) :: t()
  def new(status, evidence \\ %{}) when status in @valid_statuses and is_map(evidence) do
    %__MODULE__{status: status, evidence: evidence}
  end

  @doc "Convenience constructor for a passing result."
  @spec pass(evidence()) :: t()
  def pass(evidence \\ %{}), do: new(:pass, evidence)

  @doc "Convenience constructor for a failing result."
  @spec fail(evidence()) :: t()
  def fail(evidence \\ %{}), do: new(:fail, evidence)

  @doc "Convenience constructor for a provider-error result."
  @spec error(evidence()) :: t()
  def error(evidence \\ %{}), do: new(:error, evidence)

  @doc "Convenience constructor for an unknown/unevaluated result."
  @spec unknown(evidence()) :: t()
  def unknown(evidence \\ %{}), do: new(:unknown, evidence)

  @doc """
  Returns true only when the status is `:pass`. Used to decide whether a single
  predicate contributes to convergence.

  ## Examples

      iex> Kazi.PredicateResult.passed?(Kazi.PredicateResult.pass())
      true

      iex> Kazi.PredicateResult.passed?(Kazi.PredicateResult.error())
      false
  """
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{status: :pass}), do: true
  def passed?(%__MODULE__{}), do: false
end
