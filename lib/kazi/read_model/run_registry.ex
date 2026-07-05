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
  Records a terminal verdict (`"converged"` / `"stuck"` / `"over_budget"` /
  `"error"`) and stamps `finished_at`. Terminal status excludes a run from the
  stale query regardless of how old its last heartbeat is — it exited on
  purpose, it didn't hang.
  """
  @spec finish(String.t(), String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def finish(run_id, status) when is_binary(run_id) and is_binary(status) do
    case Repo.get_by(Run, run_id: run_id) do
      nil ->
        {:error, :not_found}

      run ->
        run
        |> Run.changeset(%{"status" => status, "finished_at" => DateTime.utc_now()})
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
end
