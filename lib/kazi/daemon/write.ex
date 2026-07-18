defmodule Kazi.Daemon.Write do
  @moduledoc """
  T52.3 (ADR-0068 decision 1): the daemon's SERVER-SIDE read-model write. The
  client sends `{"op":"write","batch":[...]}` over the control socket; this
  module applies the whole batch inside ONE `Kazi.Repo.transaction` and hands
  back `{"ok":true,"applied":N}` -- or, on ANY failure, `{"ok":false,"error":
  <reason>}` with the WHOLE transaction rolled back (never a partial batch).
  It is the sibling of `Kazi.Daemon.BusRead`: `Kazi.Daemon.Control` routes the
  `write` op here exactly as it routes `read` there.

  With the E51 daemon running it is the ONE process that opens the read-model
  read-write, so every client write serializes through this single writer --
  the structural fix for the #1019 mixed-migration-writer class (ADR-0068).

  ## The write plan wire format (JSON-safe, ADR-0034)

  A changeset does not serialize naively (it carries functions, a schema
  struct, validation closures) and neither does an `Ecto.Query`, so a write
  cannot be shipped as "a changeset over the wire". Instead each `batch` entry
  is an OPAQUE write plan -- a small JSON object the server reconstructs into a
  concrete `Repo` call. The inventory (E52 T52.0) is not all changesets: it
  includes multi-statement raw SQL (the `memory_chunks_fts` FTS upsert), so the
  format covers BOTH Ecto writes and raw statements. Four `kind`s span the whole
  ~20-entry surface:

    * `insert` -- `%{"kind" => "insert", "schema" => "Kazi.ReadModel.Iteration",
      "fields" => %{...}, "opts" => %{...}}`. Builds the schema's `changeset/2`
      (falling back to `Ecto.Changeset.change/2` for a schema without one) and
      `Repo.insert`s it. `opts` carries the encodable upsert options
      (`on_conflict`, `conflict_target`) so `authoring.ex` /
      `semantic_index.ex` UPSERTs round-trip. Covers every plain insert /
      insert! / upsert in the inventory.
    * `update_all` -- `%{"kind" => "update_all", "schema" => ..., "filters" =>
      %{...}, "changes" => %{...}}`. `Repo.update_all(from x in schema, where:
      ^filters)` with `set:` = `changes`. Covers the run-registry
      transitions (`heartbeat`, `finish`, ...), the proposed-goal/memory
      transitions, and the reaper.
    * `delete_all` -- `%{"kind" => "delete_all", "schema" => ..., "filters" =>
      %{...}}`. Covers `invalidate_cached_*` and the pause-checkpoint delete.
    * `sql` -- `%{"kind" => "sql", "sql" => "DELETE FROM memory_chunks_fts ...",
      "params" => [...]}`. A raw parametrized statement -- the ONLY shape that
      covers the FTS upsert, which is two raw statements that are one logical
      write.

  Schema module + field names resolve via `String.to_existing_atom/1` (the
  atoms already exist once the module is loaded), so a bad `schema`/field is a
  clean `{"ok":false,"error":...}`, never an arbitrary-atom leak.

  ## L-0052 bound (mirror of `BusRead.refuse_full/1`)

  `packet: :line` truncates an over-long line SILENTLY on the receiving end
  (`Kazi.Daemon.Probe.socket_buffer/0`, = 1 MiB). A write request at or over
  that bound is REFUSED here with a named error, never applied against a
  possibly-truncated payload -- a truncated write is the one thing worse than a
  refused one. The client caps a batch below the buffer and splits rather than
  send an over-long line (E52 batching); this is the server-side belt to that
  client-side suspenders.

  ## Atomicity + L-0049

  The whole batch runs in one `Repo.transaction`; the first failing entry calls
  `Repo.rollback/1` so NO entry persists (the constraint-violation case), and a
  raised error (a bad statement, an unmapped constraint) aborts the transaction
  the same way. The read-model `Repo` carries its own `busy_timeout` (L-0049),
  so a concurrent reader never turns a write into a hang.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  # ===========================================================================
  # T52.4 (ADR-0068 point 2): the write server as a supervised child.
  #
  # `Kazi.Daemon.Supervisor` migrates the read-model ONCE (it is the one and
  # only migrator) and starts THIS process only after that migration returns,
  # ordered before `Kazi.Daemon.Listener` -- so by the time the socket accepts
  # a `write`, the read-model is migrated and this write server is up. The
  # process itself holds no mutable state today; its PLACE IN THE TREE is the
  # invariant (a `write` is never served against an unmigrated file). The
  # actual per-request write logic stays in the stateless `handle/2` below,
  # which `Kazi.Daemon.Control` calls directly.
  # ===========================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # `:on_start` is a test seam (mirrors the sweep/nats naming seams): a
    # lifecycle test injects it to observe that this child is started AFTER the
    # supervisor's boot migration returns, never before.
    case Keyword.get(opts, :on_start) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end

    {:ok, %{repo: Keyword.get(opts, :repo, Kazi.Repo)}}
  end

  @doc """
  Applies one control-socket `write` request and returns the reply map.

  `request` is the decoded JSON (`batch` is the list of write plans).
  `opts[:repo]` is the `Ecto.Repo` to write through (defaults to `Kazi.Repo`;
  injectable so a test drives the sandbox).
  """
  @spec handle(map(), keyword()) :: map()
  def handle(request, opts \\ []) do
    repo = Keyword.get(opts, :repo, Kazi.Repo)

    with :ok <- refuse_oversized(request),
         {:ok, batch} <- fetch_batch(request) do
      apply_batch(repo, batch)
    else
      {:error, reason} -> error(reason)
    end
  rescue
    error ->
      Logger.debug("kazi daemon: write failed (#{Exception.message(error)})")
      error(rescue_reason(error))
  catch
    kind, reason ->
      Logger.debug("kazi daemon: write failed (#{inspect(kind)}: #{inspect(reason)})")
      error("write_failed")
  end

  # L-0052: a request whose encoded line meets or exceeds the socket buffer would
  # be truncated silently in transit; refuse it up front rather than apply a
  # payload that may already be short. Measured against the re-encoded request so
  # the bound is directly testable via `handle/2`.
  defp refuse_oversized(request) do
    if byte_size(Jason.encode!(request)) >= Kazi.Daemon.Probe.socket_buffer() do
      {:error, "request_too_large"}
    else
      :ok
    end
  end

  defp fetch_batch(%{"batch" => batch}) when is_list(batch), do: {:ok, batch}
  defp fetch_batch(_request), do: {:error, "missing_batch"}

  # One transaction for the whole batch: the first failing entry rolls back every
  # prior one, so a client never observes a partial batch (ADR-0068).
  defp apply_batch(repo, batch) do
    result =
      repo.transaction(fn ->
        Enum.reduce(batch, 0, fn entry, applied ->
          case apply_entry(repo, entry) do
            :ok -> applied + 1
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, applied} -> %{"ok" => true, "applied" => applied}
      {:error, reason} -> error(reason)
    end
  end

  defp apply_entry(repo, %{"kind" => "insert", "schema" => schema} = entry) do
    with {:ok, mod} <- resolve_schema(schema) do
      changeset = insert_changeset(mod, Map.get(entry, "fields", %{}))

      case repo.insert(changeset, decode_opts(Map.get(entry, "opts", %{}))) do
        {:ok, _row} -> :ok
        {:error, changeset} -> {:error, changeset_error(changeset)}
      end
    end
  end

  defp apply_entry(repo, %{"kind" => "update_all", "schema" => schema} = entry) do
    with {:ok, mod} <- resolve_schema(schema),
         {:ok, filters} <- keyword(Map.get(entry, "filters", %{})),
         {:ok, changes} <- keyword(Map.get(entry, "changes", %{})) do
      query = from(x in mod, where: ^filters)
      {_count, _} = repo.update_all(query, set: changes)
      :ok
    end
  end

  defp apply_entry(repo, %{"kind" => "delete_all", "schema" => schema} = entry) do
    with {:ok, mod} <- resolve_schema(schema),
         {:ok, filters} <- keyword(Map.get(entry, "filters", %{})) do
      query = from(x in mod, where: ^filters)
      {_count, _} = repo.delete_all(query)
      :ok
    end
  end

  defp apply_entry(repo, %{"kind" => "sql", "sql" => sql} = entry) when is_binary(sql) do
    case repo.query(sql, Map.get(entry, "params", [])) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "sql_failed: #{inspect(reason)}"}
    end
  end

  # An unknown `kind` (or a malformed entry) is a clean batch failure, never a
  # crashed connection -- the whole transaction rolls back and the client is told.
  defp apply_entry(_repo, %{"kind" => kind}), do: {:error, "unknown_kind: #{kind}"}
  defp apply_entry(_repo, _entry), do: {:error, "malformed_entry"}

  # Prefer the schema's own `changeset/2` (it declares the `unique_constraint`s
  # that map a DB violation to a clean `{:error, changeset}` instead of a raised
  # `Ecto.ConstraintError`); fall back to a bare change for a schema without one.
  defp insert_changeset(mod, fields) do
    if function_exported?(mod, :changeset, 2) do
      mod.changeset(struct(mod), fields)
    else
      Ecto.Changeset.change(struct(mod), atomize(fields))
    end
  end

  defp resolve_schema(name) when is_binary(name) do
    mod = existing_module(name)

    cond do
      is_nil(mod) -> {:error, "unknown_schema: #{name}"}
      Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) -> {:ok, mod}
      true -> {:error, "not_a_schema: #{name}"}
    end
  end

  defp resolve_schema(_name), do: {:error, "missing_schema"}

  defp existing_module(name) do
    String.to_existing_atom(prefix(name))
  rescue
    ArgumentError -> nil
  end

  defp prefix("Elixir." <> _rest = name), do: name
  defp prefix(name), do: "Elixir." <> name

  # JSON opts -> the small encodable subset of `Repo.insert` options the upsert
  # sites need: `on_conflict` and `conflict_target`.
  defp decode_opts(opts) when is_map(opts) do
    opts
    |> Enum.flat_map(fn
      {"on_conflict", value} -> [on_conflict: on_conflict(value)]
      {"conflict_target", value} -> [conflict_target: atomize_list(value)]
      _other -> []
    end)
  end

  defp decode_opts(_opts), do: []

  defp on_conflict("replace_all"), do: :replace_all
  defp on_conflict("nothing"), do: :nothing
  defp on_conflict(%{"replace" => fields}), do: {:replace, atomize_list(fields)}
  defp on_conflict(other), do: other

  defp keyword(map) when is_map(map) do
    {:ok, map |> atomize() |> Map.to_list()}
  rescue
    ArgumentError -> {:error, "unknown_field"}
  end

  defp keyword(_other), do: {:error, "malformed_fields"}

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {to_field(k), v} end)
  end

  defp atomize_list(list) when is_list(list), do: Enum.map(list, &to_field/1)
  defp atomize_list(value), do: [to_field(value)]

  defp to_field(key) when is_atom(key), do: key
  defp to_field(key) when is_binary(key), do: String.to_existing_atom(key)

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp rescue_reason(%Ecto.ConstraintError{constraint: constraint}),
    do: "constraint: #{constraint}"

  defp rescue_reason(%ArgumentError{}), do: "invalid_write_plan"
  defp rescue_reason(_error), do: "write_failed"

  defp error(reason), do: %{"ok" => false, "error" => to_string(reason)}
end
