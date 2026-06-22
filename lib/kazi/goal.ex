defmodule Kazi.Goal do
  @moduledoc """
  A goal: declared desired state as a set of machine-checkable predicates
  (ADR-0002, concept §4).

  A goal is a *declarative document*. Its acceptance is the **conjunction of all
  its predicates** — "done" is `∀ p ∈ predicates: eval(p) = true`, decided by the
  controller with stored evidence, never by the agent's self-report (concept §1).

  A goal carries:

    * `mode` — `:repair` (default) or `:create`. In *repair* mode the predicates
      describe existing behavior that has regressed; in *create* mode (Slice 2,
      T2.1, concept §10) they are **acceptance criteria** for NEW behavior,
      authored to fail at t0 and pass once kazi builds the feature. The mode does
      not change the convergence machinery — failing predicates are the work-list
      either way — it records the author's intent so a create goal is
      self-describing and tooling (the vacuous-goal guard T2.3) can reason about
      it.
    * `predicates` — the desired-state predicates (`Kazi.Predicate`); the goal is
      met iff every one evaluates `:pass`. In create mode these are the acceptance
      criteria.
    * `guards` — guard predicates: invariants that must never regress (e.g.
      test-count must not drop, coverage must not fall below baseline). Guards are
      `Kazi.Predicate`s flagged `guard?: true`; they are enforced as invariants,
      not goals to reach (ADR-0002).
    * `budget` — the hard token / wall-clock / iteration ceiling
      (`Kazi.Budget`).
    * `scope` — the repo and paths agents may touch (`Kazi.Scope`).

  In Slice 0 a goal is loaded from a TOML goal-file (T0.4); this struct is the
  in-memory shape every later component (loader, loop T0.7, actions, read-model
  T0.9) builds against.
  """

  alias Kazi.{Budget, Predicate, Scope}

  @typedoc "Stable identifier for a goal."
  @type id :: String.t() | atom()

  @typedoc """
  How the goal's predicates are intended. `:repair` (default) — predicates
  describe existing behavior that has regressed. `:create` — predicates are
  acceptance criteria for NEW behavior, authored to fail at t0 (T2.1).
  """
  @type mode :: :repair | :create

  @type t :: %__MODULE__{
          id: id(),
          name: String.t() | nil,
          mode: mode(),
          predicates: [Predicate.t()],
          guards: [Predicate.t()],
          budget: Budget.t(),
          scope: Scope.t(),
          metadata: map()
        }

  @enforce_keys [:id]
  defstruct id: nil,
            name: nil,
            mode: :repair,
            predicates: [],
            guards: [],
            budget: %Budget{},
            scope: %Scope{},
            metadata: %{}

  @doc """
  Builds a goal.

  `id` is required. Optional opts: `:name`, `:mode`, `:predicates`, `:guards`,
  `:budget`, `:scope`, `:metadata`. `:mode` is `:repair` (default) or `:create`
  (creation mode — predicates are acceptance criteria, T2.1). `:budget` and
  `:scope` accept either a struct or a keyword list (forwarded to
  `Kazi.Budget.new/1` / `Kazi.Scope.new/1`).

  ## Examples

      iex> g = Kazi.Goal.new("ship-it",
      ...>   predicates: [Kazi.Predicate.new(:unit, :tests)],
      ...>   budget: [max_iterations: 5])
      iex> {g.id, g.mode, length(g.predicates), g.budget.max_iterations}
      {"ship-it", :repair, 1, 5}

      iex> Kazi.Goal.new("build-widgets", mode: :create).mode
      :create
  """
  @spec new(id(), keyword()) :: t()
  def new(id, opts \\ []) when not is_nil(id) do
    %__MODULE__{
      id: id,
      name: Keyword.get(opts, :name),
      mode: Keyword.get(opts, :mode, :repair),
      predicates: Keyword.get(opts, :predicates, []),
      guards: Keyword.get(opts, :guards, []),
      budget: opts |> Keyword.get(:budget, %Budget{}) |> to_budget(),
      scope: opts |> Keyword.get(:scope, %Scope{}) |> to_scope(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Returns all predicates the controller observes each iteration — the goal's
  `predicates` followed by its `guards`. Both are evaluated every observation;
  the distinction is in how the loop *interprets* a failure (a failing predicate
  is work; a failing guard is a blocked/gamed state).

  ## Examples

      iex> g = Kazi.Goal.new("g",
      ...>   predicates: [Kazi.Predicate.new(:unit, :tests)],
      ...>   guards: [Kazi.Predicate.new(:cov, :coverage, guard?: true)])
      iex> g |> Kazi.Goal.all_predicates() |> Enum.map(& &1.id)
      [:unit, :cov]
  """
  @spec all_predicates(t()) :: [Predicate.t()]
  def all_predicates(%__MODULE__{predicates: predicates, guards: guards}) do
    predicates ++ guards
  end

  @doc """
  Returns true if the goal is in creation mode — its predicates are acceptance
  criteria for new behavior, authored to fail at t0 (T2.1, concept §10 Slice 2).

  ## Examples

      iex> Kazi.Goal.create?(Kazi.Goal.new("g", mode: :create))
      true

      iex> Kazi.Goal.create?(Kazi.Goal.new("g"))
      false
  """
  @spec create?(t()) :: boolean()
  def create?(%__MODULE__{mode: :create}), do: true
  def create?(%__MODULE__{}), do: false

  @doc """
  Returns the goal's acceptance predicates — the ordinary (non-guard) predicates
  marked `acceptance?: true`. In a create-mode goal these are the failing-at-t0
  criteria the loop drives the agent to satisfy (T2.1).

  ## Examples

      iex> g = Kazi.Goal.new("g", mode: :create,
      ...>   predicates: [Kazi.Predicate.new(:widgets, :http_probe, acceptance?: true),
      ...>                Kazi.Predicate.new(:health, :http_probe)])
      iex> g |> Kazi.Goal.acceptance_predicates() |> Enum.map(& &1.id)
      [:widgets]
  """
  @spec acceptance_predicates(t()) :: [Predicate.t()]
  def acceptance_predicates(%__MODULE__{predicates: predicates}) do
    Enum.filter(predicates, &Predicate.acceptance?/1)
  end

  defp to_budget(%Budget{} = budget), do: budget
  defp to_budget(opts) when is_list(opts), do: Budget.new(opts)

  defp to_scope(%Scope{} = scope), do: scope
  defp to_scope(opts) when is_list(opts), do: Scope.new(opts)
end
