defmodule Kazi.ReadModel.Writer do
  @moduledoc """
  T52.1 (ADR-0068): the single client-side write-router seam for the read-model.

  Every read-model write entry point routes through `write/2` so there is ONE
  place that decides *who holds the pen* (ADR-0068 decision 1): when the machine's
  daemon is running, writes belong to it (the daemon is the single writer, one
  process on one schema version — the structural fix for the #1019 mixed-migration
  contention class); with no daemon, writes go straight to `Kazi.Repo`, exactly as
  they do today (ADR-0068 decision 5, "no daemon, no change").

  ## What this task lands (and deliberately does not)

  This is the seam and the presence decision only. It moves NO call site yet, so
  behavior is unchanged and every existing read-model test stays green. The
  daemon-side `write` op and a serializing socket client are later E52 tasks; until
  a caller supplies a `:remote` writer, the alive branch falls back to the direct
  `Kazi.Repo` write, so a running daemon never silently drops a write while the
  socket path is still being built. The seam is what ships now; the routing target
  is swapped in additively later (ADR-0068 decision 3, a versioned additive API).

  ## Usage

      Writer.write(fn -> Repo.insert!(changeset) end)

  `write/2` runs `direct` (a zero-arity closure performing today's exact `Repo`
  write) when no daemon is present, and the `:remote` writer when one is. `:remote`
  defaults to `direct`.

  ## Options

    * `:remote`    — a zero-arity closure invoked instead of `direct` when the
      daemon is `:alive` (the socket-client path a later task supplies). Defaults
      to `direct`.
    * `:sock_path` — the daemon control socket to probe. Defaults to
      `Kazi.Daemon.Supervisor.default_sock_path/0`.
    * `:probe`     — a 1-arity presence probe `(sock_path -> :alive | :dead |
      :missing)`. Defaults to `&Kazi.Daemon.Probe.probe/1`. Injectable for tests.
    * `:ttl_ms`    — how long a presence decision is memoized per process before
      the socket is re-probed. Defaults to `#{__MODULE__}` module default.

  ## Memoized presence (per process, short TTL)

  A busy run issues many writes; `stat`-ing the socket on every one would be waste.
  The presence decision is cached in the process dictionary keyed by socket path
  with a short TTL, so a burst of writes probes at most once per window. The cache
  is per process — it never leaks a stale "alive" across an unrelated caller — and
  a probe after the TTL expires picks up a daemon that started or stopped meanwhile.
  """

  import Ecto.Query, only: [where: 2]

  alias Kazi.Daemon.{Probe, Supervisor}
  alias Kazi.Repo

  # Short enough that a daemon starting/stopping mid-run is noticed within a
  # second; long enough that a tight write loop probes the socket at most once.
  @default_ttl_ms 1_000

  @typedoc "A zero-arity closure performing a read-model write and returning its result."
  @type writer :: (-> term())

  @doc """
  Route a read-model write through the single-writer seam.

  `direct` is today's exact `Kazi.Repo` write, run as-is when no daemon owns the
  file. When a daemon is `:alive`, the `:remote` writer runs instead (defaulting to
  `direct` until the socket-client path is wired). Returns whatever the chosen
  writer returns.
  """
  @spec write(writer(), keyword()) :: term()
  def write(direct, opts \\ []) when is_function(direct, 0) do
    remote = Keyword.get(opts, :remote, direct)

    case daemon_status(opts) do
      :alive -> remote.()
      _absent -> direct.()
    end
  end

  # ===========================================================================
  # T52.5 (ADR-0068 decision 1): the typed write helpers every read-model write
  # entry point now routes through, instead of calling `Kazi.Repo` directly.
  #
  # Each helper builds today's exact `Repo` call as the `direct` closure AND an
  # opaque write plan (the T52.3 wire format) as the `:remote` closure, then hands
  # both to `write/2` so the SAME memoized presence decision picks between them.
  # With no daemon, the direct closure runs and behavior is byte-identical to
  # before. With a daemon, the plan crosses the control socket, the single writer
  # applies it, and the helper RECONSTRUCTS the caller-visible return so a call
  # site's `{:ok, struct}` / `{:error, changeset}` / count contract is preserved
  # (see the "Return-value reconstruction" note in `docs/session-bus.md`).
  # ===========================================================================

  @doc """
  Routes `Repo.insert(changeset, insert_opts)`.

  Remote: an invalid changeset short-circuits to `{:error, changeset}` with NO
  socket round-trip (mirroring `Repo.insert`, which never touches the DB for an
  invalid changeset). A valid one ships an `insert` plan carrying the changeset's
  cast params and the encodable upsert `opts` (`on_conflict`/`conflict_target`).
  On success the persisted row is RE-READ by its `conflict_target` (so an upsert
  return reflects the true stored row); a plain insert with no conflict target
  returns `Ecto.Changeset.apply_changes/1` (DB-autogenerated `id`/timestamps are
  not reflected — callers needing them re-read).
  """
  @spec insert(Ecto.Changeset.t(), keyword(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Ecto.Changeset{} = changeset, insert_opts \\ [], writer_opts \\ []) do
    write(
      fn -> Repo.insert(changeset, insert_opts) end,
      Keyword.put(writer_opts, :remote, fn ->
        remote_insert(changeset, insert_opts, writer_opts)
      end)
    )
  end

  @doc "Bang variant of `insert/3`; raises on `{:error, changeset}` like `Repo.insert!/2`."
  @spec insert!(Ecto.Changeset.t(), keyword(), keyword()) :: Ecto.Schema.t()
  def insert!(%Ecto.Changeset{} = changeset, insert_opts \\ [], writer_opts \\ []) do
    case insert(changeset, insert_opts, writer_opts) do
      {:ok, struct} -> struct
      {:error, changeset} -> raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  @doc """
  Routes `Repo.update(changeset)`.

  Remote: an invalid changeset short-circuits to `{:error, changeset}`. A valid
  one ships an `update_all` plan keyed on the row's primary key with the
  changeset's `changes` as `set:`, and returns `apply_changes/1` (the loaded row
  with the changes applied — a faithful reconstruction, since the base row was
  already read before the update).
  """
  @spec update(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset, writer_opts \\ []) do
    write(
      fn -> Repo.update(changeset) end,
      Keyword.put(writer_opts, :remote, fn -> remote_update(changeset, writer_opts) end)
    )
  end

  @doc """
  Routes `Repo.insert_or_update(changeset)`, dispatching on the changeset's data
  state exactly as `Repo` does: a loaded row updates, an unloaded one inserts.
  """
  @spec insert_or_update(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert_or_update(%Ecto.Changeset{} = changeset, writer_opts \\ []) do
    case changeset.data.__meta__.state do
      :loaded -> update(changeset, writer_opts)
      _built -> insert(changeset, [], writer_opts)
    end
  end

  @doc """
  Routes `Repo.delete_all(from x in schema, where: ^filters)` and returns the
  deleted-row count. `filters` is a map of `field => value` equality clauses.

  Remote: ships a `delete_all` plan; the count comes back in the reply's
  per-entry `results` (T52.3), so the count contract holds across the socket.
  """
  @spec delete_all(module(), map() | keyword(), keyword()) :: non_neg_integer()
  def delete_all(schema, filters, writer_opts \\ []) do
    filters = Enum.into(filters, %{})

    write(
      fn ->
        {count, _} = Repo.delete_all(where(schema, ^Map.to_list(filters)))
        count
      end,
      Keyword.put(writer_opts, :remote, fn -> remote_delete_all(schema, filters, writer_opts) end)
    )
  end

  @doc """
  Routes a raw `Repo.query!(sql, params)` write (the `memory_chunks_fts`
  statements). Remote: ships an `sql` plan; raises on failure like `Repo.query!`.
  Returns `:ok` on the remote path (callers of the FTS write statements discard
  the result) and the `Repo.query!` result on the direct path.
  """
  @spec query!(String.t(), list(), keyword()) :: term()
  def query!(sql, params \\ [], writer_opts \\ []) when is_binary(sql) do
    write(
      fn -> Repo.query!(sql, params) end,
      Keyword.put(writer_opts, :remote, fn -> remote_query!(sql, params, writer_opts) end)
    )
  end

  # --- remote paths + return reconstruction ----------------------------------

  defp remote_insert(changeset, insert_opts, writer_opts) do
    if changeset.valid? do
      entry = %{
        "kind" => "insert",
        "schema" => schema_name(changeset),
        "fields" => plan_fields(changeset),
        "opts" => encode_insert_opts(insert_opts)
      }

      case send_batch([entry], writer_opts) do
        {:ok, _results} -> {:ok, insert_return(changeset, insert_opts)}
        {:error, reason} -> {:error, server_error(changeset, :insert, reason)}
      end
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp remote_update(changeset, writer_opts) do
    if changeset.valid? do
      entry = %{
        "kind" => "update_all",
        "schema" => schema_name(changeset),
        "filters" => pk_filters(changeset),
        "changes" => stringify_keys(changeset.changes)
      }

      case send_batch([entry], writer_opts) do
        {:ok, _results} -> {:ok, Ecto.Changeset.apply_changes(changeset)}
        {:error, reason} -> {:error, server_error(changeset, :update, reason)}
      end
    else
      {:error, %{changeset | action: :update}}
    end
  end

  defp remote_delete_all(schema, filters, writer_opts) do
    entry = %{
      "kind" => "delete_all",
      "schema" => module_name(schema),
      "filters" => stringify_keys(filters)
    }

    case send_batch([entry], writer_opts) do
      {:ok, [count | _]} when is_integer(count) -> count
      {:ok, _results} -> 0
      {:error, reason} -> raise "kazi read-model delete_all failed via daemon: #{reason}"
    end
  end

  defp remote_query!(sql, params, writer_opts) do
    entry = %{"kind" => "sql", "sql" => sql, "params" => params}

    case send_batch([entry], writer_opts) do
      {:ok, _results} -> :ok
      {:error, reason} -> raise "kazi read-model query! failed via daemon: #{reason}"
    end
  end

  # One control-socket round-trip carrying a batch of write plans. Returns the
  # reply's per-entry `results` on success, or the server/transport error.
  defp send_batch(batch, writer_opts) do
    sock_path = Keyword.get(writer_opts, :sock_path, Supervisor.default_sock_path())

    case Probe.request(sock_path, %{"op" => "write", "batch" => batch}) do
      {:ok, %{"ok" => true} = reply} -> {:ok, Map.get(reply, "results", [])}
      {:ok, %{"ok" => false, "error" => reason}} -> {:error, reason}
      {:ok, other} -> {:error, "unexpected_reply: #{inspect(other)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # An upsert return reflects the TRUE stored row (re-read by its conflict
  # target); a plain insert returns the changes applied over the empty struct.
  defp insert_return(changeset, insert_opts) do
    applied = Ecto.Changeset.apply_changes(changeset)

    case Keyword.get(insert_opts, :conflict_target) do
      nil -> applied
      target -> reread(applied, List.wrap(target)) || applied
    end
  end

  defp reread(struct, target_fields) do
    filters = Enum.map(target_fields, fn field -> {field, Map.fetch!(struct, field)} end)
    Repo.get_by(struct.__struct__, filters)
  end

  # The row's primary key as string-keyed equality filters for `update_all`.
  defp pk_filters(changeset) do
    changeset.data
    |> Ecto.primary_key()
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
  end

  # The changeset's cast params ARE the string-keyed, JSON-safe input the daemon
  # re-casts into the identical changeset; fall back to the changes for a
  # changeset built without `cast/3`.
  defp plan_fields(%Ecto.Changeset{params: params}) when is_map(params), do: params
  defp plan_fields(%Ecto.Changeset{changes: changes}), do: stringify_keys(changes)

  defp encode_insert_opts(opts) do
    Enum.reduce(opts, %{}, fn
      {:on_conflict, on_conflict}, acc -> Map.put(acc, "on_conflict", encode_on_conflict(on_conflict))
      {:conflict_target, target}, acc -> Map.put(acc, "conflict_target", stringify_list(target))
      _other, acc -> acc
    end)
  end

  defp encode_on_conflict(:replace_all), do: "replace_all"
  defp encode_on_conflict(:nothing), do: "nothing"
  defp encode_on_conflict({:replace, fields}), do: %{"replace" => stringify_list(fields)}
  defp encode_on_conflict(other), do: other

  defp server_error(changeset, action, reason) do
    changeset
    |> Ecto.Changeset.add_error(:base, to_string(reason))
    |> Map.put(:action, action)
  end

  defp schema_name(changeset), do: module_name(changeset.data.__struct__)
  defp module_name(mod), do: mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify_list(value), do: value |> List.wrap() |> Enum.map(&to_string/1)

  # Presence, memoized per process with a short TTL (ADR-0068: do not stat the
  # socket on every write of a busy run).
  defp daemon_status(opts) do
    sock_path = Keyword.get(opts, :sock_path, Supervisor.default_sock_path())
    probe = Keyword.get(opts, :probe, &Probe.probe/1)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case Process.get(cache_key(sock_path)) do
      {status, expires_at} when expires_at > now ->
        status

      _expired_or_missing ->
        status = probe.(sock_path)
        Process.put(cache_key(sock_path), {status, now + ttl_ms})
        status
    end
  end

  defp cache_key(sock_path), do: {__MODULE__, :presence, sock_path}
end
