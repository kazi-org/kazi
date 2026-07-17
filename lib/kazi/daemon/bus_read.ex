defmodule Kazi.Daemon.BusRead do
  @moduledoc """
  T55.7 (ADR-0072 decision 5): the daemon's SERVER-SIDE bus read. The client
  sends `{"op":"read"}` over the control socket; this module pulls the
  caller's consumers, aggregates, and hands back a bounded digest -- the bytes
  a client receives are already bounded, which is ADR-0067 point 5's own
  load-bearing argument ("only a server can aggregate before the tokens are
  spent") finally honoured. The CLI, the `kazi_bus_*` MCP tools, and the
  ADR-0071 hook all reach this one implementation, so the bound is written
  once rather than re-implemented three times.

  ## Identity is the CLIENT's, never the daemon's

  Consumers are named per session, and the daemon's own environment is not the
  caller's: it has no `KAZI_SESSION_NAME`, no `CLAUDE_CODE_SESSION_ID`, and
  its cwd is not the caller's repo. So the client resolves its own `session`
  and `scope` (`Kazi.Bus.session/1` / `Kazi.Bus.scope/1`) and passes them
  EXPLICITLY; this module never re-resolves them. Letting the daemon guess
  would silently drain the wrong session's inbox.

  ## Depth (L-0040)

  `Kazi.Bus.read/1` pulls one batch of 100, so a deeper backlog needs several
  calls. A digest that under-counts a 200-message backlog would defeat the
  purpose, so the destructive (`ack`) path loops until the consumers are drained
  and aggregates the whole set into ONE digest -- bounded by `@max_batches` so
  a firehose can never make the daemon loop unboundedly. The non-destructive
  (`peek`) path cannot loop: it NAKs everything it sees, so a second pull would
  return the same messages forever. It therefore pulls a single batch, exactly
  as `Kazi.Bus.peek/1` does today.

  Connection: one short-lived `Gnat` connection per request, discovered from
  the sibling `Kazi.Daemon.Nats` -- the same pattern `Kazi.Daemon.PresenceSweep`
  uses, and for the same reason (the daemon owns nats; a request must not
  depend on a long-lived client socket surviving).
  """

  require Logger

  alias Kazi.Bus
  alias Kazi.Bus.Digest

  # `Kazi.Bus.read/1` pulls @pull_batch (100) per call; 50 rounds bounds one
  # request at 5_000 messages. A backlog deeper than that still yields a
  # correct, bounded digest -- the remainder simply stays pending for the next
  # read, which is the same contract a single-batch read already had.
  @max_batches 50

  @doc """
  Assembles the digest for one control-socket `read` request.

  `request` is the decoded JSON: `session` and `scope` are the CLIENT's
  resolved identity (required -- see the moduledoc), `peek` selects the
  non-destructive pull, and `since` restricts the pull to stream sequences
  past a cursor. `full` is REFUSED here by design -- see `refuse_full/1`.

  `opts[:nats_name]` names the sibling `Kazi.Daemon.Nats` to discover the bus
  from; `opts[:connect_opts]` is the test seam that points a request at a
  scratch nats.
  """
  @spec handle(map(), keyword()) :: map()
  def handle(request, opts) do
    with :ok <- refuse_full(request),
         {:ok, session} <- fetch_identity(request, "session"),
         {:ok, scope} <- fetch_identity(request, "scope"),
         {:ok, connect_opts} <- resolve_connect_opts(opts),
         {:ok, conn} <- Gnat.start_link(connect_opts) do
      try do
        assemble(conn, request, session, scope)
      after
        if Process.alive?(conn), do: Gnat.stop(conn)
      end
    else
      {:error, reason} -> error(reason)
    end
  rescue
    error ->
      Logger.debug("kazi daemon: bus read failed (#{Exception.message(error)})")
      error("read_failed")
  catch
    kind, reason ->
      Logger.debug("kazi daemon: bus read failed (#{inspect(kind)}: #{inspect(reason)})")
      error("read_failed")
  end

  defp assemble(conn, request, session, scope) do
    bus_opts = [conn: conn, session: session, scope: scope]

    case pull(request, bus_opts) do
      {:ok, messages} -> reply(messages)
      {:error, reason} -> error(inspect(reason))
    end
  end

  # The three pull modes, each delegating to the SAME `Kazi.Bus` primitives a
  # client used to call directly -- moving assembly server-side moved the
  # caller, not the semantics.
  defp pull(%{"since" => since}, bus_opts) when is_integer(since) and since >= 0,
    do: Bus.read_since(since, bus_opts)

  defp pull(%{"peek" => true}, bus_opts), do: Bus.peek(bus_opts)

  defp pull(_request, bus_opts), do: drain_all(bus_opts, [], @max_batches)

  # L-0040: one `read` is one batch of 100. The daemon is the party that can
  # afford to walk the whole pending set once and aggregate it, so it does.
  defp drain_all(_bus_opts, acc, 0), do: {:ok, flatten(acc)}

  defp drain_all(bus_opts, acc, rounds_left) do
    case Bus.read(bus_opts) do
      {:ok, []} -> {:ok, flatten(acc)}
      {:ok, batch} -> drain_all(bus_opts, [batch | acc], rounds_left - 1)
      {:error, reason} when acc == [] -> {:error, reason}
      # A failure PART-WAY through a drain must not discard the batches
      # already acked -- those messages are consumed and would be lost.
      {:error, _reason} -> {:ok, flatten(acc)}
    end
  end

  defp flatten(acc), do: acc |> Enum.reverse() |> List.flatten()

  defp reply(messages), do: %{"ok" => true, "digest" => Digest.render(messages)}

  # `full` is the ONE mode this socket must never serve: it is unbounded by
  # definition, and `packet: :line` truncates an over-long line SILENTLY
  # (T55.7; Kazi.Daemon.Probe.socket_buffer/0), which would hand a client a
  # short, corrupt reply it could not distinguish from a real one. The client
  # pulls `--full` off the consumer directly. Refusing loudly here keeps a
  # future non-CLI client from quietly receiving a digest when it asked for
  # everything -- assembly moving server-side must not make `full` mean
  # something new.
  defp refuse_full(%{"full" => true}), do: {:error, "full_not_supported_over_control_socket"}
  defp refuse_full(_request), do: :ok

  defp fetch_identity(request, key) do
    case Map.get(request, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "missing_#{key}"}
    end
  end

  defp resolve_connect_opts(opts) do
    case Keyword.get(opts, :connect_opts) do
      %{} = connect_opts -> {:ok, connect_opts}
      _none -> discover(Keyword.get(opts, :nats_name))
    end
  end

  defp discover(nil), do: {:error, "nats_unavailable"}

  # The sibling Kazi.Daemon.Nats may not be answering yet (boot order); a
  # caught exit is a clean error reply, never a crashed control connection.
  defp discover(nats_name) do
    base = %{host: Kazi.Daemon.Nats.host(nats_name), port: Kazi.Daemon.Nats.port(nats_name)}

    case Kazi.Daemon.Nats.token(nats_name) do
      nil -> {:ok, base}
      token -> {:ok, Map.put(base, :auth_token, token)}
    end
  catch
    :exit, _reason -> {:error, "nats_unavailable"}
  end

  defp error(reason), do: %{"ok" => false, "error" => to_string(reason)}
end
