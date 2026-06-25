defmodule KaziWeb.DagSource.Cache do
  @moduledoc """
  Remembers the latest DAG snapshot the scheduler broadcast, so the live
  dependency-DAG dashboard shows current run state the moment it mounts —
  including MID-RUN — rather than a blank view until the next transition (T23.7,
  UC-038, ADR-0011).

  The `Kazi.Scheduler.DepScheduler` publishes a `Kazi.Scheduler.DagSnapshot` on
  `DagSnapshot.topic/0` after every state change (init, each terminal, each
  regress). This cache subscribes to that topic and keeps the last frame in a
  GenServer; `KaziWeb.DagSource.snapshot/0` reads it. Until any run has
  broadcast, it serves `DagSnapshot.empty/0` (the honest "no active run" state).

  It is supervised only when the web tree boots (`Kazi.Application`, gated on the
  SQLite NIF like the rest of the dashboard). It is a pure CONSUMER of the
  scheduler's broadcasts — it never calls into the scheduler or the loop
  (ADR-0011 §2).
  """
  use GenServer

  alias Kazi.Scheduler.DagSnapshot

  @doc "Starts the cache, subscribed to the scheduler's DAG topic, holding the empty snapshot."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "The latest broadcast DAG snapshot, or `DagSnapshot.empty/0` if no run has broadcast yet."
  @spec current() :: DagSnapshot.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @impl GenServer
  def init(:ok) do
    # The cache only makes sense alongside the PubSub it subscribes to; the web
    # tree starts PubSub before this child, so the subscribe is safe.
    Phoenix.PubSub.subscribe(Kazi.PubSub, DagSnapshot.topic())
    {:ok, DagSnapshot.empty()}
  end

  @impl GenServer
  def handle_call(:current, _from, snapshot), do: {:reply, snapshot, snapshot}

  @impl GenServer
  def handle_info({:dag_updated, %DagSnapshot{} = snapshot}, _state), do: {:noreply, snapshot}
  def handle_info(_msg, state), do: {:noreply, state}
end
