defmodule Kazi.Bus.ProtocolSkew do
  @moduledoc """
  T58.2 (#1227): the client-side bus control-protocol skew check, extending
  T52.2's `ping`-reply handshake (`Kazi.ReadModel.SchemaSkew`) with a SECOND
  field on the SAME reply rather than a parallel version-negotiation
  mechanism, per T58.2's coordination note and T58.1's finding.

  T58.1 root-caused #1227: `join`/`who`/`tell` publish direct-to-NATS and
  never touch the daemon's Elixir op-dispatch code, so an old daemon binary
  cannot break them; `read` (T55.7) is dispatched through the daemon's
  control-socket `Kazi.Daemon.Control.handle/2`, so an old daemon -- one
  compiled before an op was added -- falls through to the `unknown_op`
  catch-all. That is a structural asymmetry: writes silently succeed under
  skew while reads fail with a cryptic, unexplained error.

  `bus_vsn` (an integer, bumped only when a control-socket op is added that
  an older daemon cannot serve) is the daemon's self-reported protocol
  level, always present on a `ping` reply from a daemon carrying this fix.
  Its ABSENCE is itself the signal: a daemon built before T58.2 does not
  know to send it at all, which is exactly the skewed case this exists to
  catch.

  `classify/1` runs at THE SAME connection seam every bus verb already goes
  through (`Kazi.Bus.with_discovered_conn/3` for writes, `read_assembled/1`
  for reads) so skew is caught BEFORE the op is attempted -- symmetric
  across read and write, and loud instead of `unknown_op`.
  """

  @typedoc "`:ok` -- daemon speaks a protocol at least as new as this client requires. `:daemon_outdated` -- it does not (or predates the handshake entirely)."
  @type classification :: :ok | :daemon_outdated

  # Bump alongside `Kazi.Daemon.Control`'s `@bus_vsn` whenever a control-socket
  # op is added that an older daemon cannot serve at all (the `read`/T55.7
  # class of change). Do NOT bump for additive, backward-compatible fields.
  @required_bus_vsn 1

  @doc """
  Classifies a `ping` reply (or any map carrying `"bus_vsn"`, e.g. a proposal
  candidate the caller is about to connect through) against this client's
  required protocol level.

  A missing or non-integer `bus_vsn` classifies as `:daemon_outdated` --
  a daemon built before this handshake existed cannot report otherwise, and
  that silence is the exact skew this module exists to catch.
  """
  @spec classify(map()) :: classification()
  def classify(pong) when is_map(pong) do
    case pong["bus_vsn"] do
      v when is_integer(v) and v >= @required_bus_vsn -> :ok
      _other -> :daemon_outdated
    end
  end

  @doc "This client's required bus-protocol level. Public so `Kazi.Daemon.Control` and tests stay pinned to the same number without duplicating the literal."
  @spec required_bus_vsn() :: pos_integer()
  def required_bus_vsn, do: @required_bus_vsn
end
