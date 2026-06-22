defmodule Kazi.Coordination.Transport do
  @moduledoc """
  The pub/sub transport seam — and the **behaviour** every concrete transport
  implements (T3.1c, ADR-0004; UC-013).

  kazi's live coordination (presence heartbeats, per-resource work-intent
  announcements) flows over NATS subjects `presence.*` / `intent.*` (ADR-0004).
  This module is the *substrate* under that: the narrow publish/subscribe/fetch
  contract a transport must satisfy, kept independent of how messages are carried.
  It is the sibling of `Kazi.Coordination.Lease` — that abstracts the lease store;
  this abstracts the live channel — so a feature built on it (`Kazi.Coordination.Presence`)
  stays hermetic, testable against an in-memory double, and swaps to real NATS
  (T3.1b) without changing a line of the feature.

  ## The contract in one paragraph

  `publish(subject, msg, opts)` appends `msg` to `subject`'s log, returning `:ok`.
  `fetch(subject, opts)` returns `{:ok, messages}` — every message published to
  `subject` so far, oldest-first — so an aggregator can pull the current chatter
  without holding a live subscription. `subscribe(subject, opts)` registers the
  calling process to receive future publishes to `subject` as
  `{:kazi_transport, subject, msg}` messages, returning `:ok`; it is how a
  long-lived process reacts to live updates. A transport carries opaque message
  terms — it neither inspects nor ages them; **staleness is the caller's concern**
  (presence ages entries on its own injected clock), so the transport has no
  notion of time and reads no wall clock.

  ## Subjects

  A `subject` is a plain string topic (e.g. `"presence"`, `"intent.lib/a.ex"`).
  Wildcard semantics (NATS `presence.*`) are a backend concern and out of scope
  here: a caller subscribes to exact subjects, mirroring how the in-memory double
  and the eventual JetStream subject map line up one-to-one.

  ## Instance, not global

  A transport is a running instance referenced by a handle passed per call as the
  `:bus` option, exactly like the lease store's `:store` handle. Nothing is
  global: each bus is independent, so concurrent tests and concurrent goals are
  isolated without naming collisions.
  """

  @typedoc "A pub/sub topic: a plain string subject (e.g. `\"presence\"`)."
  @type subject :: String.t()

  @typedoc "An opaque message term carried verbatim by the transport."
  @type message :: term()

  @typedoc """
  Per-call options. Carries the transport instance handle (e.g. `:bus`) and any
  backend-specific options. The transport reads no clock — staleness is the
  caller's concern — so no time options ride here.
  """
  @type opts :: keyword()

  @doc """
  Publishes `msg` to `subject`, appending it to the subject's log and delivering
  it to every live subscriber.

  Returns `:ok`. The message is carried verbatim; the transport does not inspect,
  transform, or age it.
  """
  @callback publish(subject(), message(), opts()) :: :ok

  @doc """
  Subscribes the **calling process** to future publishes on `subject`.

  After subscribing, each subsequent `publish/3` to `subject` delivers a
  `{:kazi_transport, subject, msg}` message to the subscriber's mailbox. Returns
  `:ok`. Existing (already-published) messages are not replayed — use `fetch/2`
  to read the backlog.
  """
  @callback subscribe(subject(), opts()) :: :ok

  @doc """
  Fetches every message published to `subject` so far, oldest-first.

  Returns `{:ok, messages}` (an empty list for an unknown or quiet subject). This
  is the pull path an aggregator uses to compute a snapshot without holding a
  live subscription; it does not consume or acknowledge messages.
  """
  @callback fetch(subject(), opts()) :: {:ok, [message()]}
end
