defmodule Kazi.Harness.Usage do
  @moduledoc """
  Maps a harness's RAW usage object onto the `Kazi.CLI.Usage` economy envelope,
  with a per-parse fidelity marker (T34.2, ADR-0046).

  A profile's `parse/1` carries the cached-vs-fresh token split T34.1 deferred:
  given the raw provider usage map and the profile's `{raw_key, envelope_field}`
  mapping, `map/2` returns the envelope-shaped subset plus a `fidelity/0`:

    * `:full`    — every field the profile's mapping names was reported.
    * `:partial` — at least one, but not all, were reported.
    * `:none`    — none were reported (the harness emitted no usable usage).

  The honest-unknown rule (ADR-0046): a field the harness did NOT report is
  OMITTED from the envelope, never zero-filled. A raw value of `0` IS a report
  (the provider sent the key as zero); a MISSING key is not — only present,
  non-negative integers map across. This keeps `absent == unreported` all the
  way from the provider envelope to the `--json` result, so a downstream reader
  never mistakes "unmeasured" for "zero spend".

  Pure: no I/O, no provider knowledge beyond the mapping its caller supplies.
  Each profile owns its mapping (the raw field names differ — Claude's Anthropic
  envelope vs. Codex's), but the target envelope and the fidelity discipline are
  shared, which is why this lives here rather than duplicated per profile.
  """

  @type fidelity :: :full | :partial | :none

  @doc """
  Map `raw` usage onto the envelope per `mapping`, returning `{envelope, fidelity}`.

  `mapping` is an ordered list of `{raw_key, envelope_field}` tuples naming the
  fields this profile can report. For each tuple whose `raw_key` holds a
  non-negative integer in `raw`, the value is placed under `envelope_field`;
  every other tuple is omitted. `fidelity` reflects how many of the mapping's
  fields were reported (all / some / none).
  """
  @spec map(map(), [{String.t(), atom()}]) :: {map(), fidelity()}
  def map(raw, mapping) when is_map(raw) and is_list(mapping) do
    {envelope, reported} =
      Enum.reduce(mapping, {%{}, 0}, fn {raw_key, env_key}, {acc, count} ->
        case Map.get(raw, raw_key) do
          n when is_integer(n) and n >= 0 -> {Map.put(acc, env_key, n), count + 1}
          _ -> {acc, count}
        end
      end)

    {envelope, fidelity(reported, length(mapping))}
  end

  @spec fidelity(non_neg_integer(), non_neg_integer()) :: fidelity()
  defp fidelity(0, _expected), do: :none
  defp fidelity(reported, expected) when reported >= expected, do: :full
  defp fidelity(_reported, _expected), do: :partial
end
