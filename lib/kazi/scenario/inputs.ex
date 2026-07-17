defmodule Kazi.Scenario.Inputs do
  @moduledoc """
  Fresh input generation + per-replay `{{placeholder}}` substitution (ADR-0064
  decision 2, T49.4).

  A pin's `inputs` map names each `{{placeholder}}` its trace interpolates and
  the generator kind that fills it (`%{"pat_name" => "unique_slug"}`). This module
  substitutes a FRESHLY generated value for every placeholder at every replay, so
  replays are collision-free (no "name already taken" on the second run) and a
  fixer cannot hardcode a happy path against known test data — the two properties
  ADR-0064 decision 2 requires of a trustworthy pin.

  ## Generator kinds

    * `unique_slug` — the placeholder name, a hyphen, and 8 hex chars
      (`pat_name-1a2b3c4d`): human-recognizable in evidence yet unique per replay.
    * `random_email` — `<12 hex>@example.com` (the RFC 2606 reserved domain).
    * `random_string:<n>` — `n` lowercase-alphanumeric chars; `n` must be a
      positive integer or the kind is unknown.

  Any other kind — including a malformed `random_string:` length — is
  `{:error, {:unknown_generator, name}}` naming the placeholder whose declared
  generator could not be resolved. Substitution NEVER silently drives a literal
  `{{name}}` into the surface: an unresolvable placeholder fails loudly.

  ## The randomness seam

  `substitute/3` takes a 1-arity `rand_fun` returning that many random bytes,
  defaulting to `&:crypto.strong_rand_bytes/1`. Tests inject a fixed function for
  determinism; production stays genuinely random — the same injection idiom the
  surface providers use for their command seams.
  """

  @placeholder_pattern ~r/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/

  @string_alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  @default_rand &:crypto.strong_rand_bytes/1

  @type rand_fun :: (non_neg_integer() -> binary())

  @doc """
  Substitutes every `{{placeholder}}` in `trace` with a freshly generated value.

  `inputs` maps each placeholder name to its generator kind. Returns
  `{substituted_trace, generated}` where `generated` is `%{name => value}`
  recording exactly what was substituted, or `{:error, {:unknown_generator,
  name}}` when a placeholder's declared generator kind is unknown.

  A trace with no placeholders is returned unchanged (with an empty `generated`).
  """
  @spec substitute(map(), map(), rand_fun()) ::
          {map(), %{optional(String.t()) => String.t()}}
          | {:error, {:unknown_generator, String.t()}}
  def substitute(trace, inputs, rand_fun \\ @default_rand)

  def substitute(trace, inputs, rand_fun)
      when is_map(trace) and is_map(inputs) and is_function(rand_fun, 1) do
    case build_generated(placeholders(trace), inputs, rand_fun) do
      {:ok, generated} -> {deep_replace(trace, generated), generated}
      {:error, _reason} = error -> error
    end
  end

  defp build_generated(names, inputs, rand_fun) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case generate(Map.get(inputs, name), name, rand_fun) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :error -> {:halt, {:error, {:unknown_generator, name}}}
      end
    end)
  end

  defp generate("unique_slug", name, rand_fun), do: {:ok, "#{name}-#{hex(rand_fun, 4)}"}

  defp generate("random_email", _name, rand_fun), do: {:ok, "#{hex(rand_fun, 6)}@example.com"}

  defp generate("random_string:" <> length, _name, rand_fun) do
    case Integer.parse(length) do
      {n, ""} when n > 0 -> {:ok, random_string(rand_fun, n)}
      _ -> :error
    end
  end

  defp generate(_kind, _name, _rand_fun), do: :error

  defp hex(rand_fun, bytes), do: rand_fun.(bytes) |> Base.encode16(case: :lower)

  defp random_string(rand_fun, n) do
    size = length(@string_alphabet)
    for <<byte <- rand_fun.(n)>>, into: "", do: <<Enum.at(@string_alphabet, rem(byte, size))>>
  end

  defp placeholders(trace) do
    trace
    |> collect_strings([])
    |> Enum.flat_map(&Regex.scan(@placeholder_pattern, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp collect_strings(term, acc) when is_binary(term), do: [term | acc]

  defp collect_strings(term, acc) when is_map(term) do
    Enum.reduce(term, acc, fn {key, value}, acc ->
      acc |> then(&collect_strings(key, &1)) |> then(&collect_strings(value, &1))
    end)
  end

  defp collect_strings(term, acc) when is_list(term),
    do: Enum.reduce(term, acc, &collect_strings/2)

  defp collect_strings(_term, acc), do: acc

  defp deep_replace(term, generated) when is_binary(term) do
    Regex.replace(@placeholder_pattern, term, fn whole, name ->
      Map.get(generated, name, whole)
    end)
  end

  defp deep_replace(term, generated) when is_map(term) do
    Map.new(term, fn {key, value} ->
      {deep_replace(key, generated), deep_replace(value, generated)}
    end)
  end

  defp deep_replace(term, generated) when is_list(term) do
    Enum.map(term, &deep_replace(&1, generated))
  end

  defp deep_replace(term, _generated), do: term
end
