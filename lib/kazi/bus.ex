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
  alias Kazi.Bus.Provision
  alias Kazi.Daemon.{Probe, Supervisor}

  @max_text_bytes 1024
  @pull_timeout_ms 2_000

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

  @doc "Publishes `text` directed at `session` -- `bus.<scope>.msg.<session>`."
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
  Pulls all currently-available messages off the caller's durable consumer
  (named after the sanitized session id, filtered to `opts[:scope]`), acks
  them, and returns them structured. A second call with nothing new posted
  returns `{:ok, []}` -- the durable cursor never re-delivers an acked
  message.
  """
  @spec read(keyword()) :: {:ok, [map()]} | {:error, error()}
  def read(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)
      scope = scope(opts)
      session = session(opts)
      stream = Provision.stream_name()
      consumer_name = consumer_name(session, scope)

      ensure_consumer(conn, stream, consumer_name, scope)
      {:ok, pull_all(conn, stream, consumer_name, session, ack: true)}
    end)
  end

  @doc """
  Issue #1059: a NON-DESTRUCTIVE `read` -- pulls the same durable consumer
  `read/1` uses, but NAKs every message it sees instead of acking it, so the
  message is immediately redeliverable. A second `peek/1` sees the same
  messages again; a subsequent `read/1` still consumes (and acks) them
  normally. Mirrors `read/1`'s shape exactly, only the ack behavior differs.
  """
  @spec peek(keyword()) :: {:ok, [map()]} | {:error, error()}
  def peek(opts \\ []) do
    with_conn(opts, fn conn ->
      upsert_presence(conn, opts)
      scope = scope(opts)
      session = session(opts)
      stream = Provision.stream_name()
      consumer_name = consumer_name(session, scope)

      ensure_consumer(conn, stream, consumer_name, scope)
      {:ok, pull_all(conn, stream, consumer_name, session, ack: false)}
    end)
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
          {:ok, Enum.map(contents, fn {_key, value} -> Jason.decode!(value) end)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
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
         {:ok, %{"nats_port" => port}} when is_integer(port) <- Probe.ping(sock_path),
         {:ok, conn} <- Gnat.start_link(%{host: "127.0.0.1", port: port}) do
      try do
        run(conn, fun)
      after
        if Process.alive?(conn), do: Gnat.stop(conn)
      end
    else
      _other -> {:error, :no_daemon}
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

  defp upsert_presence(conn, opts) do
    entry = %{
      "session" => session(opts),
      "pid" => os_pid(),
      "cwd" => File.cwd!(),
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    }

    KV.put_value(conn, Provision.sessions_bucket(), sanitize(session(opts)), Jason.encode!(entry))
  end

  defp ensure_consumer(conn, stream, consumer_name, scope) do
    consumer = %Consumer{
      stream_name: stream,
      durable_name: consumer_name,
      filter_subject: "bus.#{scope}.>",
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
        batch: 100,
        no_wait: true
      )

    messages = collect(conn, session, ack?, [])
    Gnat.unsub(conn, sid)
    messages
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

        parsed = parse_message(topic, body, msg[:headers])

        if visible_to?(parsed, session) do
          collect(conn, session, ack?, [parsed | acc])
        else
          collect(conn, session, ack?, acc)
        end
    after
      @pull_timeout_ms -> Enum.reverse(acc)
    end
  end

  defp parse_message(topic, body, headers) do
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
      sev: header_map["sev"] || "info"
    }
  end

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
