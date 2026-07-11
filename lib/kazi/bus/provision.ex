defmodule Kazi.Bus.Provision do
  @moduledoc """
  T51.2 (ADR-0067 decision point 2): boot provisioning for the session bus's
  JetStream backend -- the `KAZI_BUS` stream (subjects `bus.>`, 24h max_age,
  1024-byte max message) and the `kazi_sessions` KV bucket (600s TTL). Called
  ONCE from `Kazi.Daemon.start/1` after the supervised `nats-server` accepts a
  `Gnat` connection; idempotent (already-exists is `:ok`), so a later daemon
  restart against the same JetStream store is a no-op.
  """

  alias Gnat.Jetstream.API.{KV, Stream}

  @stream_name "KAZI_BUS"
  @sessions_bucket "kazi_sessions"
  @max_age_ns 24 * 60 * 60 * 1_000_000_000
  @max_msg_size 1024
  @session_ttl_ns 600 * 1_000_000_000

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
      {:ok, _info} -> :ok
      {:error, %{"err_code" => 10_058}} -> :ok
      {:error, %{"description" => "stream name already in use" <> _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_sessions_bucket(conn) do
    case KV.create_bucket(conn, @sessions_bucket, ttl: @session_ttl_ns) do
      {:ok, _info} -> :ok
      {:error, %{"err_code" => 10_058}} -> :ok
      {:error, %{"description" => "stream name already in use" <> _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
