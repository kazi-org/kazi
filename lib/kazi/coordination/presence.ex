defmodule Kazi.Coordination.Presence do
  @moduledoc """
  Live presence + per-resource work-intent over the coordination transport
  (T3.1c, ADR-0004/0006; UC-013).

  Parallel kazi instances need to see each other and negotiate *before* they
  collide: each instance heartbeats its **presence** and announces, per resource,
  the **work-intent** it is about to act on (ADR-0006's "live awareness" — the
  `presence.*` / `intent.*` subjects of ADR-0004). This module is the feature over
  the `Kazi.Coordination.Transport` seam: it publishes those announcements and
  aggregates everyone's announcements into one current `%Snapshot{}` — who is
  present and who intends to touch which resource — dropping entries that have aged
  past a TTL.

  ## Announce, then aggregate

    * `announce_presence(instance, opts)` publishes a presence heartbeat for
      `instance` stamped with the injected `now_ms`.
    * `announce_intent(instance, resource, opts)` publishes that `instance` intends
      to work `resource`, likewise stamped.
    * `snapshot(opts)` fetches every announcement from the transport and **merges**
      them: the latest heartbeat per instance, and the latest intent per
      `{instance, resource}`. Announcements older than `now_ms - ttl_ms` are aged
      out, so a crashed instance that stopped heartbeating disappears from the
      snapshot once its last beat passes the TTL.

  Merging is last-writer-wins per identity: a fresh heartbeat from an instance
  supersedes its older one (presence is level, not edge), so an instance that keeps
  beating stays present indefinitely while one that stops ages out — without the
  transport itself knowing anything about time.

  ## Injected clock (deterministic TTL)

  Every call takes its "now" from `opts` via `Kazi.Coordination.Lease.now_ms/1`
  (`:now_ms` / `:now_fn`) — the same injected-clock contract the lease substrate
  uses — and never reads a wall clock in an aging decision. A heartbeat stamped at
  `t` is live for `t..t+ttl_ms-1` and aged out at `t+ttl_ms`; the boundary is a
  pure comparison against the supplied `now_ms`, so a test drives staleness with a
  virtual clock — no `Process.sleep`, no real time, no network.

  ## Hermetic by construction

  Presence touches the world only through the transport seam, so against the
  in-memory transport (`Kazi.Coordination.Transport.Memory`) the whole thing runs
  with no NATS server and no network. Two in-memory buses pointed at the same
  underlying instance, or two instances publishing to one bus, both aggregate the
  same way — which is exactly how the conformance test exercises a merged snapshot.
  """

  alias Kazi.Coordination.Lease

  @presence_subject "presence"
  @intent_subject "intent"

  @typedoc "An instance identity — who is present / announcing intent (e.g. a kazi instance id)."
  @type instance :: String.t()

  @typedoc "A resource key an instance intends to work (e.g. a blast-radius identifier)."
  @type resource :: String.t()

  @typedoc """
  Per-call options. Carries the transport handle + module and the injected clock:

    * `:transport` — the module implementing `Kazi.Coordination.Transport`
      (defaults to `Kazi.Coordination.Transport.Memory`);
    * plus the transport's own per-call opts (e.g. `:bus`), passed through verbatim;
    * `:now_ms` / `:now_fn` — the injected clock, resolved via
      `Kazi.Coordination.Lease.now_ms/1`;
    * `:ttl_ms` — how long an announcement stays live (defaults to
      `#{30_000}` ms); an entry is aged out once `now_ms >= announced_at + ttl_ms`.
  """
  @type opts :: keyword()

  @default_ttl_ms 30_000

  defmodule Snapshot do
    @moduledoc """
    The aggregated, TTL-filtered view of presence + intent at a moment (`now_ms`).

      * `:present` — the live instances, each `%{instance, announced_at_ms}`,
        sorted by instance id for a stable, comparable snapshot;
      * `:intents` — the live work-intents, each `%{instance, resource,
        announced_at_ms}`, sorted by `{instance, resource}`.

    Both lists exclude anything aged past the TTL, so a snapshot reflects only who
    and what is *currently* live on the injected clock.
    """

    @typedoc "A live presence entry: an instance and when it last beat."
    @type presence_entry :: %{
            instance: Kazi.Coordination.Presence.instance(),
            announced_at_ms: non_neg_integer()
          }

    @typedoc "A live intent entry: an instance, the resource it intends, and when it announced."
    @type intent_entry :: %{
            instance: Kazi.Coordination.Presence.instance(),
            resource: Kazi.Coordination.Presence.resource(),
            announced_at_ms: non_neg_integer()
          }

    @type t :: %__MODULE__{
            present: [presence_entry()],
            intents: [intent_entry()]
          }

    @enforce_keys [:present, :intents]
    defstruct [:present, :intents]
  end

  @doc """
  Publishes a presence heartbeat for `instance`, stamped with the injected `now_ms`.

  Returns `:ok`. Call it periodically (on the loop's clock) to stay present; an
  instance that stops calling ages out of `snapshot/1` once its last beat passes
  the TTL.
  """
  @spec announce_presence(instance(), opts()) :: :ok
  def announce_presence(instance, opts) when is_binary(instance) do
    now = Lease.now_ms(opts)
    publish(@presence_subject, %{instance: instance, announced_at_ms: now}, opts)
  end

  @doc """
  Publishes that `instance` intends to work `resource`, stamped with the injected
  `now_ms`.

  Returns `:ok`. The latest intent per `{instance, resource}` wins in the merged
  snapshot; a fresh re-announcement keeps the intent live, an un-renewed one ages
  out.
  """
  @spec announce_intent(instance(), resource(), opts()) :: :ok
  def announce_intent(instance, resource, opts)
      when is_binary(instance) and is_binary(resource) do
    now = Lease.now_ms(opts)

    publish(
      @intent_subject,
      %{instance: instance, resource: resource, announced_at_ms: now},
      opts
    )
  end

  @doc """
  Aggregates every announcement on the transport into the current `%Snapshot{}` at
  the injected `now_ms`, dropping entries aged past the TTL.

  Presence merges last-writer-wins per instance; intent merges last-writer-wins per
  `{instance, resource}`. An announcement is live iff `now_ms < announced_at + ttl_ms`
  (default TTL `#{@default_ttl_ms}` ms, overridable via `:ttl_ms`). Both snapshot
  lists are sorted for a stable, comparable result.
  """
  @spec snapshot(opts()) :: {:ok, Snapshot.t()}
  def snapshot(opts) do
    now = Lease.now_ms(opts)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    transport = transport(opts)

    {:ok, presence_msgs} = transport.fetch(@presence_subject, opts)
    {:ok, intent_msgs} = transport.fetch(@intent_subject, opts)

    present =
      presence_msgs
      |> latest_by(& &1.instance)
      |> live(now, ttl_ms)
      |> Enum.sort_by(& &1.instance)

    intents =
      intent_msgs
      |> latest_by(&{&1.instance, &1.resource})
      |> live(now, ttl_ms)
      |> Enum.sort_by(&{&1.instance, &1.resource})

    {:ok, %Snapshot{present: present, intents: intents}}
  end

  # Collapse a subject's append-only log to the latest announcement per identity
  # (last-writer-wins): later messages in the oldest-first log overwrite earlier
  # ones for the same key.
  @spec latest_by([map()], (map() -> term())) :: [map()]
  defp latest_by(messages, key_fun) do
    messages
    |> Enum.reduce(%{}, fn msg, acc -> Map.put(acc, key_fun.(msg), msg) end)
    |> Map.values()
  end

  # Drop entries aged past the TTL: an announcement stamped at `t` is live for
  # `t..t+ttl_ms-1` and aged out at `t+ttl_ms`. Pure comparison against the
  # injected clock — never a wall clock.
  @spec live([map()], non_neg_integer(), pos_integer()) :: [map()]
  defp live(entries, now, ttl_ms) do
    Enum.filter(entries, fn %{announced_at_ms: at} -> now < at + ttl_ms end)
  end

  defp publish(subject, msg, opts) do
    transport(opts).publish(subject, msg, opts)
  end

  defp transport(opts) do
    Keyword.get(opts, :transport, Kazi.Coordination.Transport.Memory)
  end
end
