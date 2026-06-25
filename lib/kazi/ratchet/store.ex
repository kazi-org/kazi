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
  been stored, or `:none` when none has (a first run, or an unreadable/corrupt
  store — a missing baseline is never invented).
  """
  @spec read(Path.t(), Kazi.Predicate.id()) :: {:ok, number()} | :none
  def read(store_dir, id) do
    with {:ok, contents} <- File.read(path(store_dir)),
         {:ok, map} when is_map(map) <- Jason.decode(contents),
         value when is_number(value) <- Map.get(map, to_string(id)) do
      {:ok, value}
    else
      _ -> :none
    end
  end

  @doc """
  Writes `value` as the baseline for `id`, merging into any existing store (other
  predicates' baselines are preserved). Returns `:ok` or `{:error, reason}`.
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
      File.write(path(store_dir), Jason.encode!(merged))
    end
  end
end
