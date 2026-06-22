defmodule Kazi.Coordination.Transport.Memory do
  @moduledoc """
  The in-process `Kazi.Coordination.Transport` backend: the **real single-node
  default**, and the test double for presence (T3.1c, ADR-0004; UC-013).

  This is not a stub. Within one BEAM node it is a correct pub/sub bus: an `Agent`
  holds `subject => {messages, subscribers}`, `publish/3` appends the message and
  fans it out to every subscribed pid synchronously, and `fetch/2` returns a
  subject's backlog oldest-first. The NATS subject transport (T3.1b) replaces this
  only when chatter must cross nodes; on a single node this *is* the live channel,
  not a placeholder.

  ## Instance, not global

  A bus is a running `Agent` referenced by a `{__MODULE__, pid}` tuple, passed per
  call as the `:bus` option — the same instance-handle shape as the lease store's
  `:store`. Nothing is global: each bus is independent, so tests (and concurrent
  goals) are isolated without naming collisions, and a presence test spins up a
  fresh bus per case.

      {:ok, bus} = Kazi.Coordination.Transport.Memory.start_link()
      transport = Kazi.Coordination.Transport.Memory
      :ok = transport.publish("presence", %{instance: "a"}, bus: bus)
      {:ok, [%{instance: "a"}]} = transport.fetch("presence", bus: bus)

  ## No clock

  The transport carries opaque terms and never reads time — staleness is the
  caller's concern (`Kazi.Coordination.Presence` ages entries on its own injected
  clock). So this module takes no `:now_ms`/`:now_fn` and the bus stays a pure
  message log, which keeps presence's TTL behaviour deterministic from outside.
  """

  @behaviour Kazi.Coordination.Transport

  use Agent

  @typedoc "An opaque handle to a running bus: the module-tagged Agent pid."
  @type bus :: {__MODULE__, pid()}

  # Per-subject state: the append-only message log (oldest-first) and the set of
  # live subscriber pids that future publishes fan out to.
  @typep subject_state :: %{messages: [term()], subscribers: MapSet.t(pid())}

  @doc """
  Starts a fresh, empty bus and returns `{:ok, bus_handle}`.

  The handle is the `{__MODULE__, pid}` tuple passed back per call as `:bus`.
  Accepts standard `Agent.start_link/2` options (e.g. `:name`) under `opts`.
  """
  @spec start_link(keyword()) :: {:ok, bus()} | {:error, term()}
  def start_link(opts \\ []) do
    case Agent.start_link(fn -> %{} end, opts) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      {:error, _reason} = error -> error
    end
  end

  @impl Kazi.Coordination.Transport
  def publish(subject, msg, opts) when is_binary(subject) do
    pid = bus_pid(opts)

    # Append under the Agent lock, then fan out to whoever was subscribed at the
    # moment of publish. Snapshotting subscribers inside get_and_update keeps the
    # delivered set consistent with the append.
    subscribers =
      Agent.get_and_update(pid, fn subjects ->
        state = subject_state(subjects, subject)
        updated = %{state | messages: state.messages ++ [msg]}
        {state.subscribers, Map.put(subjects, subject, updated)}
      end)

    Enum.each(subscribers, &send(&1, {:kazi_transport, subject, msg}))
    :ok
  end

  @impl Kazi.Coordination.Transport
  def subscribe(subject, opts) when is_binary(subject) do
    pid = bus_pid(opts)
    subscriber = self()

    Agent.update(pid, fn subjects ->
      state = subject_state(subjects, subject)
      updated = %{state | subscribers: MapSet.put(state.subscribers, subscriber)}
      Map.put(subjects, subject, updated)
    end)
  end

  @impl Kazi.Coordination.Transport
  def fetch(subject, opts) when is_binary(subject) do
    pid = bus_pid(opts)
    {:ok, Agent.get(pid, fn subjects -> subject_state(subjects, subject).messages end)}
  end

  # The state for `subject`, defaulting to an empty log + no subscribers when the
  # subject has never been touched.
  @spec subject_state(map(), Kazi.Coordination.Transport.subject()) :: subject_state()
  defp subject_state(subjects, subject) do
    Map.get(subjects, subject, %{messages: [], subscribers: MapSet.new()})
  end

  # Resolve the bus pid from the `:bus` handle. The handle is required: a transport
  # is an instance, never a global, so a missing bus is a caller bug.
  @spec bus_pid(keyword()) :: pid()
  defp bus_pid(opts) do
    case Keyword.fetch(opts, :bus) do
      {:ok, {__MODULE__, pid}} when is_pid(pid) -> pid
      {:ok, pid} when is_pid(pid) -> pid
      _ -> raise ArgumentError, "#{inspect(__MODULE__)} requires a :bus handle in opts"
    end
  end
end
