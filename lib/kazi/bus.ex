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

  ADR-0067 guardrail: nothing outside `kazi daemon`/`kazi bus` may call this
  module -- convergence never depends on the bus.
  """

  alias Gnat.Jetstream.API.{Consumer, KV}
  alias Gnat.Jetstream.API.Stream, as: JetStream
  alias Kazi.Bus.Provision
  alias Kazi.Daemon.{Probe, Supervisor}

  @max_text_bytes 65_536
  @pull_timeout_ms 2_000
  @pull_batch 100
  @default_watch_timeout_s 300

  @typedoc "A read/who error surfaced to the CLI verbatim."
  @type error :: :no_daemon | :text_too_large | term()

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
  Publishes `text` directed at `session` -- `bus.<scope>.msg.<session>`.

  Delivery does NOT depend on the scopes matching: the recipient's
  `read/1`/`peek/1` also drains a `bus.*.msg.<session>` consumer, so a
  project-scoped tell reaches a machine-scoped reader and vice versa
  (issue #1065).
  """
  @spec tell(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def tell(session, text, opts \\ []) when is_binary(session) and is_binary(text) do
    with :ok <- check_size(text) do
      with_conn(opts, fn conn ->
        upsert_presence(conn, opts)
        scope = scope(opts)
        subject = Enum.join(["bus", scope, "msg", session], ".")

        headers = [
          {"session", session(opts)},
          {"machine", hostname()},
          {"ts", DateTime.to_iso8601(DateTime.utc_now())},
          {"sev", opts[:sev] || "info"}
        ]

        Gnat.pub(conn, subject, text, headers: headers)
      end)
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

  @doc "Lists upserted presence entries from the `kazi_sessions` KV bucket."
  @spec who(keyword()) :: {:ok, [map()]} | {:error, error()}
  def who(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)

      case KV.contents(conn, Provision.sessions_bucket()) do
        {:ok, contents} ->
          entries =
            contents
            |> Enum.map(fn {_key, value} -> Jason.decode!(value) end)
            |> Enum.map(&annotate_age/1)
            |> filter_fresh(opts)
            |> filter_team(opts)
            |> Enum.sort_by(& &1["age_s"])

          {:ok, entries}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp annotate_age(entry) do
    age_s =
      with ts when is_binary(ts) <- entry["ts"],
           {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
        DateTime.diff(DateTime.utc_now(), dt, :second)
      else
        _other -> nil
      end

    Map.put(entry, "age_s", age_s)
  end

  # Freshness (the "closed sessions look active" fix): the bucket TTL
  # expires idle entries server-side, but stores provisioned by older
  # daemons may carry a TTL-less bucket until their daemon restarts under
  # the reconciling provision -- so `who` ALSO hides entries older than the
  # TTL client-side unless `opts[:all]`.
  defp filter_fresh(entries, opts) do
    if opts[:all] do
      entries
    else
      ttl_s = div(Provision.session_ttl_ns(), 1_000_000_000)
      Enum.filter(entries, fn e -> is_integer(e["age_s"]) and e["age_s"] <= ttl_s end)
    end
  end

  defp filter_team(entries, opts) do
    case opts[:who_team] do
      nil -> entries
      team -> Enum.filter(entries, fn e -> e["team"] == team end)
    end
  end

  @doc "The current call's resolved session id -- delegates to `Kazi.CLI.resolve_session_name/1`, falling back to an os-pid identity when nothing resolves."
  @spec session(keyword()) :: String.t()
  def session(opts) do
    opts[:session] || Kazi.CLI.resolve_session_name(session_name: opts[:session]) ||
      Kazi.CLI.resolve_session_name([]) || "os-#{os_pid()}"
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
    case opts[:conn] do
      nil -> with_discovered_conn(opts, fun)
      conn -> run(conn, fun)
    end
  end

  defp with_discovered_conn(opts, fun) do
    sock_path = opts[:sock_path] || Supervisor.default_sock_path()

    with :alive <- Probe.probe(sock_path),
         {:ok, %{"nats_port" => port} = pong} when is_integer(port) <- Probe.ping(sock_path),
         {:ok, conn} <- Gnat.start_link(discovered_connect_opts(pong, port)) do
      try do
        run(conn, fun)
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

  defp run(conn, fun) do
    fun.(conn)
  catch
    {:bus_error, reason} -> {:error, reason}
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
    case KV.get_value(conn, Provision.sessions_bucket(), sanitize(session(opts))) do
      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{"team" => team}} when is_binary(team) -> team
          _other -> nil
        end

      _missing ->
        nil
    end
  end

  defp upsert_presence(conn, opts) do
    # `team` refresh rule: an explicit :team option sets (binary) or clears
    # (:none) membership; otherwise the previously stored team is PRESERVED
    # -- without this, any read/post after a join silently dropped the
    # membership on rewrite.
    team =
      case opts[:team] do
        :none -> nil
        team when is_binary(team) -> team
        nil -> stored_team(conn, opts)
      end

    entry = %{
      "session" => session(opts),
      "machine" => hostname(),
      "pid" => os_pid(),
      "cwd" => File.cwd!(),
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    }

    entry = if team, do: Map.put(entry, "team", team), else: entry

    KV.put_value(conn, Provision.sessions_bucket(), sanitize(session(opts)), Jason.encode!(entry))
  end

  defp ensure_consumer(conn, stream, consumer_name, filter_subject) do
    consumer = %Consumer{
      stream_name: stream,
      durable_name: consumer_name,
      filter_subject: filter_subject,
      ack_policy: :explicit
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
    acc = acc ++ round

    if exhausted? or length(round) < @pull_batch do
      acc
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
      {:msg, %{status: status}} when status in ["404", "408"] ->
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
