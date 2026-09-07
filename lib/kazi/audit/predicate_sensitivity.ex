defmodule Kazi.Audit.PredicateSensitivity do
  @moduledoc """
  Targeted mutation sensitivity. Only an explicit baseline pass followed by
  an explicit mutated fail detects a fault. Missing/error/unknown results are
  inconclusive. A caller must establish successful fault application separately.
  `score/3` selects targets explicitly; `score/2` retains legacy target inference.
  """
  alias Kazi.PredicateVector
  @type t :: map()

  def score(%PredicateVector{} = baseline, %PredicateVector{} = mutated) do
    score(baseline, mutated, PredicateVector.passing(baseline))
    |> Map.put(:coverage, "inferred_targets")
  end

  @doc "Scores only declared targets; invalid baseline targets return an error."
  def score(%PredicateVector{} = baseline, %PredicateVector{} = mutated, targets)
      when is_list(targets) do
    targets = targets |> Enum.uniq() |> Enum.sort()
    invalid = Enum.reject(targets, &(status(baseline, &1) == :pass))

    if invalid != [] do
      {:error, {:invalid_baseline, invalid}}
    else
      detected_ids =
        Enum.filter(
          targets,
          &Kazi.Audit.BehavioralFailure.supported?(PredicateVector.get(mutated, &1))
        )

      survivors = Enum.filter(targets, &(status(mutated, &1) == :pass))
      inconclusive_ids = targets -- (detected_ids ++ survivors)
      eligible = length(targets)
      detected = length(detected_ids)

      %{
        tested: eligible,
        constrained: detected,
        eligible: eligible,
        detected: detected,
        survived: length(survivors),
        inconclusive: length(inconclusive_ids),
        targets: targets,
        detected_ids: detected_ids,
        survivors: survivors,
        inconclusive_ids: inconclusive_ids,
        coverage: "explicit_targets",
        sensitivity: sensitivity(detected, eligible)
      }
    end
  end

  defp status(vector, id) do
    case PredicateVector.get(vector, id) do
      %{status: status} -> status
      _ -> :missing
    end
  end

  def audit(%PredicateVector{} = baseline, reevaluate) when is_function(reevaluate, 0),
    do: score(baseline, reevaluate.())

  @doc """
  Deterministic sampling gate: `true` for approximately `rate` (0.0–1.0) of
  distinct `key`s, decided purely from a stable hash of `key` — no clock, no RNG
  state. The same `{key, rate}` always decides the same way, so a periodic
  caller gets a reproducible sample and a test can pin exact keys.

  `rate <= 0.0` never samples; `rate >= 1.0` always samples.

  ## Examples

      iex> Kazi.Audit.PredicateSensitivity.should_sample?("anything", 1.0)
      true
      iex> Kazi.Audit.PredicateSensitivity.should_sample?("anything", 0.0)
      false
  """
  @spec should_sample?(String.t(), float()) :: boolean()
  def should_sample?(_key, rate) when is_number(rate) and rate <= 0, do: false
  def should_sample?(_key, rate) when is_number(rate) and rate >= 1, do: true

  def should_sample?(key, rate) when is_binary(key) and is_number(rate) do
    # phash2 spreads the key uniformly over 0..(2^32 - 1); the lowest `rate`
    # fraction of that space samples. Deterministic and clock-free.
    bucket = :erlang.phash2(key, 1_000_000)
    bucket < rate * 1_000_000
  end

  defp sensitivity(_constrained, 0), do: nil
  defp sensitivity(constrained, tested), do: constrained / tested
end
