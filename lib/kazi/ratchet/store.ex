defmodule Kazi.Ratchet.Store do
  @moduledoc """
  The persisted baseline store for `:ratchet` predicates whose baseline is the
  STORED prior value (T32.3, ADR-0041 decision 4).

  A ratchet that compares against its own prior value needs that value to survive
  between iterations and runs. It lives in a small JSON file
  (`<store_dir>/ratchets.json`) mapping a predicate id to its current baseline
  number, written only when the ratchet PASSES (the bar moves forward, never
  back — the "may only improve" guard substrate ADR-0042 leans on).

  The store directory defaults to `<workspace>/.kazi` but is overridable
  (`context[:ratchet_store_dir]`), so the anti-gaming work (T32.4) can relocate
  the baseline to a clean tree the agent cannot edit.
  """

  @filename "ratchets.json"

  @doc "The baseline file path for a store directory."
  @spec path(Path.t()) :: Path.t()
  def path(store_dir), do: Path.join(store_dir, @filename)

  @doc """
  Reads the stored baseline for `id`. Returns `{:ok, number}` when a baseline has
  been stored, `:none` when the store file is simply absent (a first run — a
  missing baseline is never invented), or `{:error, :corrupt}` when the store
  file EXISTS but cannot be decoded (M2, deep-review-001): a truncated/corrupt
  store must never be silently treated as "no baseline yet" and reseeded at the
  current (possibly regressed) value.
  """
  @spec read(Path.t(), Kazi.Predicate.id()) :: {:ok, number()} | :none | {:error, :corrupt}
  def read(store_dir, id) do
    case File.read(path(store_dir)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) ->
            case Map.get(map, to_string(id)) do
              value when is_number(value) -> {:ok, value}
              _ -> :none
            end

          _ ->
            {:error, :corrupt}
        end

      {:error, _} ->
        :none
    end
  end

  @doc """
  Writes `value` as the baseline for `id`, merging into any existing store (other
  predicates' baselines are preserved). Returns `:ok` or `{:error, reason}`.

  Writes atomically (M2, deep-review-001): the merged JSON is written to a
  sibling temp file, then renamed over the store path. `File.rename/2` on the
  same filesystem is atomic, so a crash mid-write leaves either the old store
  intact or the temp file orphaned — never a truncated `ratchets.json`.
  """
  @spec write(Path.t(), Kazi.Predicate.id(), number()) :: :ok | {:error, term()}
  def write(store_dir, id, value) when is_number(value) do
    existing =
      case File.read(path(store_dir)) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    merged = Map.put(existing, to_string(id), value)

    with :ok <- File.mkdir_p(store_dir) do
      tmp_path = path(store_dir) <> ".tmp-#{System.unique_integer([:positive])}"

      with :ok <- File.write(tmp_path, Jason.encode!(merged)) do
        File.rename(tmp_path, path(store_dir))
      end
    end
  end
end
