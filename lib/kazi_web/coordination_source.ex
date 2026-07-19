defmodule KaziWeb.CoordinationSource do
  @moduledoc """
  The injectable read seam the presence/lease map LiveView renders from
  (T3.6c, UC-018, ADR-0011).

  The lease map is a pure READ projection of the coordination substrate: live
  presence + per-resource work-intent (`Kazi.Coordination.Presence`, T3.1c) and
  the active resource leases (`Kazi.Coordination.Lease`, T3.1a). Those live on the
  NATS transport, but the LiveView never touches NATS directly — it asks a
  *source* for a `%Snapshot{}` and subscribes to that source's topic for live
  pushes. This is the ADR-0011 §3 injection seam: production points it at a real
  aggregator over the transport; a LiveView/Playwright test points it at a fixture
  source that holds the snapshot in memory and pushes updates on demand, so the
  whole surface certifies with no NATS and no harness.

  ## The contract

    * `snapshot/0` returns the current `%Snapshot{}` — the present instances, their
      announced work-intents, and the active leases — already sorted for a stable,
      comparable render.
    * `topic/0` names the `Kazi.PubSub` topic the source broadcasts on. The view
      subscribes on its connected mount; a broadcast of `{:coordination_updated, snapshot}`
      re-renders. Simulating a lease release is exactly a fresh snapshot pushed on
      this topic.

  A snapshot is deliberately a flat, render-ready value (not a live handle), so the
  view holds no transport/loop/harness reference — honoring the ADR-0011 read-only
  boundary.
  """

  alias KaziWeb.CoordinationSource.Snapshot

  @doc "The current presence/intent/lease snapshot, render-ready and sorted."
  @callback snapshot() :: Snapshot.t()

  @doc "The `Kazi.PubSub` topic this source broadcasts `{:coordination_updated, snapshot}` on."
  @callback topic() :: String.t()

  @doc """
  The source the dashboard renders from (T55.3, ADR-0073 §4).

  An explicit `:lease_map_source` application-env override always wins — the
  existing ADR-0011 §3 injection seam, unchanged. Absent an override the choice
  follows the daemon: when a kazi daemon's control socket probes `:alive` (the
  same `Kazi.Daemon.Probe` detection `kazi daemon status` uses), the default is
  the transport-backed source, so bus presence — which lives in the daemon's KV
  and is structurally invisible to the native source — renders live. When no
  daemon is reachable the default falls back to `Native` and a native run
  renders exactly as before.
  """
  @spec select() :: module()
  def select do
    case Application.get_env(:kazi, :lease_map_source) do
      nil -> default_source()
      source -> source
    end
  end

  @doc """
  The daemon control socket the dashboard probes to pick its default source.

  Defaults to `Kazi.Daemon.Supervisor.default_sock_path/0` (the exact path the
  CLI's daemon verbs probe); overridable via the `:lease_map_daemon_sock`
  application env so tests choose the daemon-present/absent branch
  deterministically (`config/test.exs` points it at a never-existing path).
  """
  @spec daemon_sock_path() :: Path.t()
  def daemon_sock_path do
    Application.get_env(:kazi, :lease_map_daemon_sock) ||
      Kazi.Daemon.Supervisor.default_sock_path()
  end

  # Probe-driven default: Transport when a daemon listens, Native otherwise.
  # `:dead` (stale socket file) and `:missing` both mean no daemon.
  defp default_source do
    case Kazi.Daemon.Probe.probe(daemon_sock_path()) do
      :alive -> KaziWeb.CoordinationSource.Transport
      _down -> KaziWeb.CoordinationSource.Native
    end
  end

  defmodule Snapshot do
    @moduledoc """
    The render-ready presence/lease projection at a moment.

      * `:present` — live instances, each `%{instance, announced_at_ms}` plus the
        optional roster detail (`machine`, `last_seen`) a bus-backed source adds,
        sorted by instance id;
      * `:intents` — live work-intents, each `%{instance, resource, announced_at_ms}`,
        sorted by `{instance, resource}`;
      * `:leases` — active leases, each `%{key, holder, expires_at_ms}`, sorted by
        resource key — the lease *map* (resource → holder) the view renders.

    Mirrors `Kazi.Coordination.Presence.Snapshot` for presence/intent and projects
    `Kazi.Coordination.Lease` structs down to the fields the view shows.
    """

    @typedoc """
    A live presence entry: an instance and when it last beat. Roster-bearing
    sources (the bus roster behind the transport source, ADR-0073 §4) also carry
    `:machine` (the host the session runs on) and `:last_seen` (a render-ready
    freshness label, e.g. `"12s ago"`); sources without roster detail omit both
    and the view renders the bare instance row as before.
    """
    @type presence_entry :: %{
            required(:instance) => String.t(),
            required(:announced_at_ms) => non_neg_integer(),
            optional(:machine) => String.t(),
            optional(:last_seen) => String.t()
          }

    @typedoc "A live work-intent: an instance, the resource it intends, and when it announced."
    @type intent_entry :: %{
            instance: String.t(),
            resource: String.t(),
            announced_at_ms: non_neg_integer()
          }

    @typedoc "An active lease: the resource key, its holder, and its absolute expiry."
    @type lease_entry :: %{
            key: String.t(),
            holder: String.t(),
            expires_at_ms: non_neg_integer()
          }

    @type t :: %__MODULE__{
            present: [presence_entry()],
            intents: [intent_entry()],
            leases: [lease_entry()]
          }

    @enforce_keys [:present, :intents, :leases]
    defstruct present: [], intents: [], leases: []
  end

  @doc """
  Builds a sorted `%Snapshot{}` from raw presence/intent/lease lists.

  A convenience for sources: takes a `Kazi.Coordination.Presence.Snapshot`'s
  `present`/`intents` and a list of `Kazi.Coordination.Lease` structs, projects
  the leases to `{key, holder, expires_at_ms}`, and sorts each list so the render
  is deterministic regardless of source ordering.
  """
  @spec build([Snapshot.presence_entry()], [Snapshot.intent_entry()], [
          Kazi.Coordination.Lease.t()
        ]) :: Snapshot.t()
  def build(present, intents, leases) do
    %Snapshot{
      present: Enum.sort_by(present, & &1.instance),
      intents: Enum.sort_by(intents, &{&1.instance, &1.resource}),
      leases:
        leases
        |> Enum.map(fn lease ->
          %{key: lease.key, holder: lease.holder, expires_at_ms: lease.expires_at_ms}
        end)
        |> Enum.sort_by(& &1.key)
    }
  end
end
