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

  alias Gnat.Jetstream.API.{Consumer, KV}
  alias Gnat.Jetstream.API.Stream, as: JetStream
  alias Kazi.Bus.{Liveness, Provision}
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
  """
  @spec tell(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def tell(recipient, text, opts \\ []) when is_binary(recipient) and is_binary(text) do
    with :ok <- check_size(text) do
      with_conn(opts, fn conn ->
        upsert_presence(conn, opts)
        target = resolve_recipient!(conn, recipient)
        scope = scope(opts)
        subject = Enum.join(["bus", scope, "msg", target], ".")

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

  # T55.5 recipient resolution. `@<team>` passes through verbatim (the team
  # consumers subscribe to `bus.*.msg.@<team>`). Otherwise the roster (the
  # sessions KV bucket) is the authority: an exact session-id match (any row,
  # fresh or stale) wins, then a nickname match against LIVE rows (freshest
  # first, in case a re-bind raced). No match raises `:unknown_recipient`
  # with the live roster, so the error names who IS addressable.
  defp resolve_recipient!(_conn, "@" <> _rest = team), do: team

  defp resolve_recipient!(conn, recipient) do
    entries =
      case KV.contents(conn, Provision.sessions_bucket()) do
        {:ok, contents} ->
          for {_key, value} <- contents, {:ok, entry} <- [Jason.decode(value)], do: entry

        {:error, reason} ->
          raise_bus_error(reason)
      end

    live = entries |> Enum.map(&annotate_age/1) |> filter_fresh([])

    named =
      live
      |> Enum.filter(fn e -> e["name"] == recipient end)
      |> Enum.min_by(fn e -> e["age_s"] end, fn -> nil end)

    cond do
      Enum.any?(entries, fn e -> e["session"] == recipient end) -> recipient
      named -> named["session"]
      true -> raise_bus_error({:unknown_recipient, recipient, roster_labels(live)})
    end
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

  Filters: `opts[:who_team]` (team membership), `opts[:who_machine]` (exact
  hostname), `opts[:who_project]` (cwd equals the dir or lives under it);
  `opts[:all]` includes TTL-stale rows.
  """
  @spec who(keyword()) :: {:ok, [map()]} | {:error, error()}
  def who(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)

      case KV.contents(conn, Provision.sessions_bucket()) do
        {:ok, contents} ->
          local = hostname()

          entries =
            contents
            |> Enum.map(fn {_key, value} -> Jason.decode!(value) end)
            |> Enum.map(&annotate_age/1)
            |> Enum.map(fn entry -> {entry, local_verdict(entry, local)} end)
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
    end)
  end

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
  defp local_verdict(entry, local) do
    if entry["machine"] == local, do: Liveness.verdict(entry), else: :remote
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
    entry = %{
      "session" => session(opts),
      "machine" => hostname(),
      "pid" => os_pid(),
      "started_at" => Liveness.proc_started_at(os_pid()),
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
