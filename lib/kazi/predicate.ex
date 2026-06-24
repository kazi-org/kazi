defmodule Kazi.Predicate do
  @moduledoc """
  A single machine-checkable predicate — the atomic unit of a goal's desired
  state (ADR-0002).

  A predicate names a *pluggable provider kind* (e.g. `:tests`, `:http_probe`,
  `:coverage`, `:prod_logs`) and carries the `config` that provider needs to
  evaluate it. The controller — never the agent — evaluates predicates and
  decides whether a goal is met; a `Predicate` is purely the declaration of
  *what* to check, not *how* to check it. The matching `Kazi.PredicateProvider`
  turns a predicate plus a context into a `Kazi.PredicateResult`.

  Predicates may be ordinary (the goal is met iff all of them pass) or *guard*
  predicates — invariants that must never regress (test-count must not drop,
  coverage must not fall below baseline). Guards prevent the agent from "passing"
  a predicate by deleting the check (ADR-0002, concept §4). `guard?` marks a
  predicate as a guard; the loop enforces guards as invariants rather than goals
  to reach.

  ## Acceptance predicates (creation mode, T2.1, concept §10 Slice 2)

  In *creation mode* a goal is authored as **acceptance criteria**: predicates
  describing desired NEW behavior that FAIL at t0 (the feature does not exist
  yet) and pass once kazi builds it. An acceptance predicate is an ordinary
  predicate — the same `:fail → work-list → dispatch → re-observe` convergence
  machinery applies; nothing about evaluation changes. `acceptance?` is purely a
  declarative marker recording the author's intent ("this is expected to fail at
  t0"), so creation goals are self-describing and tooling (e.g. the vacuous-goal
  guard, T2.3) can reason about author intent. It does **not** alter how the loop
  evaluates the predicate. A guard predicate is never an acceptance predicate
  (guards are invariants, not goals to reach); the two flags are independent but
  the loader rejects a predicate marked both.
  """

  @typedoc """
  The provider kind a predicate dispatches to. This is the registry key the
  controller uses to find the `Kazi.PredicateProvider` implementation. Slice 0
  ships `:tests` (T0.5) and `:http_probe` (T0.5b); later slices add `:coverage`,
  `:prod_logs` (T1.6), `:browser` (T2.2), and `:custom_script` (ADR-0002).
  """
  @type provider_kind :: atom()

  @typedoc """
  Stable identifier for a predicate within a goal. Used to correlate results
  across iterations (so a green→red transition is detectable as a regression —
  concept §5) and to key the `Kazi.PredicateVector`.
  """
  @type id :: String.t() | atom()

  @typedoc "Free-form configuration handed verbatim to the provider."
  @type config :: map()

  @type t :: %__MODULE__{
          id: id(),
          kind: provider_kind(),
          description: String.t() | nil,
          config: config(),
          guard?: boolean(),
          acceptance?: boolean(),
          group: String.t() | nil
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            description: nil,
            config: %{},
            guard?: false,
            acceptance?: false,
            # T12.2 group taxonomy (ADR-0020): an optional declared group id this
            # predicate belongs to — a normalized slug referencing the goal's
            # `[[group]]` taxonomy, NOT a free-text path. Default `nil` (ungrouped;
            # current behavior, fully backward-compatible). The loader validates
            # that a non-nil group is a DECLARED id (the typo/drift guard); this
            # field is appended additively so the existing field order is untouched.
            group: nil

  @doc """
  Builds a predicate.

  `id` and `kind` are required; `:config`, `:description`, `:guard?`,
  `:acceptance?`, and `:group` are optional opts. `:acceptance?` marks the
  predicate as an acceptance criterion expected to fail at t0 (creation mode,
  T2.1); it is a declarative marker only and does not change evaluation.
  `:group` (default `nil`) is the declared group id this predicate belongs to
  (T12.2, ADR-0020); the loader validates that a non-nil group references a
  declared `[[group]]` id.

  ## Examples

      iex> p = Kazi.Predicate.new(:unit, :tests, config: %{cmd: "mix test"})
      iex> {p.kind, p.config}
      {:tests, %{cmd: "mix test"}}

      iex> Kazi.Predicate.new(:live, :http_probe, guard?: false).guard?
      false

      iex> Kazi.Predicate.new(:widgets, :http_probe, acceptance?: true).acceptance?
      true

      iex> Kazi.Predicate.new(:signup, :browser, group: "identity-access").group
      "identity-access"
  """
  @spec new(id(), provider_kind(), keyword()) :: t()
  def new(id, kind, opts \\ []) when not is_nil(id) and is_atom(kind) do
    %__MODULE__{
      id: id,
      kind: kind,
      description: Keyword.get(opts, :description),
      config: Keyword.get(opts, :config, %{}),
      guard?: Keyword.get(opts, :guard?, false),
      acceptance?: Keyword.get(opts, :acceptance?, false),
      group: Keyword.get(opts, :group)
    }
  end

  @doc """
  Returns true if the predicate is a guard (an invariant that must not regress),
  rather than a goal to reach.

  ## Examples

      iex> Kazi.Predicate.guard?(Kazi.Predicate.new(:cov, :coverage, guard?: true))
      true
  """
  @spec guard?(t()) :: boolean()
  def guard?(%__MODULE__{guard?: guard?}), do: guard?

  @doc """
  Returns true if the predicate is an acceptance criterion — desired NEW
  behavior expected to fail at t0 and pass once kazi builds the feature
  (creation mode, T2.1, concept §10 Slice 2).

  ## Examples

      iex> Kazi.Predicate.acceptance?(Kazi.Predicate.new(:widgets, :http_probe, acceptance?: true))
      true

      iex> Kazi.Predicate.acceptance?(Kazi.Predicate.new(:unit, :tests))
      false
  """
  @spec acceptance?(t()) :: boolean()
  def acceptance?(%__MODULE__{acceptance?: acceptance?}), do: acceptance?
end
