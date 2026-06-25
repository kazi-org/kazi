defmodule KaziWeb.DagFixtureSource do
  @moduledoc """
  An in-memory `KaziWeb.DagSource` for hermetic certification of the live
  dependency-DAG dashboard (T23.7, UC-038).

  Compiled ONLY in the test env (`test/support` is on the `:test` elixirc path),
  so it never ships. It holds one `%Kazi.Scheduler.DagSnapshot{}` in a GenServer
  and serves it to the view; `put_snapshot/1` replaces it and broadcasts
  `{:dag_updated, snapshot}` on the source topic, which is exactly how a test
  simulates a run progressing: push a fresh snapshot with a group moved
  ready → running → converged and the subscribed view re-renders. No scheduler,
  no harness — the fixture IS the snapshot (ADR-0011 §3).
  """
  use GenServer

  @behaviour KaziWeb.DagSource

  alias Kazi.Scheduler.DagSnapshot

  @topic "scheduler:dag:fixture"

  @doc "Starts the fixture source holding an initial (default empty) snapshot."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :snapshot, DagSnapshot.empty())
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @impl KaziWeb.DagSource
  def topic, do: @topic

  @impl KaziWeb.DagSource
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Replaces the held snapshot and broadcasts it on the source topic so subscribed
  views re-render. This is the live-update lever (a run progressing).
  """
  @spec put_snapshot(DagSnapshot.t()) :: :ok
  def put_snapshot(%DagSnapshot{} = snapshot) do
    GenServer.call(__MODULE__, {:put, snapshot})
  end

  @impl GenServer
  def init(snapshot), do: {:ok, snapshot}

  @impl GenServer
  def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

  @impl GenServer
  def handle_call({:put, snapshot}, _from, _state) do
    Phoenix.PubSub.broadcast(Kazi.PubSub, @topic, {:dag_updated, snapshot})
    {:reply, :ok, snapshot}
  end
end
