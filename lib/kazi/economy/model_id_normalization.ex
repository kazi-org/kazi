defmodule Kazi.Economy.ModelIdNormalization do
  @moduledoc """
  Normalize model IDs to canonical form for price-table lookups (ADR-TBD).

  Providers and harnesses report model IDs with minor variations:
  - Case (CLAUDE-OPUS-4-8 vs claude-opus-4-8)
  - Version date suffixes (claude-opus-4-8-20260101)
  - Whitespace (leading/trailing)

  `normalize/1` returns a canonical lowercase form stripped of these variations,
  so the price table (`Kazi.Economy.PriceMap`) can be expressed with one entry
  per semantic model, and lookups resolve common real-world variations. The
  honest-unknown discipline persists: a normalized form still not in the map
  returns :error, never a guess.

  Pure: no I/O, no provider knowledge beyond the string transformations below.
  """

  @doc """
  Normalize `model` to canonical form.

  Returns the canonical (lowercase, no version suffix, no whitespace) form of
  a model ID string, or nil for non-binary inputs. An empty string returns `""`.

  Normalization steps (applied in order):
  1. Trim leading/trailing whitespace.
  2. Lowercase the entire string.
  3. Strip trailing YYYYMMDD version suffixes (an 8-digit date after the last `-`).
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(model) when is_binary(model) do
    model
    |> String.trim()
    |> String.downcase()
    |> strip_version_suffix()
  end

  def normalize(_model), do: nil

  @doc """
  Look up a model in a map after normalizing its ID.

  Returns `{:ok, value}` if the normalized model ID is present in `map`;
  returns `:error` otherwise. Useful for price-table lookups where the
  harness reports a variant of a canonical model ID.
  """
  @spec normalize_and_lookup(term(), map()) :: {:ok, any()} | :error
  def normalize_and_lookup(model, map) when is_map(map) do
    case normalize(model) do
      normalized when is_binary(normalized) ->
        case Map.fetch(map, normalized) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end

      nil ->
        :error
    end
  end

  def normalize_and_lookup(_model, _map), do: :error

  # Strip a trailing YYYYMMDD version suffix (8 consecutive digits after the last `-`).
  # Example: "claude-opus-4-8-20260101" → "claude-opus-4-8".
  # If no such suffix exists, returns the string unchanged.
  @spec strip_version_suffix(String.t()) :: String.t()
  defp strip_version_suffix(model) do
    case String.match?(model, ~r/-\d{8}$/) do
      true -> String.slice(model, 0..-10//1)
      false -> model
    end
  end
end
