defmodule Kazi.Velocity.Cursor do
  @moduledoc """
  T67.3 (ADR-0079 decision 2): the collector's MACHINE-LOCAL incremental cursor.

  For each transcript file the collector persists a small JSON state: the byte
  `offset` parsed so far and the CUMULATIVE `Kazi.Velocity.Counters` accumulated up
  to that offset, plus the last event timestamp (`prev_ts`) used to bridge
  active-time across passes and the resolved session identity. On the next pass the
  collector parses only bytes past `offset` and merges the fresh chunk into the
  carried accumulator, so re-scanning a transcript that has not grown yields the
  IDENTICAL cumulative totals (idempotency) — the cursor, not the read-model, is
  what makes the collector incremental and repeatable.

  This is machine-local state (ADR-0079): it lives under a per-machine state
  directory, never in the read-model. The directory is injectable so tests use a
  tmp dir.
  """

  alias Kazi.Velocity.Counters

  @typedoc "The persisted per-transcript cursor state."
  @type state :: %{
          offset: non_neg_integer(),
          counters: Counters.t(),
          prev_ts: DateTime.t() | nil,
          session_uuid: String.t() | nil,
          session_name: String.t() | nil
        }

  @doc "The empty cursor for a transcript never seen before."
  @spec empty() :: state()
  def empty do
    %{offset: 0, counters: %Counters{}, prev_ts: nil, session_uuid: nil, session_name: nil}
  end

  @doc """
  Load the cursor state for `transcript_path` from `dir`. A missing or unreadable
  cursor file degrades to `empty/0` (re-scan from the start), never a crash.
  """
  @spec load(String.t(), String.t()) :: state()
  def load(dir, transcript_path) do
    path = cursor_path(dir, transcript_path)

    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw) do
      decode(map)
    else
      _ -> empty()
    end
  end

  @doc "Persist the cursor state for `transcript_path` under `dir`."
  @spec save(String.t(), String.t(), state()) :: :ok | {:error, term()}
  def save(dir, transcript_path, state) do
    path = cursor_path(dir, transcript_path)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(encode(state)))
  end

  # A stable, filesystem-safe cursor filename per transcript path (hash so an
  # absolute path with slashes maps to a single flat file).
  defp cursor_path(dir, transcript_path) do
    digest = :crypto.hash(:sha256, transcript_path) |> Base.encode16(case: :lower)
    Path.join(dir, "#{digest}.json")
  end

  defp encode(state) do
    %{
      "offset" => state.offset,
      "prev_ts" => encode_ts(state.prev_ts),
      "session_uuid" => state.session_uuid,
      "session_name" => state.session_name,
      "counters" => encode_counters(state.counters)
    }
  end

  defp encode_counters(%Counters{} = c) do
    c
    |> Map.from_struct()
    |> Map.new(fn
      {k, %DateTime{} = dt} -> {Atom.to_string(k), DateTime.to_iso8601(dt)}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end

  defp encode_ts(nil), do: nil
  defp encode_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode(map) do
    %{
      offset: non_neg_int(Map.get(map, "offset")),
      prev_ts: decode_ts(Map.get(map, "prev_ts")),
      session_uuid: Map.get(map, "session_uuid"),
      session_name: Map.get(map, "session_name"),
      counters: decode_counters(Map.get(map, "counters", %{}))
    }
  end

  defp decode_counters(map) when is_map(map) do
    Enum.reduce(Map.from_struct(%Counters{}), %Counters{}, fn {field, _default}, acc ->
      key = Atom.to_string(field)

      case Map.get(map, key) do
        nil -> acc
        value -> Map.put(acc, field, decode_counter_value(field, value))
      end
    end)
  end

  defp decode_counters(_), do: %Counters{}

  defp decode_counter_value(field, value) when field in [:first_observed_at, :last_observed_at],
    do: decode_ts(value)

  defp decode_counter_value(_field, value), do: value

  defp decode_ts(nil), do: nil

  defp decode_ts(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0
end
