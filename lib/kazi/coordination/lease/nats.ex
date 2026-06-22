defmodule Kazi.Coordination.Lease.Nats do
  @moduledoc """
  The cross-node `Kazi.Coordination.Lease` backend, backed by a **NATS JetStream
  Key/Value bucket** (T3.1b, ADR-0004; UC-013).

  Where `Kazi.Coordination.Lease.Memory` arbitrates leases inside one BEAM node,
  this backend arbitrates them *across* nodes: many kazi instances on different
  machines acquire the same resource key through one JetStream KV bucket, so
  disjoint lease-sets run concurrently while overlapping ones serialize — the same
  decision (ADR-0006) the in-memory default makes locally, lifted to a cluster.

  It satisfies the **exact same** narrow contract as the in-memory default and is
  exercised by the **same** shared conformance suite
  (`Kazi.Coordination.LeaseContract`). The mapping from the contract onto
  JetStream KV is:

    * a lease key `k` is the KV subject `$KV.<bucket>.<k>`; the stored value is the
      JSON `{"holder": ..., "expires_at_ms": ...}`;
    * the **revision** is the underlying stream **sequence** of the key's last
      message — monotonic and server-assigned, exactly the CAS token the contract
      needs;
    * **compare-and-set** is the server-enforced `Nats-Expected-Last-Subject-Sequence`
      publish header: a write lands only if the key's current sequence is the one
      we expect, so two nodes racing to acquire a free key cannot both win — the
      loser gets a *wrong last sequence* PubAck and is reported `{:error, :held}`.

  ## Why the value carries an absolute expiry (and not just bucket max-age)

  TTL is the **injected** clock (`Kazi.Coordination.Lease.now_ms/1`), not NATS's
  wall clock: the stored value carries an absolute `expires_at_ms`, and the
  free/held decision is a pure comparison against the `:now_ms` the caller supplies
  (`Kazi.Coordination.Lease.expired?/2`) — identical to the in-memory backend. This
  is what lets the shared conformance suite drive a *virtual* clock against a real
  NATS server and still get deterministic TTL boundaries.

  The KV bucket's `max_age` (configured from `ttl_ms` at bucket creation, see
  `ensure_bucket/2`) is a *defense-in-depth* garbage collector for a crashed
  holder that never releases — it is not what the contract's expiry depends on. A
  lease's logical liveness is always the stored `expires_at_ms` versus the injected
  clock.

  ## CAS semantics (mirrors `Kazi.Coordination.Lease.Memory`)

    * **acquire** — reads the key's current message; if the key is free *at
      `now_ms`* (no message, a tombstoned key, or a stored lease whose
      `expires_at_ms` has passed) or already held by the *same* holder, it CAS-writes
      a new value expecting the key's current sequence. The PubAck's new sequence is
      the lease's revision. A *different, unexpired* holder ⇒ `{:error, :held}`; a
      lost CAS race (another node wrote first) ⇒ `{:error, :held}`.
    * **renew** — CAS-writes expecting the held lease's `revision`; if the key has
      moved on (sequence advanced, re-acquired, expired, or released) ⇒
      `{:error, :not_held}`.
    * **release** — if the held lease is still current, tombstones the key (a `DEL`
      marker) expecting its `revision`; idempotent — a stale or already-free
      release is a silent `:ok`.

  ## Configuration

  A backend instance is identified per call by `opts`:

    * `:conn` — a running `Gnat` connection (pid or registered name); **required**.
    * `:bucket` — the KV bucket name; **required**. `ensure_bucket/2` creates it
      idempotently.

  The injected clock (`:now_ms` / `:now_fn`) rides in the same `opts`, exactly as
  for the in-memory backend, so the conformance suite wires this backend by
  swapping `backend:` and providing a `:conn` + a fresh `:bucket` per test.
  """

  @behaviour Kazi.Coordination.Lease

  alias Gnat.Jetstream.API.{KV, Stream}
  alias Kazi.Coordination.Lease

  @subject_prefix "$KV."

  # JetStream's "wrong last sequence" PubAck error code: the CAS check failed
  # because the key's current sequence was not the one we expected.
  @wrong_last_sequence 10_071

  @typedoc """
  The resolved per-call config: a Gnat connection, a KV bucket name, and the
  original `opts` (so the injected clock is reachable for expiry decisions).
  """
  @type config :: %{conn: Gnat.t(), bucket: binary(), opts: keyword()}

  @doc """
  Ensures the KV bucket named `bucket` exists, creating it idempotently.

  `ttl_ms` configures the bucket's `max_age` as a defense-in-depth GC for crashed
  holders (a never-released lease ages out of the store); logical expiry is still
  the stored `expires_at_ms` against the injected clock, so the conformance suite's
  virtual TTL does not depend on this. Call once before using a fresh bucket
  (acquire does not create the bucket — that is an operator/setup concern).

  Returns `:ok` whether the bucket was created or already existed.
  """
  @spec ensure_bucket(keyword(), Lease.ttl_ms()) :: :ok | {:error, term()}
  def ensure_bucket(opts, ttl_ms) when is_list(opts) and is_integer(ttl_ms) and ttl_ms > 0 do
    %{conn: conn, bucket: bucket} = config(opts)
    # max_age is in nanoseconds; give crashed holders a generous window beyond the
    # logical TTL so a live, repeatedly-renewed lease is never GC'd out from under
    # its holder. Logical expiry remains the stored expires_at_ms.
    max_age_ns = ttl_ms * 1_000 * 1_000 * 10

    case KV.create_bucket(conn, bucket, ttl: max_age_ns) do
      {:ok, _info} -> :ok
      # A bucket that already exists is reported as a stream-name conflict; that is
      # the idempotent success path for "ensure".
      {:error, %{"err_code" => 10_058}} -> :ok
      {:error, %{"description" => "stream name already in use" <> _}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Lease
  def acquire(key, holder, ttl_ms, opts)
      when is_binary(key) and is_binary(holder) and is_integer(ttl_ms) and ttl_ms > 0 do
    cfg = config(opts)
    now = Lease.now_ms(opts)
    expires_at = now + ttl_ms

    case read_entry(cfg, key) do
      # Free at `now` (no entry, tombstoned, or expired) — CAS-write expecting the
      # key's current sequence (0 when there has never been a message).
      {:free, expected_seq} ->
        cas_put(cfg, key, holder, expires_at, expected_seq, :held)

      # Already held by us — refresh, CAS-writing at the current sequence.
      {:held, %Lease{holder: ^holder}, seq} ->
        cas_put(cfg, key, holder, expires_at, seq, :held)

      # A different, unexpired holder owns it.
      {:held, %Lease{}, _seq} ->
        {:error, :held}
    end
  end

  @impl Lease
  def renew(%Lease{key: key, holder: holder, revision: revision}, ttl_ms, opts)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    cfg = config(opts)
    now = Lease.now_ms(opts)
    expires_at = now + ttl_ms

    case read_entry(cfg, key) do
      # Still the current, unexpired lease we hold (sequence == our revision, same
      # holder) — CAS-extend at that sequence.
      {:held, %Lease{holder: ^holder}, ^revision} ->
        cas_put(cfg, key, holder, expires_at, revision, :not_held)

      # Superseded: sequence advanced, re-acquired by another, expired, or released.
      _other ->
        {:error, :not_held}
    end
  end

  @impl Lease
  def release(%Lease{key: key, holder: holder, revision: revision}, opts) do
    cfg = config(opts)

    case read_entry(cfg, key) do
      # We are the current holder at our revision — tombstone the key, expecting
      # that sequence so a concurrent re-acquire is not clobbered. Best-effort: a
      # lost CAS race means someone already moved the key on, and release is
      # idempotent and total, so any outcome is reported `:ok`.
      {:held, %Lease{holder: ^holder}, ^revision} ->
        _ = cas_delete(cfg, key, revision)
        :ok

      # Already free, expired, or superseded — releasing is a no-op.
      _other ->
        :ok
    end
  end

  @impl Lease
  def peek(key, opts) when is_binary(key) do
    cfg = config(opts)

    case read_entry(cfg, key) do
      {:held, %Lease{} = lease, _seq} -> {:ok, lease}
      {:free, _seq} -> :free
    end
  end

  # Read the key's current KV entry and classify it against the injected clock.
  #
  # Returns:
  #   * `{:free, expected_seq}` — the key is logically free: no message yet
  #     (`expected_seq == 0`), a tombstone, or a stored lease that has expired. The
  #     `expected_seq` is the sequence a CAS acquire must expect.
  #   * `{:held, %Lease{}, seq}` — an unexpired lease holds the key at stream
  #     sequence `seq` (the lease's revision).
  @spec read_entry(config(), Lease.key()) ::
          {:free, non_neg_integer()} | {:held, Lease.t(), Lease.revision()}
  defp read_entry(%{conn: conn, bucket: bucket} = cfg, key) do
    now = cfg_now(cfg)

    case Stream.get_message(conn, KV.stream_name(bucket), %{last_by_subj: subject(bucket, key)}) do
      {:ok, %{seq: seq, data: data, hdrs: hdrs}} ->
        cond do
          # A tombstone (DEL/PURGE marker) means the key is free; the next writer
          # must still expect the marker's sequence.
          tombstone?(hdrs) ->
            {:free, seq}

          true ->
            classify_value(data, seq, key, now)
        end

      # No message for the subject yet — the key has never been written.
      {:error, %{"code" => 404}} ->
        {:free, 0}

      {:error, %{"err_code" => 10_037}} ->
        {:free, 0}

      {:error, _reason} ->
        # Treat an unreadable subject as free at sequence 0; a subsequent CAS at 0
        # will fail safely if the key in fact exists, never granting a false lease.
        {:free, 0}
    end
  end

  # Decode a stored lease value and decide free/held purely against the injected
  # clock (never NATS wall time), so virtual-clock TTL is deterministic.
  @spec classify_value(binary() | nil, Lease.revision(), Lease.key(), non_neg_integer()) ::
          {:free, non_neg_integer()} | {:held, Lease.t(), Lease.revision()}
  defp classify_value(data, seq, key, now) do
    case decode_lease(data, key, seq) do
      {:ok, lease} ->
        if Lease.expired?(lease, now), do: {:free, seq}, else: {:held, lease, seq}

      :error ->
        {:free, seq}
    end
  end

  # CAS-write a fresh lease value expecting the key's current sequence. On success
  # the PubAck's new sequence is the lease's revision; a wrong-last-sequence PubAck
  # (another writer raced) yields `error_tag` (`:held` for acquire, `:not_held` for
  # renew).
  @spec cas_put(
          config(),
          Lease.key(),
          Lease.holder(),
          non_neg_integer(),
          non_neg_integer(),
          :held | :not_held
        ) :: {:ok, Lease.t()} | {:error, :held | :not_held}
  defp cas_put(%{conn: conn, bucket: bucket}, key, holder, expires_at, expected_seq, error_tag) do
    body = encode_lease(holder, expires_at)
    headers = [{"Nats-Expected-Last-Subject-Sequence", Integer.to_string(expected_seq)}]

    case publish(conn, subject(bucket, key), body, headers) do
      {:ok, new_seq} ->
        {:ok, %Lease{key: key, holder: holder, revision: new_seq, expires_at_ms: expires_at}}

      {:error, :cas_failed} ->
        {:error, error_tag}

      {:error, _reason} ->
        {:error, error_tag}
    end
  end

  # Tombstone the key (a KV `DEL` marker) expecting its current sequence, so a
  # concurrent re-acquire is not clobbered. Best-effort: release is idempotent and
  # total, so any failure is swallowed by the caller.
  @spec cas_delete(config(), Lease.key(), non_neg_integer()) :: :ok | {:error, term()}
  defp cas_delete(%{conn: conn, bucket: bucket}, key, expected_seq) do
    headers = [
      {"KV-Operation", "DEL"},
      {"Nats-Expected-Last-Subject-Sequence", Integer.to_string(expected_seq)}
    ]

    case publish(conn, subject(bucket, key), "", headers) do
      {:ok, _seq} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Publish to a KV subject and parse the JetStream PubAck. A successful ack is
  # `{"stream": ..., "seq": N}` (N is the new revision); a CAS failure is
  # `{"error": {"err_code": 10071, ...}}`.
  @spec publish(Gnat.t(), binary(), binary(), Gnat.headers()) ::
          {:ok, non_neg_integer()} | {:error, :cas_failed | term()}
  defp publish(conn, subject, body, headers) do
    case Gnat.request(conn, subject, body, headers: headers) do
      {:ok, %{body: ack_body}} -> parse_pub_ack(ack_body)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_pub_ack(binary()) :: {:ok, non_neg_integer()} | {:error, :cas_failed | term()}
  defp parse_pub_ack(ack_body) do
    case Jason.decode(ack_body) do
      {:ok, %{"seq" => seq}} when is_integer(seq) ->
        {:ok, seq}

      {:ok, %{"error" => %{"err_code" => @wrong_last_sequence}}} ->
        {:error, :cas_failed}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:error, {:unexpected_ack, other}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec encode_lease(Lease.holder(), non_neg_integer()) :: binary()
  defp encode_lease(holder, expires_at_ms) do
    Jason.encode!(%{"holder" => holder, "expires_at_ms" => expires_at_ms})
  end

  @spec decode_lease(binary() | nil, Lease.key(), Lease.revision()) :: {:ok, Lease.t()} | :error
  defp decode_lease(data, key, seq) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"holder" => holder, "expires_at_ms" => expires_at_ms}}
      when is_binary(holder) and is_integer(expires_at_ms) ->
        {:ok, %Lease{key: key, holder: holder, revision: seq, expires_at_ms: expires_at_ms}}

      _ ->
        :error
    end
  end

  defp decode_lease(_data, _key, _seq), do: :error

  # A KV tombstone is signalled by a `KV-Operation: DEL` or `PURGE` header. The
  # raw header block is a binary `NATS/1.0\r\nKv-Operation: DEL\r\n...`; match
  # case-insensitively on the operation marker.
  @spec tombstone?(binary() | nil) :: boolean()
  defp tombstone?(hdrs) when is_binary(hdrs) do
    down = String.downcase(hdrs)
    String.contains?(down, "kv-operation: del") or String.contains?(down, "kv-operation: purge")
  end

  defp tombstone?(_hdrs), do: false

  @spec subject(binary(), Lease.key()) :: binary()
  defp subject(bucket, key), do: @subject_prefix <> bucket <> "." <> key

  # Resolve and validate the per-call config. Both :conn and :bucket are required:
  # a backend is an instance addressed by its connection + bucket, never a global.
  @spec config(keyword()) :: config()
  defp config(opts) do
    conn =
      case Keyword.fetch(opts, :conn) do
        {:ok, conn} when is_pid(conn) or is_atom(conn) ->
          conn

        _ ->
          raise ArgumentError, "#{inspect(__MODULE__)} requires a :conn (Gnat connection) in opts"
      end

    bucket =
      case Keyword.fetch(opts, :bucket) do
        {:ok, bucket} when is_binary(bucket) -> bucket
        _ -> raise ArgumentError, "#{inspect(__MODULE__)} requires a :bucket name in opts"
      end

    %{conn: conn, bucket: bucket, opts: opts}
  end

  # The injected clock for a resolved config (carries the original opts so expiry
  # honours :now_ms / :now_fn).
  @spec cfg_now(map()) :: non_neg_integer()
  defp cfg_now(%{opts: opts}), do: Lease.now_ms(opts)
end
