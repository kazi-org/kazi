defmodule Kazi.ReadModel.RunRegistry do
  @moduledoc """
  The fleet run registry (T46.1, ADR-0057): every `kazi apply` process on this
  machine upserts a `runs` row at start, heartbeats it each loop tick, and
  records a terminal status on exit. Liveness has no IPC — it is computed from
  heartbeat staleness (`stale?/2`), so a SIGKILLed run is visibly stale rather
  than silently absent, and a dead run's row is never deleted (it is the fleet
  dashboard's post-mortem record).

  This module is the ONLY writer/reader of `Kazi.ReadModel.Run`; callers
  (`Kazi.Loop`, `kazi dashboard`) go through it rather than touching `Kazi.Repo`
  directly, matching the read-model's other projections (`Kazi.ReadModel`).
  """

  import Ecto.Query

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  # A run with no heartbeat in this long is considered stale (crashed or hung)
  # when it carries no terminal status. Documented per T46.1's acceptance
  # criterion; a future knob can make this configurable without changing the
  # query shape.
  @stale_after_seconds 90

  @doc """
  Upserts a run row: inserts on first start, or refreshes an existing row (same
  `run_id`) back to `"running"` with a fresh heartbeat — used both to register a
  new run and to have a restarted process reclaim its own registry row.
  """
  @spec start(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("started_at", now)
      |> Map.put("heartbeat_at", now)
      |> Map.put_new("status", "running")

    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :pid,
           :workspace,
           :goal_ref,
           :harness,
           :model,
           :status,
           :started_at,
           :heartbeat_at,
           :finished_at,
           :transcript_sink_path,
           :events_sink_path,
           :max_iterations,
           :session_name,
           :os_pid,
           :updated_at
         ]},
      conflict_target: :run_id,
      returning: true
    )
  end

  @doc """
  Advances a run's heartbeat to now. A no-op error tuple (`{:error, :not_found}`)
  when the run_id isn't registered, so a caller can distinguish "never started"
  from a transient write failure.
  """
  @spec heartbeat(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def heartbeat(run_id) when is_binary(run_id) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      run ->
        run
        |> Run.changeset(%{"heartbeat_at" => DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Records the inner harness's own session id (e.g. the claude envelope's
  `session_id`) on the run row, so the dashboard can offer an interactive
  resume (`claude -r <id>`). Idempotent: rewriting the same id is a no-op
  read; a changed id (the harness rotated sessions mid-run) records the
  newest one — the resumable one.
  """
  @spec record_harness_session(String.t(), String.t()) ::
          {:ok, Run.t()} | {:error, :not_found}
  def record_harness_session(run_id, session_id)
      when is_binary(run_id) and is_binary(session_id) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      %Run{harness_session_id: ^session_id} = run ->
        {:ok, run}

      run ->
        run
        |> Run.changeset(%{"harness_session_id" => session_id})
        |> Repo.update()
    end
  end

  @doc """
  Records the OS pid of the dispatched harness subprocess (issue #857), so a
  fresh apply for the same `goal_ref` can detect a still-alive prior run's
  child (`orphan_candidates/2`). Idempotent, like `record_harness_session/2`.
  """
  @spec record_harness_pid(String.t(), String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def record_harness_pid(run_id, pid) when is_binary(run_id) and is_binary(pid) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      %Run{harness_child_pid: ^pid} = run ->
        {:ok, run}

      run ->
        run
        |> Run.changeset(%{"harness_child_pid" => pid})
        |> Repo.update()
    end
  end

  @doc """
  Records a terminal verdict (`"converged"` / `"stuck"` / `"over_budget"` /
  `"error"`) and stamps `finished_at`. Terminal status excludes a run from the
  stale query regardless of how old its last heartbeat is — it exited on
  purpose, it didn't hang.

  `economics` (T48.7, ADR-0058 decision 1) carries the optional run-end
  figures projected alongside the status: `:budget_tokens`,
  `:budget_cached_input_tokens`, `:budget_cost_usd`, `:dispatch_count`,
  `:outcome_cause_class`, `:context_tier`, `:predicate_count`,
  `:predicate_kind_histogram`. Defaults to `%{}` (byte-identical to the
  pre-T48.7 call) so every existing caller is unaffected. The caller is
  responsible for the honest-unknown discipline (ADR-0046) — a key it omits
  here is left at its column default/nil, never coerced to 0 by this module.
  """
  @spec finish(String.t() | Run.t(), String.t(), map()) ::
          {:ok, Run.t()} | {:error, :not_found}
  def finish(run_or_id, status, economics \\ %{})

  def finish(%Run{run_id: run_id}, status, economics) when is_binary(status),
    do: finish(run_id, status, economics)

  def finish(run_id, status, economics)
      when is_binary(run_id) and is_binary(status) and is_map(economics) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      run ->
        attrs =
          economics
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.put("status", status)
          |> Map.put("finished_at", DateTime.utc_now())

        run
        |> Run.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Lists every registered run, most recently started first."
  @spec list() :: [Run.t()]
  def list do
    Run
    |> order_by(desc: :started_at)
    |> Repo.all()
  end

  @doc "Fetches a single run by its `run_id`, or `nil` when it isn't registered."
  @spec get(String.t()) :: Run.t() | nil
  def get(run_id) when is_binary(run_id) do
    Repo.get_by(Run, run_id: run_id)
  end

  @doc """
  Lists every registered run for `goal_ref` other than `exclude_run_id` (the
  caller's own, about-to-register run), most recently started first. Used by
  the orphan-on-resume check (issue #857) to find prior runs of the SAME goal
  whose recorded `harness_child_pid` might still be alive.
  """
  @spec list_by_goal_ref(String.t(), String.t()) :: [Run.t()]
  def list_by_goal_ref(goal_ref, exclude_run_id) when is_binary(goal_ref) do
    Run
    |> where([r], r.goal_ref == ^goal_ref and r.run_id != ^exclude_run_id)
    |> order_by(desc: :started_at)
    |> Repo.all()
  end

  @doc """
  True when `run` has no terminal status and its heartbeat is older than
  `stale_after_seconds` (default #{@stale_after_seconds}s). A terminal run is
  never stale — it converged/stopped on purpose.
  """
  @spec stale?(Run.t(), non_neg_integer()) :: boolean()
  def stale?(run, stale_after_seconds \\ @stale_after_seconds)

  def stale?(%Run{status: "running", heartbeat_at: heartbeat_at}, stale_after_seconds) do
    DateTime.diff(DateTime.utc_now(), heartbeat_at, :second) > stale_after_seconds
  end

  def stale?(%Run{}, _stale_after_seconds), do: false

  @doc "Lists every run currently classified stale (see `stale?/2`)."
  @spec list_stale(non_neg_integer()) :: [Run.t()]
  def list_stale(stale_after_seconds \\ @stale_after_seconds) do
    Enum.filter(list(), &stale?(&1, stale_after_seconds))
  end

  @doc """
  Records an external termination event (SIGTERM, SIGKILL, abnormal exit) for
  a run during the finalization phase. Used when the controller process receives
  a termination signal, allowing post-mortem observability even when the run
  exits abnormally. Idempotent: multiple calls do not alter the status.
  """
  @spec record_termination(String.t(), term()) :: {:ok, Run.t()} | {:error, :not_found}
  def record_termination(run_id, _reason) when is_binary(run_id) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      %Run{status: status} = run when status != "running" ->
        {:ok, run}

      run ->
        run
        |> Run.changeset(%{"status" => "terminated", "finished_at" => DateTime.utc_now()})
        |> Repo.update()
    end
  end
end
