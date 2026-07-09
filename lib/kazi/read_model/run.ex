defmodule Kazi.ReadModel.Run do
  @moduledoc """
  A row in the fleet run registry (T46.1, ADR-0057): one `kazi apply` process on
  this machine, upserted on start and heartbeated each loop tick.

  This is the read-model schema backing `Kazi.ReadModel.RunRegistry`. Liveness is
  a derived property (heartbeat staleness), not a stored one — a crashed process
  leaves its last heartbeat behind rather than an explicit "dead" row, which is
  exactly what makes a SIGKILLed run distinguishable from one that never existed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "runs" do
    field(:run_id, :string)
    field(:pid, :string)
    field(:workspace, :string)
    field(:goal_ref, :string)
    field(:harness, :string)
    field(:model, :string)
    field(:status, :string, default: "running")
    field(:started_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:events_sink_path, :string)
    field(:transcript_sink_path, :string)
    # T46.6 (ADR-0057): the run's declared iteration budget ceiling
    # (`goal.budget.max_iterations`), captured once at registration so the
    # attention queue can compute "budget consumed" fleet-wide with no goal
    # reload. `nil` for an unbounded goal or a pre-T46.6 row.
    field(:max_iterations, :integer)
    # Session identity (ADR-0057 follow-up): the operator-assigned label
    # (`kazi apply --session-name` / KAZI_SESSION_NAME) telling concurrent
    # runs apart on the starmap rail, and the inner harness's own session id
    # (the claude envelope's `session_id`) so a run can be resumed
    # interactively (`claude -r <id>`). Both nil on pre-existing rows.
    field(:session_name, :string)
    field(:harness_session_id, :string)
    # Session provenance part 2: when this run was registered from an
    # approved proposal (`kazi apply <proposal-ref>`), the proposal_ref it
    # came from -- copied at registration so a run traces back to the
    # proposal (and its session_name) even when the applying session differs
    # from the planning one. Nil for a plain goal-file-path run.
    field(:proposal_ref, :string)
    # Issue #857: the OS pid of the dispatched harness subprocess (as reported
    # by `Kazi.Harness.CliAdapter`'s child-supervision wrapper), so a fresh
    # apply for the same goal_ref can warn when a previous run's harness child
    # is still alive. nil until a dispatch reports one.
    field(:harness_child_pid, :string)
    # T48.15: the OS process id (as an integer stored as string) for liveness
    # detection in run reaping. Recorded when a dispatch starts the child process.
    field(:os_pid, :string)
    field(:session_os_pid, :string)
    # --- T48.7 (ADR-0058 decision 1): run-end economics ---------------------
    # Persisted at terminal projection (`RunRegistry.finish/3`) alongside the
    # terminal status. Honest-unknown (ADR-0046): the token/cost fields are
    # nil when the harness never reported usage this run — never coerced to 0.
    field(:budget_tokens, :integer)
    field(:budget_cached_input_tokens, :integer)
    field(:budget_cost_usd, :float)
    # Loop-tracked (not harness-reported): always known, defaults to 0.
    field(:dispatch_count, :integer, default: 0)
    # The T48.4 (ADR-0058 decision 4) honest terminal cause class —
    # "budget_exhausted" / "error_wedged" / "quarantine_blocked" — or nil when
    # no mislabel applies (a clean converge, or a stop that is exactly what it
    # says it is; see `Kazi.Loop.CauseClass`).
    field(:outcome_cause_class, :string)
    # T48.4: the cause detail — implicated predicate ids, their stringified
    # last-observed reasons, and the exhausted budget dimension. Nullable, no
    # default (honest-unknown: absent means "no cause classified").
    field(:outcome_cause_detail, :map)
    # The active ADR-0047 context tier at termination.
    field(:context_tier, :integer)
    # Goal shape, computed from the goal at run start.
    field(:predicate_count, :integer)
    field(:predicate_kind_histogram, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @required [:run_id, :pid, :workspace, :goal_ref, :started_at, :heartbeat_at]
  @optional [
    :harness,
    :model,
    :status,
    :finished_at,
    :events_sink_path,
    :transcript_sink_path,
    :max_iterations,
    :session_name,
    :harness_session_id,
    :proposal_ref,
    :harness_child_pid,
    :os_pid,
    :session_os_pid,
    :budget_tokens,
    :budget_cached_input_tokens,
    :budget_cost_usd,
    :dispatch_count,
    :outcome_cause_class,
    :outcome_cause_detail,
    :context_tier,
    :predicate_count,
    :predicate_kind_histogram
  ]

  @doc """
  Builds a changeset for inserting/upserting a run row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:run_id)
  end
end
