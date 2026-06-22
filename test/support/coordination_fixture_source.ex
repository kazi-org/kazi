defmodule KaziWeb.CoordinationFixtureSource do
  @moduledoc """
  An in-memory `KaziWeb.CoordinationSource` for hermetic certification of the
  presence/lease map LiveView (T3.6c, UC-018).

  Compiled ONLY in the test env (`test/support` is on the `:test` elixirc path),
  so it never ships. It holds one `%Snapshot{}` in a GenServer and serves it to the
  view; `put_snapshot/1` replaces it and broadcasts `{:coordination_updated, snapshot}`
  on the source topic, which is exactly how a test (or the Playwright seed endpoint)
  *simulates a lease release*: push a fresh snapshot with the released lease dropped
  and the subscribed view re-renders. No NATS, no transport — the fixture IS the
  snapshot (ADR-0011 §3).

  The module satisfies the `KaziWeb.CoordinationSource` behaviour via the static
  `topic/0` and a `snapshot/0` that reads the GenServer's current value, so the
  LiveView calls it exactly as it would the production source.
  """
  use GenServer

  @behaviour KaziWeb.CoordinationSource

  alias KaziWeb.CoordinationSource
  alias KaziWeb.CoordinationSource.Snapshot

  @topic "coordination:lease_map:fixture"

  @doc "Starts the fixture source holding an initial (default empty) snapshot."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :snapshot, empty_snapshot())
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  @impl CoordinationSource
  def topic, do: @topic

  @impl CoordinationSource
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Replaces the held snapshot and broadcasts it on the source topic so subscribed
  views re-render. This is the live-update / simulated-release lever.
  """
  @spec put_snapshot(Snapshot.t()) :: :ok
  def put_snapshot(%Snapshot{} = snapshot) do
    GenServer.call(__MODULE__, {:put, snapshot})
  end

  @doc "An empty snapshot — no presence, no intent, no leases."
  @spec empty_snapshot() :: Snapshot.t()
  def empty_snapshot, do: CoordinationSource.build([], [], [])

  @impl GenServer
  def init(snapshot), do: {:ok, snapshot}

  @impl GenServer
  def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}

  @impl GenServer
  def handle_call({:put, snapshot}, _from, _state) do
    Phoenix.PubSub.broadcast(Kazi.PubSub, @topic, {:coordination_updated, snapshot})
    {:reply, :ok, snapshot}
  end
end
