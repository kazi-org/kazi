defmodule Kazi.Bus do
  @moduledoc """
  T51.2 (ADR-0067 decision point 3): the session-bus client -- `post`, `read`,
  `peek`, `who`, `tell` over the daemon-supervised NATS JetStream bus
  (`Kazi.Bus.Provision`).

  Connects LAZILY per call: discovers the daemon's `nats_port` through
  `Kazi.Daemon.Probe.ping/1` (the control-socket handshake T51.1 already
  ships), then opens a short-lived `Gnat` connection for that one call. No
  daemon -> `{:error, :no_daemon}`, never a raised error (the CLI turns this
  into the one-line no-daemon message).

  `opts[:conn]` lets a caller (chiefly tests) supply an already-connected
  `Gnat` pid and skip daemon discovery entirely -- the connection is then the
  caller's to close.

  ## Session identity (T55.5, ADR-0073 decision point 3)

  Every call carries a session id, resolved by `session/1` through the
  EXISTING ADR-0067 point 2 chain (`Kazi.CLI.resolve_session_name/1`):
  an explicit `opts[:session]` (test seam), then `--session-name` /
  `opts[:session_name]`, then `KAZI_SESSION_NAME`, then a harness-provided
  session env var (`CLAUDE_CODE_SESSION_ID`). Only when ALL of those are
  absent does `stable_fallback_id/0` apply -- never the former `os-<pid>`,
  which changed on every CLI invocation and fragmented one session into
  unaddressable ghost presence rows.

  **Stable-fallback mechanism.** The id anchors on the nearest STABLE
  ancestor process: starting from this process's parent, the walk skips
  transient non-interactive shells (a `sh`/`bash`/`zsh`/... invoked with
  `-c`, the wrapper a harness spawns per command and throws away) and stops
  at the first ancestor that isn't one -- the harness process itself, or
  the operator's interactive shell. The id is `s-` plus 12 hex chars of
  `sha256(hostname|anchor-pid|anchor-start-time)`: two CLI invocations
  spawned from the same session context walk to the same anchor and get the
  SAME id, while two genuinely different sessions anchor on different
  processes -- and a recycled pid has a different start time, so pid reuse
  cannot collide either. If `ps` is unusable the last resort is
  `s-pid-<os-pid>` (honest, but only stable within one OS process).

  On top of the id, `name/2` (`kazi bus name <nickname>`) assigns a durable
  human name carried on presence; `tell/3` resolves a recipient as `@<team>`,
  exact session id, then nickname -- an unknown recipient is an error naming
  the live roster, never a silent queue-to-nowhere.

  ADR-0067 guardrail: nothing outside `kazi daemon`/`kazi bus` may call this
  module -- convergence never depends on the bus.
  """

  require Logger

  alias Gnat.Jetstream.API.{Consumer, KV}
  alias Gnat.Jetstream.API.Stream, as: JetStream
  alias Kazi.Bus.{Board, Claims, Liveness, Provision}
  alias Kazi.Daemon.{Probe, Supervisor}

  @max_text_bytes 65_536
  @pull_timeout_ms 2_000
  @pull_batch 100
  @default_watch_timeout_s 300
  @puback_timeout_ms 5_000

  # Bus/JetStream calls must never hang the operator's command (lore L-0035,
  # mirrors Kazi.ReadModel.Guard and Kazi.Bus.Hook's own payload bound).
  # `Gnat.Jetstream.Pager.receive_messages/2` -- which `KV.contents/2`'s
  # roster read (every `who`/`board` call pages through it) drives -- has a
  # bare `receive do ... end` with NO `after` clause. If the expected NATS
  # reply never arrives (a dropped message, a consumer race, a wedged
  # connection), the calling process blocks FOREVER with no escape. `run/3`
  # closes that gap: every `with_conn`-routed call executes in a monitored
  # task with a hard deadline; on timeout the task is killed and the call
  # degrades to `{:error, :bus_unavailable}` -- the same tolerated shape as
  # `:no_daemon` -- instead of hanging past the bound. `watch/1` (designed to
  # block for minutes waiting on new messages) passes its own timeout plus a
  # grace window; every other call gets this short default.
  @default_call_timeout_ms 15_000
  @watch_call_grace_ms 15_000

  # The board's ephemeral fact consumer is deleted the moment its read
  # finishes; this threshold only bounds cleanup if that delete is ever missed
  # (e.g. a crash mid-board), so the server reaps the orphan quickly.
  @board_consumer_ttl_ns 30 * 1_000_000_000

  # T55.7: the control-socket budget for a daemon-assembled `read`. Generous
  # next to `Kazi.Daemon.Probe`'s 2s default because the daemon may walk a deep
  # backlog (several 100-message batches, L-0040) before it has a digest to
  # send. This is the CLI's patience; the ADR-0071 hook's much tighter
  # wall-clock bound is its own (T55.9), passed as `opts[:timeout]`.
  @read_timeout_ms 15_000

  @typedoc "A read/who error surfaced to the CLI verbatim."
  @type error :: :no_daemon | :text_too_large | term()

  @typedoc """
  T55.12: what `tell/3` answers instead of a bare `:ok` -- `:ok` meant QUEUED,
  never SEEN, and a supervisor could not tell the two apart.

    * `:id` -- the message's JetStream stream sequence (the same public id
      T55.1 puts on every digest line), which `status/2` dereferences.
    * `:recipient` -- the RESOLVED target (a nickname resolves to its session
      id), so the sender sees who actually got addressed.
    * `:liveness` -- the recipient's roster liveness at send time (T55.11), or
      `"no-presence"` when the tell landed on a durable inbox whose presence
      row is gone. `"dead-reaping"`/`"no-presence"` are the warning-worthy
      values; the CLI prints a warning and still sends.
  """
  @type receipt :: %{id: pos_integer(), recipient: String.t(), liveness: String.t()}

  @doc """
  Publishes `text` (kind `kind`, optional `opts[:topic]`) to `bus.<scope>.<kind>.<topic|_>`,
  after upserting the caller's presence. `text` over #{@max_text_bytes} bytes
  is rejected CLIENT-SIDE, naming the cap.
  """
  @spec post(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def post(kind, text, opts \\ []) when is_binary(kind) and is_binary(text) do
    with :ok <- check_size(text) do
      with_conn(opts, fn conn ->
        upsert_presence(conn, opts)
        scope = scope(opts)
        topic = opts[:topic] || "_"
        sev = opts[:sev] || "info"
        subject = Enum.join(["bus", scope, kind, topic], ".")

        headers = [
          {"session", session(opts)},
          {"machine", hostname()},
          {"ts", DateTime.to_iso8601(DateTime.utc_now())},
          {"sev", sev}
        ]

        Gnat.pub(conn, subject, text, headers: headers)
      end)
    end
  end

  @doc """
  Publishes `text` directed at `recipient` -- `bus.<scope>.msg.<session>`.

  T55.5 (ADR-0073 decision point 3): `recipient` resolves, in order, as an
  `@<team>` fan-out (verbatim, unchanged from #1069), an exact session id
  present in the roster, then a NICKNAME (`name/2`) looked up against live
  presence. A recipient matching none of those is
  `{:error, {:unknown_recipient, recipient, roster}}` -- naming the live
  roster -- never a silent queue-to-nowhere (the field pain this closes:
  hours of messages directed at a replaced session id nobody could see
  were going unread).

  Delivery does NOT depend on the scopes matching: the recipient's
  `read/1`/`peek/1` also drains a `bus.*.msg.<session>` consumer, so a
  project-scoped tell reaches a machine-scoped reader and vice versa
  (issue #1065).

  ## Delivery visibility (T55.12)

  Answers `{:ok, receipt}` -- see `t:receipt/0`. A bare `:ok` meant QUEUED,
  never SEEN: the field pain this closes is a supervisor who could not
  distinguish delivered-and-ignored from parked-in-a-queue-nobody-drains
  from lost-because-the-session-was-replaced, and coordinated for hours
  against dead session ids whose queues swallowed every message.

  Two mechanisms make the receipt honest:

    * The message is published with a reply subject, so JetStream's PubAck
      returns the stream sequence -- the `:id` `status/2` dereferences. A
      tell that never got a PubAck is an ERROR, not a cheerful `:ok`.
    * The recipient's durable inbox is ensured to EXIST at send time (per
      live member for a team fan-out), so the queued message is immediately
      countable as inbox depth by `who/1` rather than invisible until the
      recipient happens to read. It is the same durable, created with the
      same parameters `read/1` would use -- idempotent, and never a cursor
      the recipient would not otherwise have.
  """
  @spec tell(String.t(), String.t(), keyword()) :: {:ok, receipt()} | {:error, error()}
  def tell(recipient, text, opts \\ []) when is_binary(recipient) and is_binary(text) do
    with :ok <- check_size(text) do
      with_conn(opts, fn conn ->
        upsert_presence(conn, opts)
        {target, liveness} = resolve_recipient!(conn, recipient)
        scope = scope(opts)
        subject = Enum.join(["bus", scope, "msg", target], ".")

        headers = [
          {"session", session(opts)},
          {"machine", hostname()},
          {"ts", DateTime.to_iso8601(DateTime.utc_now())},
          {"sev", opts[:sev] || "info"}
        ]

        ensure_inbox(conn, target)
        id = publish_for_seq!(conn, subject, text, headers)

        {:ok, %{id: id, recipient: target, liveness: liveness}}
      end)
    end
  end

  # T55.12: publish and WAIT for JetStream's PubAck, whose `seq` is the
  # message's public id. `Gnat.pub/4` is fire-and-forget -- it cannot report a
  # sequence, and it cannot report a rejected publish either, which is exactly
  # how a tell could answer `:ok` for a message the stream never stored.
  defp publish_for_seq!(conn, subject, text, headers) do
    case Gnat.request(conn, subject, text,
           headers: headers,
           receive_timeout: @puback_timeout_ms
         ) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"seq" => seq}} when is_integer(seq) -> seq
          {:ok, %{"error" => error}} -> raise_bus_error({:publish_rejected, error})
          _other -> raise_bus_error({:publish_rejected, body})
        end

      {:error, reason} ->
        raise_bus_error({:publish_failed, reason})
    end
  end

  # The durable inbox a tell's target reads from: the per-session directed
  # consumer, or -- for an `@<team>` fan-out -- one per live member, matching
  # `drain/3`'s team durable exactly. Created with the SAME parameters
  # `ensure_consumer/4` uses from the read path, so this only ever
  # pre-creates a cursor the recipient's first read would have created
  # anyway (deliver_policy :all, so nothing is skipped).
  defp ensure_inbox(conn, "@" <> team) do
    stream = Provision.stream_name()

    for member <- team_members(conn, team) do
      ensure_consumer(conn, stream, team_consumer_name(team, member), "bus.*.msg.@#{team}")
    end
  end

  defp ensure_inbox(conn, target) do
    ensure_consumer(
      conn,
      Provision.stream_name(),
      tell_consumer_name(target),
      "bus.*.msg.#{target}"
    )
  end

  # The live roster's members of `team` -- the sessions a fan-out actually
  # reaches. A team is a live membership list, not a static one (#1069), so a
  # member whose presence has aged out is not counted. Reads the roster
  # WITHOUT upserting: a sender must never leave a presence row of its own
  # behind while resolving someone else's team (that is the ghost-row class
  # T55.11 retired).
  defp team_members(conn, team) do
    case roster(conn, []) do
      {:ok, entries} -> for e <- entries, e["team"] == team, do: e["session"]
      {:error, _reason} -> []
    end
  end

  # T55.5 recipient resolution, T55.12 liveness + durable-inbox fallback.
  # `@<team>` passes through verbatim (the team consumers subscribe to
  # `bus.*.msg.@<team>`). Otherwise the roster (the sessions KV bucket) is the
  # authority: an exact session-id match (any row, fresh or stale) wins, then
  # a nickname match against LIVE rows (freshest first, in case a re-bind
  # raced).
  #
  # Returns `{target, liveness}`: liveness rides back to the caller so `tell`
  # can WARN on a recipient that resolved against a `dead-reaping` row.
  # T55.12 deliberately keeps liveness ADVISORY rather than letting it refuse:
  # a row is `dead-reaping` per the LOCAL sweep's verdict, and the operator
  # may legitimately know better (a session mid-restart under the same name).
  # Refusing would trade a silent-send failure for a silent-refusal failure.
  #
  # No roster match falls back to the durable inbox: a session whose presence
  # aged out but whose cursor still exists WILL drain the queue when it
  # returns, so that tell must land. Only a recipient with neither raises
  # `:unknown_recipient` with the live roster, naming who IS addressable.
  defp resolve_recipient!(_conn, "@" <> _rest = team), do: {team, "team"}

  defp resolve_recipient!(conn, recipient) do
    entries =
      case KV.contents(conn, Provision.sessions_bucket()) do
        {:ok, contents} ->
          for {_key, value} <- contents, {:ok, entry} <- [Jason.decode(value)], do: entry

        {:error, reason} ->
          raise_bus_error(reason)
      end

    # filter_fresh/2 takes {entry, verdict} PAIRS since T55.11 (liveness):
    # pair each row with its local verdict -- which also gives tell the same
    # never-hide-a-live-pid semantics as `who` -- and unwrap the survivors.
    # (Union-merge regression pinned by test: plain maps here crashed every
    # non-@ tell with FunctionClauseError.)
    local = hostname()

    annotated = Enum.map(entries, &annotate_age/1)
    started = Liveness.started_map(local_pids(annotated, local))

    pairs = Enum.map(annotated, fn entry -> {entry, local_verdict(entry, local, started)} end)

    live = pairs |> filter_fresh([]) |> Enum.map(fn {entry, _verdict} -> entry end)
    live_ids = MapSet.new(live, & &1["session"])

    exact = Enum.find(pairs, fn {e, _v} -> e["session"] == recipient end)

    named =
      pairs
      |> Enum.filter(fn {e, _v} ->
        MapSet.member?(live_ids, e["session"]) and e["name"] == recipient
      end)
      |> Enum.min_by(fn {e, _v} -> e["age_s"] end, fn -> nil end)

    cond do
      exact -> {recipient, rendered_liveness(exact)}
      named -> {elem(named, 0)["session"], rendered_liveness(named)}
      has_inbox?(conn, recipient) -> {recipient, "no-presence"}
      true -> raise_bus_error({:unknown_recipient, recipient, roster_labels(live)})
    end
  end

  # T55.12: does `recipient` own a durable inbox cursor? True only for a
  # session that has read the bus at least once, or that a previous tell
  # addressed (which itself required a presence row) -- so this can never
  # green-light a typo, only a session whose row aged out from under it.
  defp has_inbox?(conn, recipient) do
    match?(
      {:ok, _info},
      Consumer.info(conn, Provision.stream_name(), tell_consumer_name(recipient))
    )
  end

  # The live roster as one label per session -- `nickname (session-id)` when
  # named, the bare id otherwise -- for the one-line unknown-recipient error.
  defp roster_labels(live) do
    live
    |> Enum.sort_by(fn e -> e["age_s"] end)
    |> Enum.map(fn e ->
      case e["name"] do
        name when is_binary(name) -> "#{name} (#{e["session"]})"
        _unnamed -> e["session"]
      end
    end)
  end

  @doc """
  T55.5 (ADR-0073 decision point 3): assigns `nickname` as the calling
  session's durable name -- carried on presence (every later bus call
  preserves it), rendered by `who/1`, and resolvable by `tell/3`.

  Re-asserting a name RE-BINDS it to the current session: any other presence
  row holding the same name loses it, so a relaunched worker that runs
  `bus name <role>` again becomes addressable under that role immediately
  (and the old row can no longer soak up its messages).

  A nickname that is empty, whitespace-containing, `@`-prefixed (reserved
  for teams), or equal to a DIFFERENT live session's id is rejected
  client-side as `{:error, {:invalid_nickname, nickname, why}}`.
  """
  @spec name(String.t(), keyword()) :: :ok | {:error, error()}
  def name(nickname, opts \\ []) when is_binary(nickname) do
    with :ok <- validate_nickname(nickname) do
      with_conn(opts, fn conn ->
        rebind_name!(conn, nickname, session(opts))
        upsert_presence(conn, Keyword.put(opts, :name, nickname))
        :ok
      end)
    end
  end

  defp validate_nickname(nickname) do
    cond do
      nickname == "" ->
        {:error, {:invalid_nickname, nickname, "a nickname must be non-empty"}}

      String.starts_with?(nickname, "@") ->
        {:error, {:invalid_nickname, nickname, "`@` prefixes team names (`bus join`)"}}

      nickname =~ ~r/\s/ ->
        {:error, {:invalid_nickname, nickname, "a nickname cannot contain whitespace"}}

      true ->
        :ok
    end
  end

  # Rebinding pass: rejects a nickname that shadows ANOTHER session's id
  # (`tell` resolves exact ids first, so such a name could never be reached),
  # then strips the name from every other row holding it -- re-asserting a
  # name moves it to the caller.
  defp rebind_name!(conn, nickname, self_id) do
    case KV.contents(conn, Provision.sessions_bucket()) do
      {:ok, contents} ->
        decoded =
          for {key, value} <- contents, {:ok, entry} <- [Jason.decode(value)], do: {key, entry}

        if Enum.any?(decoded, fn {_k, e} ->
             e["session"] == nickname and e["session"] != self_id
           end) do
          raise_bus_error(
            {:invalid_nickname, nickname,
             "it is another live session's id -- pick a different name"}
          )
        end

        for {key, entry} <- decoded,
            entry["name"] == nickname,
            entry["session"] != self_id do
          KV.put_value(
            conn,
            Provision.sessions_bucket(),
            key,
            Jason.encode!(Map.delete(entry, "name"))
          )
        end

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Pulls all currently-available messages off the caller's durable consumers
  -- the scope consumer (filtered to `opts[:scope]`) plus the session's
  directed-message consumer (`bus.*.msg.<session>`, all scopes; issue
  #1065) -- acks them, dedups the overlap, and returns them structured in
  stream order. A second call with nothing new posted returns `{:ok, []}`
  -- the durable cursors never re-deliver an acked message.

  Every returned message carries its JetStream stream sequence as the
  public `:id` (T55.1, ADR-0072 decision 3) -- the stable identifier a
  digest line or stub names.
  """
  @spec read(keyword()) :: {:ok, [map()]} | {:error, error()}
  def read(opts \\ []), do: consume(opts, ack: true)

  @doc """
  Issue #1059: a NON-DESTRUCTIVE `read` -- pulls the same durable consumer
  `read/1` uses, but NAKs every message it sees instead of acking it, so the
  message is immediately redeliverable. A second `peek/1` sees the same
  messages again; a subsequent `read/1` still consumes (and acks) them
  normally. Mirrors `read/1`'s shape exactly, only the ack behavior differs.
  """
  @spec peek(keyword()) :: {:ok, [map()]} | {:error, error()}
  def peek(opts \\ []), do: consume(opts, ack: false)

  @doc """
  T55.7 (ADR-0072 d5): the DAEMON-ASSEMBLED read -- the one entry point the
  CLI, the `kazi_bus_*` MCP tools, and the ADR-0071 hook all share, so the
  render bound is written once instead of three times.

  Sends `read` over the daemon's control socket and returns what the daemon
  assembled. The client never pulls a consumer and never aggregates: by the
  time this returns, the bytes are already bounded (ADR-0067 point 5, "only a
  server can aggregate before the tokens are spent").

  Returns `{:ok, %{"digest" => digest}}` -- `Kazi.Bus.Digest`'s bounded shape,
  ready for `Digest.to_tty_lines/1` or a `--json` envelope. `opts[:peek]` is
  the non-destructive pull; `opts[:since]` is the cursor-anchored replay.

  `opts[:full]` returns `{:ok, %{"messages" => messages}}` instead, and is the
  one mode that does NOT go through the daemon: it is the documented escape
  (ADR-0072 d1), so there is no digest to assemble, and its size is bounded by
  nothing -- the control socket's line framing must never carry it (see
  `Kazi.Daemon.Probe.socket_buffer/0`). It pulls the same durable consumers
  directly, exactly as it did before assembly moved.

  With no daemon -- the socket missing, stale, or unanswering -- returns
  `{:error, :no_daemon}` exactly as every other bus verb does, on BOTH paths.
  ADR-0067 point 1: bus surfaces degrade to a clean one-line error and
  convergence never depends on the bus.
  """
  @spec read_digest(keyword()) :: {:ok, map()} | {:error, error()}
  def read_digest(opts \\ []) do
    if opts[:full], do: read_full(opts), else: read_assembled(opts)
  end

  defp read_assembled(opts) do
    sock_path = opts[:sock_path] || Supervisor.default_sock_path()

    with :alive <- Probe.probe(sock_path),
         {:ok, reply} <- Probe.request(sock_path, read_request(opts), read_timeout_ms(opts)),
         %{"ok" => true} <- reply do
      {:ok, reply}
    else
      # An `ok: false` reply is the DAEMON refusing the read (a bus that is
      # provisioned but unreachable, say) -- distinct from "no daemon", and
      # surfaced rather than flattened, so the operator sees which it was.
      %{"ok" => false} = reply ->
        {:error, {:bus_read_failed, reply["error"] || "unknown"}}

      # The socket answered but the bytes were not a reply we understand. NOT
      # `:no_daemon` -- there plainly is one -- and saying so would send an
      # operator to debug the wrong thing entirely.
      {:error, %Jason.DecodeError{}} ->
        {:error, {:bus_read_failed, "malformed reply from daemon"}}

      _no_daemon ->
        {:error, :no_daemon}
    end
  end

  # The `--full` escape: the raw set, straight off the durable consumers.
  defp read_full(opts) do
    result =
      cond do
        is_integer(opts[:since]) -> read_since(opts[:since], opts)
        opts[:peek] -> peek(opts)
        true -> read(opts)
      end

    case result do
      {:ok, messages} -> {:ok, %{"messages" => messages}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Identity resolves HERE, on the client, and travels EXPLICITLY: the daemon
  # has no KAZI_SESSION_NAME and its cwd is not the caller's repo, so a daemon
  # left to resolve either would drain the wrong session's inbox.
  defp read_request(opts) do
    %{"op" => "read", "session" => session(opts), "scope" => scope(opts)}
    |> put_unless_nil("peek", opts[:peek])
    |> put_unless_nil("since", opts[:since])
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, _key, false), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # A digest reply is small by construction, but `full` can carry the whole
  # backlog, and a deep drain is several round trips inside the daemon --
  # neither fits Probe's 2s default. `opts[:timeout]` is in SECONDS, matching
  # every other bus verb.
  defp read_timeout_ms(opts) do
    case opts[:timeout] do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _default -> @read_timeout_ms
    end
  end

  @doc """
  T55.7 (T51.4's debugging escape, ADR-0072 d5): `read/1` anchored at a
  cursor -- consumes and returns ONLY messages whose stream sequence is
  strictly greater than `anchor`, NAKing everything at or before it back to
  pending (so a `--since` probe never eats the backlog a plain `read/1` was
  counting on).

  Shares `watch/1`'s `{:since, anchor}` mechanism but NEVER parks: an anchor
  already at the newest sequence returns `{:ok, []}` immediately. That is the
  difference that makes it a read rather than a wait -- `watch --since` asks
  "tell me when", `read --since` asks "what have I missed".
  """
  @spec read_since(non_neg_integer(), keyword()) :: {:ok, [map()]} | {:error, error()}
  def read_since(anchor, opts \\ []) when is_integer(anchor) and anchor >= 0 do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)
      {:ok, drain(conn, opts, {:since, anchor})}
    end)
  end

  # Issue #1065: a `tell` published under a DIFFERENT scope than the reader's
  # (`bus.<project-id>.msg.<session>` against a machine-scoped consumer) was
  # stored in the stream but never delivered -- no error on either side. Every
  # read/peek therefore drains TWO durables: the scope consumer (unchanged),
  # plus a per-session consumer filtered to `bus.*.msg.<session>`, which sees
  # directed messages across ALL scopes. A same-scope tell arrives on both
  # consumers; `dedup_by_stream_seq/1` collapses it to one delivery.
  defp consume(opts, ack: ack?) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)
      {:ok, drain(conn, opts, {:ack, ack?})}
    end)
  end

  # The shared pull path for read/peek/watch: presence is the CALLER's
  # responsibility (watch refreshes it on each wake without re-draining).
  # `mode` is `{:ack, boolean}` (read acks / peek NAKs everything, one batch)
  # or `{:since, anchor}` (T54.9/#1097: consume ONLY messages with
  # `stream_seq > anchor`, NAK the backlog so read/peek still see it).
  defp drain(conn, opts, mode) do
    scope = scope(opts)
    session = session(opts)
    stream = Provision.stream_name()

    scope_consumer = consumer_name(session, scope)
    ensure_consumer(conn, stream, scope_consumer, "bus.#{scope}.>")

    tell_consumer = tell_consumer_name(session)
    ensure_consumer(conn, stream, tell_consumer, "bus.*.msg.#{session}")

    scoped = pull(conn, stream, scope_consumer, session, mode)
    told = pull(conn, stream, tell_consumer, session, mode)

    # Team fan-in (#1069): a joined session also drains directed-at-team
    # messages (`tell @<team>`) across all scopes, one durable per
    # team+session so every member gets its own copy.
    team_msgs =
      case current_team(conn, opts) do
        nil ->
          []

        team ->
          team_consumer = team_consumer_name(team, session)
          ensure_consumer(conn, stream, team_consumer, "bus.*.msg.@#{team}")
          pull(conn, stream, team_consumer, "@" <> team, mode)
      end

    dedup_by_stream_seq(scoped ++ told ++ team_msgs)
  end

  defp pull(conn, stream, consumer_name, session, {:ack, ack?}),
    do: pull_all(conn, stream, consumer_name, session, ack: ack?)

  defp pull(conn, stream, consumer_name, session, {:since, anchor}),
    do: pull_new(conn, stream, consumer_name, session, anchor)

  @doc """
  Blocks until a NEW message arrives for the caller, then consumes and
  returns it/them -- the no-poll-loop alternative to `read/1` (issue #1091).

  `opts[:since]` anchors what counts as new (T54.9, issue #1097):

    * `:now` (the DEFAULT) -- capture the stream's `last_seq` at entry and
      deliver only messages with a stream sequence STRICTLY greater; any
      backlog already pending on the durables (e.g. left un-acked by a prior
      `peek/1`) is NAKed back, staying consumable by `read/1`/`peek/1`, and
      never wakes the watch.
    * an integer sequence -- anchor there precisely: pending messages past
      that sequence return immediately, everything at or before it is
      treated as backlog.
    * `:all` -- the pre-T54.9 behavior: drain first, so anything already
      pending (backlog included) returns immediately.

  While parked it holds ephemeral core-NATS subscriptions on the caller's
  scope, directed, and team subjects as a wake signal, then drains the
  durables again. The `:now` anchor is captured AFTER those subscriptions
  are live (risk R-E54-6), so a message landing in between cannot be lost.
  `opts[:timeout]` is in SECONDS (default #{@default_watch_timeout_s}); on
  expiry returns `{:error, :watch_timeout}` -- always distinguishable from
  an arrival. Presence is re-upserted on entry and on wake, so a watching
  session stays fresh in `who`.
  """
  @spec watch(keyword()) :: {:ok, [map()]} | {:error, error()}
  def watch(opts \\ []) do
    timeout_ms = (opts[:timeout] || @default_watch_timeout_s) * 1_000

    # `watch` is the one bus call designed to block for a long time; its
    # outer bound must cover its own wait, not `run/3`'s short default.
    opts = Keyword.put_new(opts, :call_timeout_ms, timeout_ms + @watch_call_grace_ms)

    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)

      case opts[:since] || :now do
        :all ->
          case drain(conn, opts, {:ack, true}) do
            [] -> await_then_drain(conn, opts, {:ack, true}, timeout_ms)
            messages -> {:ok, messages}
          end

        since ->
          # R-E54-6 ordering: `await_then_drain/4` brings the wake
          # subscriptions up BEFORE `resolve_anchor/2` reads `last_seq`, so
          # a message landing in between is either counted into the anchor
          # (backlog) or already signalled in the mailbox -- never dropped.
          await_then_drain(conn, opts, {:anchor, since}, timeout_ms)
      end
    end)
  end

  defp await_then_drain(conn, opts, mode, timeout_ms) do
    scope = scope(opts)
    session = session(opts)

    subjects =
      ["bus.#{scope}.>", "bus.*.msg.#{session}"] ++
        case current_team(conn, opts) do
          nil -> []
          team -> ["bus.*.msg.@#{team}"]
        end

    sids =
      Enum.map(subjects, fn subject ->
        {:ok, sid} = Gnat.sub(conn, self(), subject)
        sid
      end)

    # The `:now` anchor resolves HERE, after the subscriptions above are
    # live (R-E54-6). `{:anchor, seq}` re-entries pass the resolved integer
    # through unchanged.
    mode =
      case mode do
        {:anchor, since} -> {:since, resolve_anchor(conn, since)}
        other -> other
      end

    # Close the park race: a message that landed between the caller's last
    # drain and the subscriptions coming up would otherwise sit in the
    # durables until the next wake. With the subs already live, this drain's
    # pulls may have core-sub copies in the mailbox -- unsub + flush before
    # returning them.
    case drain(conn, opts, mode) do
      [] ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        result = await_wake(conn, opts, mode, deadline, sids)
        # Defensive double-unsub: the wake path already unsubscribed +
        # flushed before draining; the timeout path lands here with the
        # subscriptions still live.
        Enum.each(sids, fn sid -> Gnat.unsub(conn, sid) end)
        result

      messages ->
        Enum.each(sids, fn sid -> Gnat.unsub(conn, sid) end)
        flush_bus_msgs()
        {:ok, messages}
    end
  end

  defp await_wake(conn, opts, mode, deadline, sids) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :watch_timeout}
    else
      receive do
        {:msg, %{topic: "bus." <> _}} ->
          upsert_presence(conn, opts)
          # The wake message itself arrives via the durables -- the
          # core-NATS subs are only a signal. Unsubscribe and FLUSH their
          # remaining copies before draining: `collect/4`'s receive in the
          # pull path would otherwise swallow a stray core-sub copy (no JS
          # ack subject, so no stream_seq) alongside the pulled one and
          # deliver the same message twice.
          Enum.each(sids, fn sid -> Gnat.unsub(conn, sid) end)
          flush_bus_msgs()

          case drain(conn, opts, mode) do
            [] -> resubscribe_and_wait(conn, opts, mode, deadline)
            messages -> {:ok, messages}
          end

        {:msg, _other} ->
          await_wake(conn, opts, mode, deadline, sids)
      after
        remaining -> {:error, :watch_timeout}
      end
    end
  end

  # An irrelevant wake (another session's message on the scope subject)
  # drained empty after we tore the signal subscriptions down -- set them
  # up again and keep waiting out the same deadline. An anchored mode keeps
  # its already-resolved anchor; it is never re-captured mid-watch.
  defp resubscribe_and_wait(conn, opts, mode, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :watch_timeout}
    else
      await_then_drain(conn, opts, mode, remaining)
    end
  end

  # T54.9 anchor resolution: `:now` is the JetStream stream's current
  # `last_seq`; an explicit integer passes through (also the re-entry path
  # after an irrelevant wake, so the anchor stays fixed for the whole watch).
  defp resolve_anchor(_conn, seq) when is_integer(seq) and seq >= 0, do: seq

  defp resolve_anchor(conn, :now) do
    case JetStream.info(conn, Provision.stream_name()) do
      {:ok, %{state: %{last_seq: seq}}} -> seq
      {:error, reason} -> raise_bus_error(reason)
    end
  end

  defp flush_bus_msgs do
    receive do
      {:msg, %{topic: "bus." <> _}} -> flush_bus_msgs()
    after
      0 -> :ok
    end
  end

  # T55.1 (ADR-0072 decision 3): after deduplication the stream sequence is
  # the message's PUBLIC id -- carried on every returned message (and thus on
  # every digest line and stub), so anything a digest names stays
  # dereferenceable. It was previously stripped here as internal-only.
  defp dedup_by_stream_seq(messages) do
    messages
    |> Enum.uniq_by(fn m -> m.stream_seq || {m.scope, m.kind, m.topic, m.ts, m.text} end)
    |> Enum.sort_by(fn m -> m.stream_seq || 0 end)
    |> Enum.map(fn m -> m |> Map.put(:id, m.stream_seq) |> Map.delete(:stream_seq) end)
  end

  @doc false
  # Exposed for tests only: the durable consumer name a session's `read/1`
  # uses -- lets a test assert on cross-session isolation without duplicating
  # the naming scheme.
  @spec consumer_name_for(String.t(), String.t()) :: String.t()
  def consumer_name_for(session, scope), do: consumer_name(session, scope)

  @doc """
  Lists upserted presence entries from the `kazi_sessions` KV bucket, each
  annotated with `seen_s`/`age_s` (seconds since the row's last heartbeat)
  and `liveness` (T55.11):

    * `"active"` -- the session itself refreshed the row recently.
    * `"idle"` -- the process is alive but quiet; the daemon's presence sweep
      (`Kazi.Daemon.PresenceSweep`) re-heartbeats such rows so they never age
      out, and a TTL-stale row whose pid is verified alive LOCALLY is likewise
      kept and rendered idle (never hidden, never dead).
    * `"dead-reaping"` -- a LOCAL row whose pid is verifiably gone (or reused
      by a different process, per `Kazi.Bus.Liveness`); the sweep removes it
      on its next pass.

  Each row also carries `inbox` (T55.12): how many DIRECTED messages are
  queued and un-read for that session -- its own `tell` inbox plus its team
  fan-out inbox, read from the durable consumers' `num_pending`. A depth that
  climbs while liveness says the session is alive is the roster telling an
  operator their tells are landing but nobody is draining them.

  Filters: `opts[:who_team]` (team membership), `opts[:who_machine]` (exact
  hostname), `opts[:who_project]` (cwd equals the dir or lives under it);
  `opts[:all]` includes TTL-stale rows.
  """
  @spec who(keyword()) :: {:ok, [map()]} | {:error, error()}
  def who(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)

      case roster(conn, opts) do
        {:ok, entries} -> {:ok, Enum.map(entries, &annotate_inbox(conn, &1))}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  T55.4 (ADR-0073 decision point 1): the current-state projection -- the
  last-value `fact` per topic plus the live roster, rendered through
  `Kazi.Bus.Board` into a bounded, JSON-ready map (`kazi schema` shape unchanged
  from a read digest's bounds).

  CURSOR-FREE and idempotent: unlike `read/1`, the board CONSUMES NOTHING. The
  facts come off a throwaway ephemeral consumer with `deliver_policy:
  :last_per_subject` -- entirely separate from the durable read cursors -- so a
  session may board every turn without draining a message a `read` was counting
  on (the `read` ack landmine, ADR-0073). The roster is the same `roster/1`
  `who/1` reads. Presence is re-upserted on entry, so a session that boards
  stays fresh in every other session's board.

  Bounded by ADR-0072's digest rules: an oversize fact body renders as a stub,
  and the fact section is at most `Kazi.Bus.Digest.max_lines/0` lines regardless
  of how many topics exist.
  """
  @spec board(keyword()) :: {:ok, map()} | {:error, error()}
  def board(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)

      case roster(conn, opts) do
        {:ok, entries} ->
          {:ok, attach_claims(Board.render(read_facts(conn, opts), entries), opts)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # ADR-0073 point 2: the ownership section is a DIRECT projection of
  # `refs/claims/*` read at source (`Kazi.Bus.Claims`) -- never routed through
  # the bus, never touched by the daemon. It is read only when a caller asks for
  # it (`opts[:claims]`): the CLI and MCP surfaces do; the pure-projection and
  # NATS-path tests do not, so they never shell out to git. An unreachable
  # remote degrades to `"claims_available" => false` -- one honest line at the
  # renderer, never a stale table.
  defp attach_claims(board, opts) do
    case Keyword.get(opts, :claims, false) do
      false -> board
      nil -> board
      true -> merge_claims(board, Claims.read([]))
      claim_opts when is_list(claim_opts) -> merge_claims(board, Claims.read(claim_opts))
    end
  end

  defp merge_claims(board, {:ok, claims}) do
    board
    |> Map.put("claims", claims)
    |> Map.put("claims_available", true)
    |> Map.put("total_claims", length(claims))
  end

  defp merge_claims(board, {:error, _reason}) do
    board
    |> Map.put("claims", [])
    |> Map.put("claims_available", false)
    |> Map.put("total_claims", 0)
  end

  # ADR-0073 point 1: the board's fact section is the CURRENT value of every
  # fact topic, read without consuming anything. An ephemeral consumer with
  # `deliver_policy: :last_per_subject` delivers exactly the latest message on
  # each `bus.<scope>.fact.<topic>` subject; being ephemeral (deleted right
  # after) and on its OWN cursor, it never disturbs the durable `read`/`peek`
  # consumers. It is created with explicit ack (JetStream rejects a pull
  # consumer with any other ack policy) and unlimited max_ack_pending so a board
  # spanning more than the batch size of topics still drains in full.
  defp read_facts(conn, opts) do
    scope = scope(opts)
    stream = Provision.stream_name()

    consumer = %Consumer{
      stream_name: stream,
      filter_subject: "bus.#{scope}.fact.>",
      deliver_policy: :last_per_subject,
      ack_policy: :explicit,
      replay_policy: :instant,
      inactive_threshold: @board_consumer_ttl_ns,
      max_ack_pending: -1
    }

    case Consumer.create(conn, consumer) do
      {:ok, info} ->
        try do
          pull_facts(conn, stream, info.name, [])
        after
          Consumer.delete(conn, stream, info.name)
        end

      {:error, reason} ->
        raise_bus_error(reason)
    end
  end

  # Walks the ephemeral last-per-subject consumer to exhaustion in full batches
  # (a board with more topics than one batch needs several), acking as it goes
  # so nothing redelivers within the walk -- harmless to durable cursors since
  # this consumer is its own. `dedup_by_stream_seq/1` renames each message's
  # stream sequence to the public `:id` the board's stub/verbatim lines carry.
  defp pull_facts(conn, stream, consumer_name, acc) do
    inbox = "_INBOX.#{Integer.to_string(System.unique_integer([:positive]))}"
    {:ok, sid} = Gnat.sub(conn, self(), inbox)

    :ok =
      Consumer.request_next_message(conn, stream, consumer_name, inbox, nil,
        batch: @pull_batch,
        no_wait: true
      )

    {round, exhausted?} = collect_facts(conn, [], 0)
    Gnat.unsub(conn, sid)
    acc = [round | acc]

    if exhausted? or length(round) < @pull_batch do
      acc |> Enum.reverse() |> List.flatten() |> dedup_by_stream_seq()
    else
      pull_facts(conn, stream, consumer_name, acc)
    end
  end

  defp collect_facts(conn, acc, count) do
    receive do
      {:msg, %{status: status}} when status in ["404", "408", "409"] ->
        {Enum.reverse(acc), true}

      {:msg, %{topic: topic, body: body} = msg} ->
        if msg[:reply_to], do: Gnat.pub(conn, msg.reply_to, "")
        parsed = parse_message(topic, body, msg[:headers], msg[:reply_to])

        if count + 1 == @pull_batch do
          {Enum.reverse([parsed | acc]), false}
        else
          collect_facts(conn, [parsed | acc], count + 1)
        end
    after
      @pull_timeout_ms -> {Enum.reverse(acc), true}
    end
  end

  # The annotated + filtered roster WITHOUT the caller's presence upsert or
  # inbox depth -- the shared read behind `who/1` (which adds both) and the
  # internal resolution paths (`team_members/2`, `status/2`), which must never
  # heartbeat a row of their own just to look someone else up.
  defp roster(conn, opts) do
    case KV.contents(conn, Provision.sessions_bucket()) do
      {:ok, contents} ->
        local = hostname()

        entries =
          contents
          |> Enum.map(fn {_key, value} -> Jason.decode!(value) end)
          |> Enum.map(&annotate_age/1)
          |> then(fn annotated ->
            started = Liveness.started_map(local_pids(annotated, local))
            Enum.map(annotated, fn entry -> {entry, local_verdict(entry, local, started)} end)
          end)
          |> filter_fresh(opts)
          |> Enum.map(&annotate_liveness/1)
          |> filter_team(opts)
          |> filter_machine(opts)
          |> filter_project(opts)
          |> Enum.sort_by(& &1["age_s"])

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # T55.12: the row's un-read DIRECTED depth -- its `tell` inbox plus, when it
  # belongs to a team, that team's fan-out inbox. Broadcast (`post`) traffic on
  # the scope consumer is deliberately NOT counted: "inbox" answers "how many
  # messages addressed to this session are waiting", which is what a tell's
  # sender needs to know. A session with no durable yet has genuinely nothing
  # queued -- every tell ensures its target's inbox exists -- so a missing
  # consumer is an honest 0, not an unknown.
  defp annotate_inbox(conn, entry) do
    stream = Provision.stream_name()
    session = entry["session"]

    consumers =
      [tell_consumer_name(session)] ++
        case entry["team"] do
          team when is_binary(team) -> [team_consumer_name(team, session)]
          _none -> []
        end

    depth = consumers |> Enum.map(&num_pending(conn, stream, &1)) |> Enum.sum()

    Map.put(entry, "inbox", depth)
  end

  defp num_pending(conn, stream, consumer_name) do
    case Consumer.info(conn, stream, consumer_name) do
      {:ok, %{num_pending: pending}} when is_integer(pending) -> pending
      _no_consumer -> 0
    end
  end

  @doc """
  T55.12: the delivery state of the message with public id `id` (the stream
  sequence `tell/3`'s receipt carries) -- the answer to "was it actually
  seen?", read from the RECIPIENT's durable consumer ack state:

    * `"pending"` -- the message is stored and queued, but the recipient has
      not acked it. Either it has not read yet, or it only peeked (a peek NAKs
      and never advances the cursor).
    * `"consumed"` -- the recipient's `read/1` acked it. That means DELIVERED
      AND DRAINED, which is as far as the bus can honestly see: whether the
      session then acted on it is not something an ack can know, and the
      advisory contract (ADR-0067 point 7) means it was never obliged to.

  The verdict is the consumer's ack floor (the sequence below which everything
  is acked) compared against `id`, so it survives the message itself having
  aged out of the consumer's view.

  `recipients` breaks the state out per session, which is what a `tell @<team>`
  fan-out needs: the aggregate `state` is `"consumed"` only once EVERY live
  member acked, so one member draining cannot make a team message look
  universally seen.

  Consumes nothing: it reads consumer info and fetches the message directly by
  sequence, so a `status` check never disturbs the recipient's cursor.
  Errors `{:unknown_message, id}` for an id that is not in the stream (never
  posted, or aged out past the 30-day retention) and `{:not_directed, id,
  kind}` for a broadcast -- a `post` has no one recipient whose ack state
  could answer the question.
  """
  @spec status(pos_integer(), keyword()) :: {:ok, map()} | {:error, error()}
  def status(id, opts \\ []) when is_integer(id) do
    with_conn(opts, fn conn ->
      stream = Provision.stream_name()

      case JetStream.get_message(conn, stream, %{seq: id}) do
        {:ok, message} ->
          {:ok, build_status(conn, stream, id, message)}

        {:error, _reason} ->
          {:error, {:unknown_message, id}}
      end
    end)
  end

  @doc """
  T55.6 (ADR-0072 decision 3): fetch the FULL body of the message with public
  id `id` -- the same JetStream stream sequence a digest line or stub names
  (T55.1). This is the deliberate pull that makes a stub's collapsed body
  addressable again, so the digest's stub-collapsing stays reachable rather
  than a dead end: a session that has decided a stub is worth the context
  spends it here, on purpose.

  Implemented as a direct JetStream stream GET by sequence -- NO consumer is
  involved, so `get` never advances anyone's read cursor. Contrast `read/1`,
  which acks and CONSUMES: a `get` can be spent freely and a later `read/1`
  still delivers that same message normally.

  Returns the message's provenance (`id`, `scope`, `kind`, `topic`, `sev`,
  `session`, `machine`, `ts`, `bytes`) plus its `text` byte-identical to what
  was posted. Errors `{:unknown_message, id}` for an id the stream cannot
  produce (never posted, or aged out of the 30-day retention) -- the same
  one-line error shape `status/2` uses, never a crash.
  """
  @spec get(pos_integer(), keyword()) :: {:ok, map()} | {:error, error()}
  def get(id, opts \\ []) when is_integer(id) do
    with_conn(opts, fn conn ->
      stream = Provision.stream_name()

      case JetStream.get_message(conn, stream, %{seq: id}) do
        {:ok, message} -> {:ok, build_get(id, message)}
        {:error, _reason} -> {:error, {:unknown_message, id}}
      end
    end)
  end

  defp build_get(id, message) do
    ["bus", scope, kind | topic_parts] = String.split(message.subject, ".")
    headers = parse_headers(message.hdrs)
    text = message.data || ""

    %{
      "id" => id,
      "scope" => scope,
      "kind" => kind,
      "topic" => if(topic_parts == [], do: nil, else: Enum.join(topic_parts, ".")),
      "sev" => headers["sev"] || "info",
      "session" => headers["session"],
      "machine" => headers["machine"],
      "ts" => headers["ts"],
      "bytes" => byte_size(text),
      "text" => text
    }
  end

  defp build_status(conn, stream, id, message) do
    case String.split(message.subject, ".") do
      ["bus", _scope, "msg", target] ->
        recipients = status_recipients(conn, stream, id, target)

        %{
          "id" => id,
          "recipient" => target,
          "state" => aggregate_state(recipients),
          "sent_at" => sent_at(message),
          "recipients" => recipients
        }

      ["bus", _scope, kind | _topic] ->
        raise_bus_error({:not_directed, id, kind})

      _other ->
        raise_bus_error({:unknown_message, id})
    end
  end

  # One entry per session whose ack state bears on this message: the single
  # target, or every live member of a team fan-out. A team with no live member
  # left yields `[]` -- and `aggregate_state/1` calls that pending, because
  # nobody has drained it (claiming "consumed" for a message no one received
  # is the exact lie this task exists to kill).
  defp status_recipients(conn, stream, id, "@" <> team) do
    for member <- team_members(conn, team) do
      %{
        "session" => member,
        "state" => consumer_state(conn, stream, team_consumer_name(team, member), id)
      }
    end
  end

  defp status_recipients(conn, stream, id, target) do
    [
      %{
        "session" => target,
        "state" => consumer_state(conn, stream, tell_consumer_name(target), id)
      }
    ]
  end

  defp aggregate_state([]), do: "pending"

  defp aggregate_state(recipients) do
    if Enum.all?(recipients, &(&1["state"] == "consumed")), do: "consumed", else: "pending"
  end

  # The ack floor is the stream sequence below which the consumer has acked
  # everything, so `ack_floor >= id` means this message is acked. A consumer
  # that does not exist has acked nothing -- pending, which is the honest
  # answer for a session that has never drained its inbox.
  defp consumer_state(conn, stream, consumer_name, id) do
    case Consumer.info(conn, stream, consumer_name) do
      {:ok, %{ack_floor: %{stream_seq: floor}}} when is_integer(floor) and floor >= id ->
        "consumed"

      _pending ->
        "pending"
    end
  end

  # The message's send time: its `ts` header (the sender's own stamp, matching
  # every other bus surface), falling back to the stream's store time.
  defp sent_at(message) do
    headers = parse_headers(message.hdrs)

    case headers["ts"] do
      ts when is_binary(ts) -> ts
      _absent -> if message.time, do: DateTime.to_iso8601(message.time), else: nil
    end
  end

  # `Stream.get_message/4` returns headers as the raw NATS/HTTP-style block
  # (`NATS/1.0\r\nkey: value\r\n...`), unlike the pull path's parsed list.
  defp parse_headers(nil), do: %{}

  defp parse_headers(hdrs) when is_binary(hdrs) do
    hdrs
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _no_colon -> acc
      end
    end)
  end

  defp parse_headers(_other), do: %{}

  @doc "The presence TTL in seconds (the `kazi_sessions` bucket's server-side entry TTL) -- `who`'s freshness cutoff and the `who --json` `ttl_s` field derive from it."
  @spec session_ttl_s() :: pos_integer()
  def session_ttl_s, do: div(Provision.session_ttl_ns(), 1_000_000_000)

  defp annotate_age(entry) do
    age_s =
      with ts when is_binary(ts) <- entry["ts"],
           {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
        DateTime.diff(DateTime.utc_now(), dt, :second)
      else
        _other -> nil
      end

    # `seen_s` is the documented spelling (T55.11); `age_s` is kept as an
    # alias so existing consumers of the JSON shape do not break.
    entry
    |> Map.put("age_s", age_s)
    |> Map.put("seen_s", age_s)
  end

  # A pid can only be judged on the machine that recorded it; every other
  # machine's rows are `:remote` -- never guessed about (T55.11).
  defp local_verdict(entry, local, started_map) do
    if entry["machine"] == local, do: Liveness.verdict(entry, started_map), else: :remote
  end

  # The pids this machine may judge -- one batched `ps` covers them all.
  defp local_pids(entries, local) do
    for e <- entries, e["machine"] == local, is_integer(e["pid"]), do: e["pid"]
  end

  # Freshness (the "closed sessions look active" fix): the bucket TTL
  # expires idle entries server-side, but stores provisioned by older
  # daemons may carry a TTL-less bucket until their daemon restarts under
  # the reconciling provision -- so `who` ALSO hides entries older than the
  # TTL client-side unless `opts[:all]`. T55.11 exception: a TTL-stale row
  # whose pid is verified ALIVE locally is never hidden -- alive-but-idle
  # and dead are opposite situations, and hiding conflated them.
  defp filter_fresh(pairs, opts) do
    if opts[:all] do
      pairs
    else
      ttl_s = session_ttl_s()

      Enum.filter(pairs, fn {entry, verdict} ->
        (is_integer(entry["age_s"]) and entry["age_s"] <= ttl_s) or verdict == :alive
      end)
    end
  end

  # The rendered liveness: a locally-verified-dead pid wins (the row is
  # awaiting the sweep's reap); a TTL-stale-but-shown row is at best idle;
  # otherwise the stored value stands (the session's own upsert writes
  # `active`, the daemon sweep's re-heartbeat writes `idle`).
  defp annotate_liveness({entry, verdict}) do
    stale? = not (is_integer(entry["age_s"]) and entry["age_s"] <= session_ttl_s())

    liveness =
      cond do
        verdict == :dead -> "dead-reaping"
        stale? -> "idle"
        true -> entry["liveness"] || "active"
      end

    Map.put(entry, "liveness", liveness)
  end

  # T55.12: the liveness label `tell` reports on its receipt -- the SAME
  # rendering `who` shows, so a warning and the roster can never disagree.
  defp rendered_liveness(pair), do: annotate_liveness(pair)["liveness"]

  defp filter_team(entries, opts) do
    case opts[:who_team] do
      nil -> entries
      team -> Enum.filter(entries, fn e -> e["team"] == team end)
    end
  end

  # T55.11: `who --machine <host>` -- exact hostname match.
  defp filter_machine(entries, opts) do
    case opts[:who_machine] do
      nil -> entries
      machine -> Enum.filter(entries, fn e -> e["machine"] == machine end)
    end
  end

  # T55.11: `who --project <dir>` -- sessions whose cwd IS the dir or lives
  # under it (worktrees checked out inside the dir count).
  defp filter_project(entries, opts) do
    case opts[:who_project] do
      nil ->
        entries

      dir ->
        dir = Path.expand(dir)

        Enum.filter(entries, fn e ->
          case e["cwd"] do
            cwd when is_binary(cwd) -> cwd == dir or String.starts_with?(cwd, dir <> "/")
            _other -> false
          end
        end)
    end
  end

  @doc """
  The current call's resolved session id: `opts[:session]` (explicit
  injection, chiefly tests), else the ADR-0067 point 2 resolution chain via
  `Kazi.CLI.resolve_session_name/1` (`--session-name` / `opts[:session_name]`
  > `KAZI_SESSION_NAME` > `CLAUDE_CODE_SESSION_ID`), else
  `stable_fallback_id/0` (T55.5) -- never the former per-process `os-<pid>`,
  which fragmented a nameless session into a new ghost presence row on every
  CLI invocation.
  """
  @spec session(keyword()) :: String.t()
  def session(opts) do
    opts[:session] ||
      Kazi.CLI.resolve_session_name(session_name: opts[:session_name]) ||
      stable_fallback_id()
  end

  # ---------------------------------------------------------------------------
  # Stable fallback identity (T55.5, ADR-0073 decision point 3). See the
  # moduledoc's "Session identity" section for the mechanism rationale.
  # ---------------------------------------------------------------------------

  @transient_shells ~w(sh bash zsh dash ksh fish ash csh tcsh)
  @fallback_walk_limit 10

  @doc """
  The session id used when the whole name-resolution chain comes up empty:
  `s-` + 12 hex chars of `sha256(hostname|anchor-pid|anchor-start-time)`,
  where the ANCHOR is the nearest stable ancestor process -- the walk starts
  at this process's parent and skips transient `-c` shells (the throwaway
  wrapper a harness spawns per command), stopping at the first ancestor that
  isn't one (the harness itself, or the operator's interactive shell).

  Two CLI invocations from the same session context therefore hash the same
  anchor and get the SAME id (no ghost presence rows), while two genuinely
  different sessions anchor on different processes -- and because the
  anchor's START TIME is hashed in, a recycled pid cannot collide either.
  Memoized per OS process (`:persistent_term`): the ancestry of a running
  process never changes, so one `ps` walk per process is enough.

  Last resort (no usable `ps` on PATH): `s-pid-<os-pid>`, which is only
  stable within a single OS process -- honest degradation, documented here.
  """
  @spec stable_fallback_id() :: String.t()
  def stable_fallback_id do
    case :persistent_term.get({__MODULE__, :fallback_id}, nil) do
      nil ->
        id = compute_fallback_id()
        :persistent_term.put({__MODULE__, :fallback_id}, id)
        id

      id ->
        id
    end
  end

  defp compute_fallback_id do
    case ps_int(os_pid(), "ppid=") do
      {:ok, ppid} -> fallback_id_from(ppid)
      :error -> "s-pid-#{os_pid()}"
    end
  end

  @doc false
  # Exposed for tests: the fallback id anchored by walking UP from
  # `candidate_pid` -- in real use the calling process's parent. Two distinct
  # transient shells spawned by the same stable process must yield the same
  # id; two distinct stable processes must not.
  @spec fallback_id_from(pos_integer()) :: String.t()
  def fallback_id_from(candidate_pid) do
    case walk_to_anchor(candidate_pid, @fallback_walk_limit) do
      {pid, start} -> derive_fallback_id(hostname(), pid, start)
      :error -> "s-pid-#{os_pid()}"
    end
  end

  @doc false
  # T55.14 (#1164): the pid + start time the presence row records -- the STABLE
  # session anchor, computed with the SAME ancestor walk that backs the session
  # id (`walk_to_anchor/2`), starting from this process's parent. Never the
  # ephemeral CLI invocation's own pid, which exits before the daemon sweep
  # can see it. Falls back to this process's own identity only when `ps` can't
  # resolve an ancestor (last-resort honest degradation).
  @spec anchor_identity() :: {pos_integer(), String.t() | nil}
  def anchor_identity do
    case ps_int(os_pid(), "ppid=") do
      {:ok, ppid} -> anchor_identity_from(ppid)
      :error -> {os_pid(), Liveness.proc_started_at(os_pid())}
    end
  end

  @doc false
  # Exposed for tests: the anchor identity walked UP from `candidate_pid` -- in
  # real use this process's parent. Mirrors `fallback_id_from/1` (the session-id
  # side) but returns the pid + start-time PAIR the presence row stores instead
  # of the hashed id, reusing the identical `walk_to_anchor/2`. A short-lived
  # writer therefore records its still-alive ancestor, not its own about-to-exit
  # pid.
  @spec anchor_identity_from(pos_integer()) :: {pos_integer(), String.t() | nil}
  def anchor_identity_from(candidate_pid) do
    case walk_to_anchor(candidate_pid, @fallback_walk_limit) do
      {pid, start} -> {pid, start}
      :error -> {os_pid(), Liveness.proc_started_at(os_pid())}
    end
  end

  @doc false
  # The pure derivation, exposed for tests: deterministic in its inputs; any
  # differing input (host, pid, or start time) yields a different id.
  @spec derive_fallback_id(String.t(), pos_integer(), String.t()) :: String.t()
  def derive_fallback_id(host, anchor_pid, anchor_start) do
    hash = :crypto.hash(:sha256, "#{host}|#{anchor_pid}|#{anchor_start}")
    "s-" <> (hash |> Base.encode16(case: :lower) |> binary_part(0, 12))
  end

  defp walk_to_anchor(pid, hops) when is_integer(pid) and pid > 1 do
    case ps_field(pid, "command=") do
      {:ok, cmd} ->
        if hops > 0 and transient_shell?(cmd) do
          case ps_int(pid, "ppid=") do
            {:ok, ppid} when ppid > 1 -> walk_to_anchor(ppid, hops - 1)
            _other -> anchor(pid)
          end
        else
          anchor(pid)
        end

      :error ->
        :error
    end
  end

  defp walk_to_anchor(_pid, _hops), do: :error

  defp anchor(pid) do
    case ps_field(pid, "lstart=") do
      {:ok, start} -> {pid, start}
      :error -> {pid, "unknown-start"}
    end
  end

  # A transient shell is `sh`/`bash`/`zsh`/... running with `-c` (possibly
  # combined, e.g. `-lc`) -- the per-command wrapper a harness spawns and
  # discards. An interactive shell (`-zsh`, `bash` with no `-c`) is NOT
  # transient: it IS the session anchor for an operator typing commands.
  defp transient_shell?(cmd) do
    case String.split(String.trim(cmd), ~r/\s+/, parts: 2) do
      [exe, args] ->
        Path.basename(exe) in @transient_shells and args =~ ~r/(^|\s)-[A-Za-z]*c(\s|$)/

      _no_args ->
        false
    end
  end

  defp ps_int(pid, field) do
    with {:ok, out} <- ps_field(pid, field),
         {int, _rest} <- Integer.parse(out) do
      {:ok, int}
    else
      _other -> :error
    end
  end

  defp ps_field(pid, field) do
    case System.cmd("ps", ["-o", field, "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          value -> {:ok, value}
        end

      _other ->
        :error
    end
  rescue
    # `ps` missing from PATH entirely (System.cmd raises :enoent).
    ErlangError -> :error
  end

  @doc "`machine` (default) or the current repo's canonical toplevel path, slugged."
  @spec scope(keyword()) :: String.t()
  def scope(opts) do
    case opts[:scope] || "machine" do
      "project" -> project_id()
      other -> other
    end
  end

  @doc "Slugs `git rev-parse --show-toplevel` into a bus-subject-safe project id. `unknown` outside a git worktree."
  @spec project_id() :: String.t()
  def project_id do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> slug()
      _other -> "unknown"
    end
  end

  # ---------------------------------------------------------------------------
  # Connection: discover the daemon (unless `opts[:conn]` was given) and run
  # `fun` against it, closing only a connection we opened ourselves.
  # ---------------------------------------------------------------------------
  defp with_conn(opts, fun) do
    timeout_ms = opts[:call_timeout_ms] || @default_call_timeout_ms

    case opts[:conn] do
      nil -> with_discovered_conn(opts, fun, timeout_ms)
      conn -> run(conn, fun, timeout_ms)
    end
  end

  defp with_discovered_conn(opts, fun, timeout_ms) do
    sock_path = opts[:sock_path] || Supervisor.default_sock_path()

    with :alive <- Probe.probe(sock_path),
         {:ok, %{"nats_port" => port} = pong} when is_integer(port) <- Probe.ping(sock_path),
         {:ok, conn} <- Gnat.start_link(discovered_connect_opts(pong, port)) do
      try do
        run(conn, fun, timeout_ms)
      after
        if Process.alive?(conn), do: Gnat.stop(conn)
      end
    else
      _other -> {:error, :no_daemon}
    end
  end

  @doc """
  The nats connect opts a bus CLIENT uses, from the daemon control handshake
  (issue #1101). The client dials the daemon's CONFIGURED nats host -- the
  connect-mode remote host, not a hardcoded `127.0.0.1` -- so a cross-machine
  `--nats-host` bus works from the CLI with no SSH tunnel; and it presents the
  shared `nats_token` (handshake value, else `KAZI_NATS_TOKEN`) so a
  token-protected bus no longer rejects the client with an Authorization
  Violation. Falls back to today's local, unauthenticated shape when the
  handshake omits them (an older daemon). Public for unit testing.
  """
  @spec discovered_connect_opts(map(), pos_integer()) :: map()
  def discovered_connect_opts(pong, port) do
    host =
      case pong["nats_host"] do
        h when is_binary(h) and h != "" -> h
        _ -> "127.0.0.1"
      end

    base = %{host: host, port: port}

    case pong["nats_token"] || System.get_env("KAZI_NATS_TOKEN") do
      t when is_binary(t) and t != "" -> Map.put(base, :auth_token, t)
      _ -> base
    end
  end

  @doc false
  # Test seam (mirrors `Kazi.ReadModel.Guard.run/3`): the bounded-call
  # regression test calls this directly with a short timeout; production
  # always arrives here through `with_conn/2`.
  #
  # Runs `fun.(conn)` in a monitored task with a hard deadline of
  # `timeout_ms`. On timeout (or a crash) the task is killed and this
  # degrades to `{:error, :bus_unavailable}` instead of blocking past the
  # bound -- see the moduledoc-adjacent comment above `@default_call_timeout_ms`
  # for why this exists.
  @spec run(Gnat.t(), (Gnat.t() -> term()), timeout()) :: term()
  def run(conn, fun, timeout_ms \\ @default_call_timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {__MODULE__, :ok, fun.(conn)}
        catch
          {:bus_error, reason} -> {__MODULE__, :error, reason}
        end
      end)

    result =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {__MODULE__, :ok, value}} -> value
        {:ok, {__MODULE__, :error, reason}} -> {:error, reason}
        {:exit, reason} -> unavailable(reason)
        nil -> unavailable({:timeout, timeout_ms})
      end

    # `Task.async/1` links the task; flush its `{:EXIT, ...}` here so a
    # trapping caller's mailbox never sees it (mirrors Guard.run/3).
    receive do
      {:EXIT, pid, _reason} when pid == task.pid -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp unavailable(reason) do
    Logger.warning(fn -> "bus call unavailable (#{inspect(reason)}); degrading" end)
    {:error, :bus_unavailable}
  end

  defp raise_bus_error(reason), do: throw({:bus_error, reason})

  defp check_size(text) do
    if byte_size(text) > @max_text_bytes do
      {:error, {:text_too_large, @max_text_bytes}}
    else
      :ok
    end
  end

  @doc """
  Registers the caller under a named team (#1069): presence gains a
  `team` field that every later bus call preserves, `who/1` can filter on
  it, and `tell "@<team>"` messages reach the session via `read`/`peek`/
  `watch`. Idempotent; joining a different team moves the session.
  """
  @spec join(String.t(), keyword()) :: :ok | {:error, error()}
  def join(team, opts \\ []) when is_binary(team) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, Keyword.put(opts, :team, team))
      :ok
    end)
  end

  @doc "Clears the caller's team membership (#1069). Presence itself remains until its TTL lapses."
  @spec leave(keyword()) :: :ok | {:error, error()}
  def leave(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, Keyword.put(opts, :team, :none))
      :ok
    end)
  end

  # The caller's current team: an explicit opts[:team] wins (a join/leave in
  # flight), else whatever the presence entry carries.
  defp current_team(conn, opts) do
    case opts[:team] do
      :none -> nil
      team when is_binary(team) -> team
      nil -> stored_team(conn, opts)
    end
  end

  defp stored_team(conn, opts) do
    case stored_entry(conn, opts)["team"] do
      team when is_binary(team) -> team
      _other -> nil
    end
  end

  # The caller's currently-stored presence entry, `%{}` when absent/corrupt --
  # the single fetch both the team and name (T55.5) preservation rules read.
  defp stored_entry(conn, opts) do
    case KV.get_value(conn, Provision.sessions_bucket(), sanitize(session(opts))) do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, entry} when is_map(entry) -> entry
          _other -> %{}
        end

      _missing ->
        %{}
    end
  end

  defp upsert_presence(conn, opts) do
    stored = stored_entry(conn, opts)

    # `team` refresh rule: an explicit :team option sets (binary) or clears
    # (:none) membership; otherwise the previously stored team is PRESERVED
    # -- without this, any read/post after a join silently dropped the
    # membership on rewrite.
    team =
      case opts[:team] do
        :none -> nil
        team when is_binary(team) -> team
        nil -> stored["team"]
      end

    # `name` refresh rule (T55.5): `name/2` sets it via :name; every other
    # bus call preserves the stored one, so a nickname survives across calls
    # exactly like team membership does.
    name =
      case opts[:name] do
        name when is_binary(name) -> name
        nil -> stored["name"]
      end

    # T55.11: pid AND process start time -- a pid alone is reusable, so the
    # daemon's presence sweep matches both before claiming the session is
    # alive (or reaping it). `liveness` is "active" on the session's OWN
    # writes; the sweep's re-heartbeats rewrite it to "idle".
    #
    # T55.14 (#1164): the recorded pid is the STABLE session anchor's, NOT this
    # ephemeral CLI invocation's own (`os_pid/0`). A one-shot `bus post`/`who`/
    # `tell` exits milliseconds after writing its row, so recording its own pid
    # meant the sweep always found it gone and reaped every live session as
    # `dead-reaping` (`idle` was unreachable). `anchor_identity/0` reuses the
    # SAME nearest-stable-ancestor walk that backs the session id, so the pid
    # is a long-lived ancestor still present when the sweep runs.
    {anchor_pid, anchor_started_at} = anchor_identity()

    entry = %{
      "session" => session(opts),
      "machine" => hostname(),
      "pid" => anchor_pid,
      "started_at" => anchor_started_at,
      "liveness" => "active",
      "cwd" => File.cwd!(),
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    }

    entry = if team, do: Map.put(entry, "team", team), else: entry
    entry = if is_binary(name), do: Map.put(entry, "name", name), else: entry

    KV.put_value(conn, Provision.sessions_bucket(), sanitize(session(opts)), Jason.encode!(entry))
  end

  defp ensure_consumer(conn, stream, consumer_name, filter_subject) do
    consumer = %Consumer{
      stream_name: stream,
      durable_name: consumer_name,
      filter_subject: filter_subject,
      ack_policy: :explicit,
      # T54.9 fix (verification gate): pull_pending defers acks for the whole
      # walk, so the server default max_ack_pending (1000) would stall the
      # walk -- and starve the strictly-new message behind a >1000 backlog --
      # once that many deliveries are in flight. Unlimited is safe here: the
      # walk is bounded by the stream itself and NAKs everything back.
      max_ack_pending: -1
    }

    case Consumer.create(conn, consumer) do
      {:ok, _info} -> :ok
      {:error, %{"description" => "consumer name already in use" <> _}} -> :ok
      {:error, %{"err_code" => 10_013}} -> :ok
      {:error, reason} -> raise_bus_error(reason)
    end
  end

  defp pull_all(conn, stream, consumer_name, session, ack: ack?) do
    inbox = "_INBOX.#{Integer.to_string(System.unique_integer([:positive]))}"
    {:ok, sid} = Gnat.sub(conn, self(), inbox)

    :ok =
      Consumer.request_next_message(conn, stream, consumer_name, inbox, nil,
        batch: @pull_batch,
        no_wait: true
      )

    messages = collect(conn, session, ack?, [])
    Gnat.unsub(conn, sid)
    messages
  end

  # T54.9 (#1097): the anchored pull behind `watch/1`'s default. Pulls the
  # consumer's ENTIRE pending set (looping full batches) WITHOUT acking,
  # then acks only messages past `anchor` (they are consumed and returned)
  # and NAKs the rest back to pending -- `peek/1`'s mechanism -- so backlog
  # a prior peek left un-acked stays consumable by `read`/`peek` and never
  # satisfies a watch.
  defp pull_new(conn, stream, consumer_name, session, anchor) do
    inbox = "_INBOX.#{Integer.to_string(System.unique_integer([:positive]))}"
    {:ok, sid} = Gnat.sub(conn, self(), inbox)
    pulled = pull_pending(conn, stream, consumer_name, inbox, [])
    Gnat.unsub(conn, sid)

    {new, backlog} =
      Enum.split_with(pulled, fn m -> is_integer(m.stream_seq) and m.stream_seq > anchor end)

    Enum.each(backlog, fn m -> Gnat.pub(conn, m.reply_to, "-NAK") end)
    Enum.each(new, fn m -> Gnat.pub(conn, m.reply_to, "") end)

    new
    |> Enum.filter(&visible_to?(&1, session))
    |> Enum.map(&Map.delete(&1, :reply_to))
  end

  # Deferred-ack batch loop: unacked deliveries are in flight (not
  # redelivered until ack_wait), so successive full batches walk the whole
  # pending set even when it exceeds one batch -- a NAK-as-we-go loop would
  # re-pull the same first batch forever.
  defp pull_pending(conn, stream, consumer_name, inbox, acc) do
    :ok =
      Consumer.request_next_message(conn, stream, consumer_name, inbox, nil,
        batch: @pull_batch,
        no_wait: true
      )

    {round, exhausted?} = collect_unacked([], 0)
    # Prepend-and-reverse: `acc ++ round` copied the growing accumulator on
    # every batch (O(N^2) across a deep backlog; verification-gate finding).
    acc = [round | acc]

    if exhausted? or length(round) < @pull_batch do
      acc |> Enum.reverse() |> List.flatten()
    else
      pull_pending(conn, stream, consumer_name, inbox, acc)
    end
  end

  # Like `collect/4` but WITHOUT acking, and SELECTIVE: only JS pull
  # deliveries (they carry a `$JS.ACK...` reply subject) are received.
  # Stray core-NATS wake copies (no reply_to) stay in the mailbox for
  # `await_wake/5` -- receiving them here would eat the wake signal for a
  # message whose durable copy this pull round already missed.
  defp collect_unacked(acc, count) do
    receive do
      {:msg, %{status: status}} when status in ["404", "408", "409"] ->
        {Enum.reverse(acc), true}

      {:msg, %{topic: topic, body: body, reply_to: reply_to} = msg}
      when is_binary(reply_to) ->
        parsed =
          topic
          |> parse_message(body, msg[:headers], reply_to)
          |> Map.put(:reply_to, reply_to)

        if count + 1 == @pull_batch do
          {Enum.reverse([parsed | acc]), false}
        else
          collect_unacked([parsed | acc], count + 1)
        end
    after
      @pull_timeout_ms -> {Enum.reverse(acc), true}
    end
  end

  defp collect(conn, session, ack?, acc) do
    receive do
      {:msg, %{status: status}} when status in ["404", "408"] ->
        Enum.reverse(acc)

      {:msg, %{topic: topic, body: body} = msg} ->
        if msg[:reply_to] do
          if ack?,
            do: Gnat.pub(conn, msg.reply_to, ""),
            else: Gnat.pub(conn, msg.reply_to, "-NAK")
        end

        parsed = parse_message(topic, body, msg[:headers], msg[:reply_to])

        if visible_to?(parsed, session) do
          collect(conn, session, ack?, [parsed | acc])
        else
          collect(conn, session, ack?, acc)
        end
    after
      @pull_timeout_ms -> Enum.reverse(acc)
    end
  end

  defp parse_message(topic, body, headers, reply_to) do
    ["bus", scope, kind | topic_parts] = String.split(topic, ".")
    header_map = for {k, v} <- headers || [], into: %{}, do: {k, v}

    %{
      scope: scope,
      kind: kind,
      topic: if(topic_parts == [], do: nil, else: Enum.join(topic_parts, ".")),
      text: body,
      session: header_map["session"],
      machine: header_map["machine"],
      ts: header_map["ts"],
      sev: header_map["sev"] || "info",
      # The JetStream stream sequence from the ack subject: the dedup key
      # across the two consumers, and -- once dedup renames it to `:id`
      # (T55.1, ADR-0072) -- the message's public identifier.
      stream_seq: stream_seq(reply_to)
    }
  end

  # `$JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<ts>.<pending>`,
  # or the v2 form with `<domain>.<account-hash>` prepended after "ACK".
  defp stream_seq(nil), do: nil

  defp stream_seq(reply_to) do
    case String.split(reply_to, ".") do
      ["$JS", "ACK", _stream, _consumer, _delivered, sseq, _cseq, _ts, _pending] ->
        String.to_integer(sseq)

      ["$JS", "ACK", _domain, _acchash, _stream, _consumer, _delivered, sseq | _rest] ->
        String.to_integer(sseq)

      _other ->
        nil
    end
  end

  defp tell_consumer_name(session), do: "kztell_" <> sanitize(session)

  defp team_consumer_name(team, session),
    do: "kzteam_" <> sanitize(team) <> "_" <> sanitize(session)

  defp visible_to?(%{kind: "msg", topic: topic}, session), do: topic == session
  defp visible_to?(_msg, _session), do: true

  defp consumer_name(session, scope), do: "kzread_" <> sanitize(scope) <> "_" <> sanitize(session)

  defp sanitize(str), do: String.replace(str, ~r/[^a-zA-Z0-9_-]/, "_")

  defp slug(str), do: str |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _other -> "unknown"
    end
  end

  defp os_pid, do: :os.getpid() |> to_string() |> String.to_integer()
end
