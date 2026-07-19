defmodule Kazi.Action do
  @moduledoc """
  An action the convergence loop can take to drive actual state toward desired
  state — and the **behaviour** every concrete action implements.

  This module is deliberately *both*:

    * a **data type** (`%Kazi.Action{}`) — a declarative description of an action
      the loop has decided to perform (its `kind`, the `params` for it, and a
      free-form `metadata` bag), produced by the state machine's
      `decide-next-action` step (T0.7);
    * a **behaviour** (`@callback execute/2`) — the contract a concrete action
      module implements to actually perform that action.

  In the walking skeleton (ADR-0007, concept §5) the loop's reconcile actions are
  not only "dispatch an agent": Slice 0 adds two **non-agent** actions —

    * `:integrate` — land a converged fix: branch → commit → push → open PR →
      rebase-merge (T0.10a, UC-020);
    * `:deploy` — ship the released artifact to the target (T0.10b, UC-015),
      behind a stub until the cloud target is provisioned (T0.6h);

  alongside `:dispatch_agent` — drive a coding agent against the failing-predicate
  evidence inside a leased blast radius (concept §5). The data type names *which*
  action; the behaviour says *how* to run one.

  ## Implementing the behaviour

  A concrete action module declares `@behaviour Kazi.Action` and implements
  `execute/2`. The integrate action (T0.10a) and deploy action (T0.10b) are the
  Slice 0 implementations; they live in their own modules, not here — this module
  is contract + data only (zero-stub policy).

      defmodule MyApp.IntegrateAction do
        @behaviour Kazi.Action

        @impl true
        def execute(%Kazi.Action{kind: :integrate} = action, context) do
          # ... branch/commit/push/PR/merge ...
          {:ok, %{pr: 42}}
        end
      end
  """

  @typedoc """
  The kind of action. Slice 0: `:dispatch_agent`, `:integrate`, `:deploy`. The
  type is left open (`atom()`) so later slices can add actions without a core
  change (ADR-0007: deepen, don't re-architect).
  """
  @type kind :: :dispatch_agent | :integrate | :deploy | atom()

  @typedoc "Parameters the action needs to execute, shaped per `kind`."
  @type params :: map()

  @type t :: %__MODULE__{
          kind: kind(),
          params: params(),
          metadata: map()
        }

  @enforce_keys [:kind]
  defstruct kind: nil, params: %{}, metadata: %{}

  @typedoc """
  Execution context passed alongside the action: the goal, the current predicate
  vector / failing-predicate evidence, the target workspace, and whatever else
  the loop threads through. Kept as a map so the contract does not couple to the
  state machine's internal state shape.
  """
  @type context :: map()

  @typedoc """
  The result of executing an action. `:ok`/`{:ok, result}` on success (the
  `result` map carries effects worth recording as evidence — e.g. a PR number, a
  deploy ref); `{:error, reason}` on failure so the loop can decide its next
  action.
  """
  @type result :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Performs the action against the given context.

  Implementations should be side-effecting *only* through their declared effect
  (integrate touches git/GitHub; deploy triggers a release) and must return a
  `result` the loop can record as evidence and branch on.
  """
  @callback execute(action :: t(), context :: context()) :: result()

  @doc """
  Builds an action.

  ## Examples

      iex> a = Kazi.Action.new(:deploy, params: %{ref: "v1"})
      iex> {a.kind, a.params}
      {:deploy, %{ref: "v1"}}
  """
  @spec new(kind(), keyword()) :: t()
  def new(kind, opts \\ []) when is_atom(kind) do
    %__MODULE__{
      kind: kind,
      params: Keyword.get(opts, :params, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
