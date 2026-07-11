defmodule Kazi.Bus.Provision do
  @moduledoc """
  T51.2 (ADR-0067 decision point 2): boot provisioning for the session bus's
  JetStream backend -- the `KAZI_BUS` stream (subjects `bus.>`, 30-day
  max_age, 128 KiB max message) and the `kazi_sessions` KV bucket (600s
  TTL). Called ONCE from `Kazi.Daemon.start/1` after the supervised
  `nats-server` accepts a `Gnat` connection.

  Provisioning RECONCILES, not just creates: an already-existing stream or
  bucket gets a config update to the current desired settings. Create-only
  provisioning pinned whatever config the store was first provisioned with
  -- daemons carried forward a TTL-less sessions bucket (closed sessions
  looked active in `bus who` forever) and the original 1024-byte/24h stream
  limits regardless of upgrades.
  """

  alias Gnat.Jetstream.API.{KV, Stream}

  @stream_name "KAZI_BUS"
  @sessions_bucket "kazi_sessions"
  @max_age_ns 30 * 24 * 60 * 60 * 1_000_000_000
  @max_msg_size 131_072
  @session_ttl_ns 600 * 1_000_000_000
  @two_minutes_ns 2 * 60 * 1_000_000_000

  @doc "The sessions bucket's entry TTL in nanoseconds -- `who` freshness derives from this."
  @spec session_ttl_ns() :: pos_integer()
  def session_ttl_ns, do: @session_ttl_ns

  @doc "The stream name bus clients publish/consume against."
  @spec stream_name() :: String.t()
  def stream_name, do: @stream_name

  @doc "The KV bucket name `who()` and presence upserts use."
  @spec sessions_bucket() :: String.t()
  def sessions_bucket, do: @sessions_bucket

  @doc """
  Connects to `opts[:host]`/`opts[:port]` (optionally authenticating with
  `opts[:auth_token]`, the ADR-0067 cross-machine shared token) and
  provisions the stream + bucket. Returns `:ok` (already-exists included) or
  `{:error, reason}`.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.fetch!(opts, :port)
    conn_opts = connect_opts(host, port, Keyword.get(opts, :auth_token))

    with {:ok, conn} <- Gnat.start_link(conn_opts) do
      try do
        provision(conn)
      after
        if Process.alive?(conn), do: Gnat.stop(conn)
      end
    end
  end

  @doc "Provisions against an ALREADY-connected `conn` (used by tests that manage their own connection)."
  @spec provision(Gnat.t()) :: :ok | {:error, term()}
  def provision(conn) do
    with :ok <- ensure_stream(conn),
         :ok <- ensure_sessions_bucket(conn) do
      :ok
    end
  end

  defp connect_opts(host, port, nil), do: %{host: host, port: port}
  defp connect_opts(host, port, token), do: %{host: host, port: port, auth_token: token}

  defp ensure_stream(conn) do
    stream = %Stream{
      name: @stream_name,
      subjects: ["bus.>"],
      max_age: @max_age_ns,
      max_msg_size: @max_msg_size,
      storage: :file
    }

    case Stream.create(conn, stream) do
      {:ok, _info} ->
        :ok

      {:error, %{"err_code" => 10_058}} ->
        reconcile_stream(conn, stream)

      {:error, %{"description" => "stream name already in use" <> _}} ->
        reconcile_stream(conn, stream)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_stream(conn, stream) do
    case Stream.update(conn, stream) do
      {:ok, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_sessions_bucket(conn) do
    case KV.create_bucket(conn, @sessions_bucket, ttl: @session_ttl_ns) do
      {:ok, _info} ->
        :ok

      {:error, %{"err_code" => 10_058}} ->
        reconcile_sessions_bucket(conn)

      {:error, %{"description" => "stream name already in use" <> _}} ->
        reconcile_sessions_bucket(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A KV bucket is a `KV_<name>` stream under the hood; updating its TTL is a
  # stream-config update mirroring `KV.create_bucket/3`'s settings exactly
  # (NATS rejects the stream as a KV store otherwise).
  defp reconcile_sessions_bucket(conn) do
    stream = %Stream{
      name: "KV_" <> @sessions_bucket,
      subjects: ["$KV." <> @sessions_bucket <> ".>"],
      max_msgs_per_subject: 1,
      discard: :new,
      deny_delete: true,
      allow_rollup_hdrs: true,
      max_age: @session_ttl_ns,
      max_bytes: -1,
      max_msg_size: -1,
      num_replicas: 1,
      storage: :file,
      duplicate_window: min(@session_ttl_ns, @two_minutes_ns)
    }

    case Stream.update(conn, stream) do
      {:ok, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
