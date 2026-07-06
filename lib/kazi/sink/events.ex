defmodule Kazi.Sink.Events do
  @moduledoc """
  The per-run `events.jsonl` sink (T46.2, ADR-0057 decision 3): one JSON line
  per loop observation — the predicate vector, converged flag, dispatch
  metadata (`action_kind`/`action_params`), regression-detector firings, and
  the ADR-0046 context/tool counters — appended to the run's sink directory.

  Unlike `Kazi.Sink.Transcript` (a passive tee of raw harness stream text),
  every event here is a structured map the caller has already computed for
  the read-model row (`Kazi.Runtime`'s `on_iteration` seam builds it from the
  SAME `Kazi.ReadModel.Iteration` struct `record_iteration/1` just inserted),
  so a sink line and its read-model row can never disagree in shape or values.

  Append-only and best-effort throughout: a write failure (unwritable
  directory, transient I/O error) is caught and logged, never raised into the
  loop. `read/1` is the matching reader — it tolerates a torn final line (a
  process killed mid-write leaves a partial trailing line) by silently
  dropping any line that fails to parse as JSON, rather than erroring the
  whole read.

  ## Retention

  Sinks accumulate one directory per run under the shared `sinks_dir`
  (`<sinks_dir>/<run_id>/events.jsonl`, alongside `transcript.jsonl`) and are
  never deleted by the write path — `sweep/2` is the separate, explicit
  retention pass: it drops a run's ENTIRE sink directory once it is aged past
  `:max_age_seconds` OR sized past `:max_bytes` (`default_max_age_seconds/0`,
  `default_max_bytes/0`), but NEVER a directory named in the caller-supplied
  `:live_run_ids` — the caller (which owns the read-model, e.g.
  `Kazi.ReadModel.RunRegistry.list/0`) decides liveness; this module has no
  Repo dependency and stays a pure filesystem operation.
  """

  require Logger

  alias Kazi.Redaction

  @default_max_age_seconds 7 * 24 * 60 * 60
  @default_max_bytes 200 * 1024 * 1024

  @doc "The default retention age (seconds) applied when `sweep/2` receives no `:max_age_seconds` opt."
  @spec default_max_age_seconds() :: pos_integer()
  def default_max_age_seconds, do: @default_max_age_seconds

  @doc "The default retention size cap (bytes, per run directory) applied when `sweep/2` receives no `:max_bytes` opt."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  Appends `event` (a map) to `path` as one redacted JSON line. `path` may be
  `nil` (no sink configured) — a no-op. Best-effort: any failure is caught and
  logged, never raised into the caller.
  """
  @spec append(String.t() | nil, map(), keyword()) :: :ok
  def append(path, event, opts \\ [])

  def append(nil, _event, _opts), do: :ok

  def append(path, event, _opts) when is_binary(path) and is_map(event) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    line = event |> redact_event() |> Jason.encode!()
    File.write!(path, line <> "\n", [:append])
    :ok
  rescue
    error ->
      Logger.warning(fn -> "kazi events sink append failed for #{path}: #{inspect(error)}" end)
      :ok
  end

  @doc """
  Reads `path` back into a list of decoded event maps, oldest first. A torn
  final line (one that fails to parse as JSON, e.g. a crash mid-write) is
  silently dropped rather than raising; every earlier line is still returned.
  A missing file reads as an empty list.
  """
  @spec read(String.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} -> [decoded]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Sweeps `sinks_dir` (the parent directory of per-run `<run_id>/` sink
  directories), deleting a run's whole sink directory when it is aged past
  `:max_age_seconds` (default #{@default_max_age_seconds}s) OR sized past
  `:max_bytes` (default #{@default_max_bytes} bytes) — except any run_id listed
  in `:live_run_ids` (default `[]`), which is never touched regardless of age
  or size. Returns the list of deleted run_ids. A missing `sinks_dir` sweeps to
  an empty list rather than raising.
  """
  @spec sweep(String.t(), keyword()) :: [String.t()]
  def sweep(sinks_dir, opts \\ []) do
    max_age_seconds = Keyword.get(opts, :max_age_seconds, @default_max_age_seconds)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    live_run_ids = opts |> Keyword.get(:live_run_ids, []) |> MapSet.new()

    case File.ls(sinks_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn run_id -> {run_id, Path.join(sinks_dir, run_id)} end)
        |> Enum.filter(fn {_run_id, path} -> File.dir?(path) end)
        |> Enum.reject(fn {run_id, _path} -> MapSet.member?(live_run_ids, run_id) end)
        |> Enum.filter(fn {_run_id, path} ->
          aged?(path, max_age_seconds) or oversized?(path, max_bytes)
        end)
        |> Enum.map(fn {run_id, path} ->
          File.rm_rf!(path)
          run_id
        end)

      {:error, _} ->
        []
    end
  end

  # =============================================================================
  # Event redaction (mirrors Kazi.Sink.Transcript's field-by-field pass)
  # =============================================================================

  defp redact_event(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, redact_value(v)} end)
  end

  defp redact_value(v) when is_binary(v), do: Redaction.redact(v)
  defp redact_value(v) when is_map(v), do: redact_event(v)
  defp redact_value(v) when is_list(v), do: Enum.map(v, &redact_value/1)
  defp redact_value(v), do: v

  # =============================================================================
  # Retention sweep helpers
  # =============================================================================

  defp aged?(path, max_age_seconds) do
    case newest_mtime(path) do
      nil -> false
      mtime -> DateTime.diff(DateTime.utc_now(), mtime, :second) > max_age_seconds
    end
  end

  defp oversized?(path, max_bytes), do: dir_size(path) > max_bytes

  defp newest_mtime(path) do
    path
    |> File.ls!()
    |> Enum.map(&Path.join(path, &1))
    |> Enum.map(&file_mtime/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      mtimes -> Enum.max(mtimes, DateTime)
    end
  rescue
    _ -> nil
  end

  defp file_mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _} -> nil
    end
  end

  defp dir_size(path) do
    path
    |> File.ls!()
    |> Enum.map(&Path.join(path, &1))
    |> Enum.map(fn file ->
      case File.stat(file) do
        {:ok, %{size: size}} -> size
        {:error, _} -> 0
      end
    end)
    |> Enum.sum()
  rescue
    _ -> 0
  end
end
