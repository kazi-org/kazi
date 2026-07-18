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

  ## Write-time version-stamp-and-refuse (T52.7, ADR-0068)

  With no daemon (the `_absent` branch), before running the direct `Repo` write
  this seam compares THIS binary's schema version against the version stamped in
  the direct db file. When the binary is OLDER than the file
  (`SchemaSkew.classify/2 == :client_older`) it refuses the write rather than
  writing against a schema it does not understand: it logs the one-line operator
  degrade (the `Kazi.ReadModel.Migrate.migrate_or_refuse/2` message, extended from
  migrate-time to write-time — "read-model schema vN is newer than this binary …
  upgrade kazi") and returns a shaped degrade, so the run continues
  persistence-blind and VISIBLY (Guard-style, L-0035) instead of hanging or
  corrupting a newer schema. An equal-or-newer binary writes direct exactly as
  before. This mirrors the migrate-time refuse (`Migrate.run/2`) at write time,
  closing the gap for a run whose db was migrated forward by a newer peer AFTER
  this (older) binary already booted past its migration step.

  The refuse is decided ONLY when no daemon owns the file. With a daemon `:alive`,
  an older client keeps writing through the daemon's additive write API (T52.5) —
  the daemon is the single writer on the newer schema, so there is nothing to
  refuse.

  ### Refused-write return contract (keeps every caller alive)

  A refused write performs NO `Repo` write, yet must return a value each call
  site's existing match tolerates — the same discipline the Guard degrade
  (`{:error, :read_model_unavailable}`) already establishes read-model-wide:

    * `insert/3`, `update/2`, `insert_or_update/2` → `{:error,
      :read_model_unavailable}` (their callers already match `{:ok, _}` with a
      `with`/`case` and tolerate the `:read_model_unavailable` error tuple, e.g.
      `Kazi.ReadModel.record_iteration/1`'s typespec).
    * `insert!/3` → returns the `{:error, :read_model_unavailable}` tuple WITHOUT
      raising (it raises only on a genuine `%Ecto.Changeset{}` error); its lone
      caller (`Kazi.Memory.SemanticIndex` FTS upkeep) discards the result.
    * `delete_all/3` → `0` (truthful: no rows were removed) — its `non_neg_integer`
      count contract is preserved.
    * `query!/3` → `:ok` (mirrors its own remote-path discard return).

  ### Memoized skew (per process, short TTL)

  Like the presence probe, the file's stamped version is NOT read on every write:
  the refuse decision is cached in the process dictionary with the same TTL, so a
  write burst reads the stamp at most once per window and picks up a peer's
  forward-migration after the TTL expires.
  """

  require Logger

  import Ecto.Query, only: [where: 2]

  alias Kazi.Daemon.{Probe, Supervisor}
  alias Kazi.ReadModel.{Migrate, SchemaSkew}
  alias Kazi.Repo

  # Short enough that a daemon starting/stopping mid-run is noticed within a
  # second; long enough that a tight write loop probes the socket at most once.
  @default_ttl_ms 1_000

  @typedoc "A zero-arity closure performing a read-model write and returning its result."
  @type writer :: (-> term())

  @doc """
  Route a read-model write through the single-writer seam.

  `direct` is today's exact `Kazi.Repo` write, run as-is when no daemon owns the
  file AND this binary's schema is not older than the file's stamped schema. When a
  daemon is `:alive`, the `:remote` writer runs instead (defaulting to `direct`
  until the socket-client path is wired). When no daemon owns the file and this
  binary is OLDER than the file's stamped schema (T52.7), the write is REFUSED: the
  `:refused` closure runs (a shaped Guard-style degrade) and no `Repo` write
  happens. Returns whatever the chosen writer returns.

  ## Options (T52.7 additions)

    * `:refused` — a zero-arity closure producing the shaped degrade value when the
      write is refused at write time. Defaults to `{:error, :read_model_unavailable}`
      (the read-model-wide Guard degrade). Typed helpers override it to preserve
      their own return contract (`delete_all` → `0`, `query!` → `:ok`).
    * `:binary_version` — this binary's schema version, for the skew check.
      Defaults to `Kazi.ReadModel.Migrate.binary_version/0`. Injectable for tests.
    * `:db_stamped_version` — the direct file's stamped schema version. Defaults to
      `Kazi.ReadModel.Migrate.db_stamped_version(Kazi.Repo)`. Injectable for tests.
  """
  @spec write(writer(), keyword()) :: term()
  def write(direct, opts \\ []) when is_function(direct, 0) do
    remote = Keyword.get(opts, :remote, direct)

    case daemon_status(opts) do
      :alive ->
        remote.()

      _absent ->
        if refuse_direct?(opts) do
          refused = Keyword.get(opts, :refused, fn -> {:error, :read_model_unavailable} end)
          refused.()
        else
          direct.()
        end
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

  @doc """
  Bang variant of `insert/3`; raises on `{:error, changeset}` like `Repo.insert!/2`.

  A write-time refuse (T52.7) surfaces as `{:error, :read_model_unavailable}` and
  is returned WITHOUT raising — a refused write is a degrade, not an invalid
  changeset — so an older binary running persistence-blind never crashes a caller
  that discards the result (the `SemanticIndex` FTS upkeep).
  """
  @spec insert!(Ecto.Changeset.t(), keyword(), keyword()) ::
          Ecto.Schema.t() | {:error, :read_model_unavailable}
  def insert!(%Ecto.Changeset{} = changeset, insert_opts \\ [], writer_opts \\ []) do
    case insert(changeset, insert_opts, writer_opts) do
      {:ok, struct} ->
        struct

      {:error, :read_model_unavailable} = degrade ->
        degrade

      {:error, %Ecto.Changeset{} = changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
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
      writer_opts
      |> Keyword.put(:remote, fn -> remote_delete_all(schema, filters, writer_opts) end)
      |> Keyword.put(:refused, fn -> 0 end)
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
      writer_opts
      |> Keyword.put(:remote, fn -> remote_query!(sql, params, writer_opts) end)
      |> Keyword.put(:refused, fn -> :ok end)
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
    sock_path = Keyword.get(writer_opts, :sock_path, default_sock_path())

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
      {:on_conflict, on_conflict}, acc ->
        Map.put(acc, "on_conflict", encode_on_conflict(on_conflict))

      {:conflict_target, target}, acc ->
        Map.put(acc, "conflict_target", stringify_list(target))

      _other, acc ->
        acc
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

  # The control socket the presence probe and the write client dial when a call
  # site supplies none. Overridable via `config :kazi, :read_model_writer_sock`
  # so the test env points it at a never-existing socket (mirroring
  # `:lease_map_daemon_sock`) and unrelated suites never route to a real daemon a
  # developer's machine happens to be running.
  defp default_sock_path do
    Application.get_env(:kazi, :read_model_writer_sock) || Supervisor.default_sock_path()
  end

  # Presence, memoized per process with a short TTL (ADR-0068: do not stat the
  # socket on every write of a busy run).
  defp daemon_status(opts) do
    sock_path = Keyword.get(opts, :sock_path, default_sock_path())
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

  # The write-time version-stamp-and-refuse decision (T52.7), memoized per process
  # with the same short TTL as the presence probe: read the file's stamped version
  # at most once per window rather than on every write of a burst. Returns `true`
  # when this binary is OLDER than the file's stamped schema (refuse), `false`
  # otherwise (write direct). The one-line operator degrade is logged on each fresh
  # (post-TTL) refuse decision, so a persistence-blind run stays visible without
  # spamming a line per write.
  defp refuse_direct?(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case Process.get(skew_key()) do
      {decision, expires_at} when expires_at > now ->
        decision

      _expired_or_missing ->
        decision = probe_skew(opts)
        Process.put(skew_key(), {decision, now + ttl_ms})
        decision
    end
  end

  defp probe_skew(opts) do
    bin_version = Keyword.get_lazy(opts, :binary_version, &Migrate.binary_version/0)

    db_version =
      Keyword.get_lazy(opts, :db_stamped_version, fn -> Migrate.db_stamped_version(Repo) end)

    # An unstamped (nil) db — a freshly-created, pre-migration file — is never
    # "newer", so it always writes direct (mirrors Migrate's brand-new-db path).
    if is_integer(db_version) and SchemaSkew.classify(bin_version, db_version) == :client_older do
      Logger.warning(fn ->
        "read-model schema v#{db_version} is newer than this binary " <>
          "(v#{bin_version}); running without persistence -- upgrade kazi"
      end)

      true
    else
      false
    end
  end

  defp skew_key, do: {__MODULE__, :skew}
end
