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
          guard?: boolean()
        }

  @enforce_keys [:id, :kind]
  defstruct id: nil,
            kind: nil,
            description: nil,
            config: %{},
            guard?: false

  @doc """
  Builds a predicate.

  `id` and `kind` are required; `:config`, `:description`, and `:guard?` are
  optional opts.

  ## Examples

      iex> p = Kazi.Predicate.new(:unit, :tests, config: %{cmd: "mix test"})
      iex> {p.kind, p.config}
      {:tests, %{cmd: "mix test"}}

      iex> Kazi.Predicate.new(:live, :http_probe, guard?: false).guard?
      false
  """
  @spec new(id(), provider_kind(), keyword()) :: t()
  def new(id, kind, opts \\ []) when not is_nil(id) and is_atom(kind) do
    %__MODULE__{
      id: id,
      kind: kind,
      description: Keyword.get(opts, :description),
      config: Keyword.get(opts, :config, %{}),
      guard?: Keyword.get(opts, :guard?, false)
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
end
