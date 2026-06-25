defmodule Kazi.CLI.Usage do
  @moduledoc """
  The economy-accounting `usage` envelope for kazi's `--json` result (T34.1,
  ADR-0046).

  Renders the per-run token/cost usage Claude (and other harnesses) report into a
  normalized, ADDITIVE object on the terminal result:

      { "usage": { "input_tokens": 0, "cached_input_tokens": 0,
        "cache_write_tokens": 0, "output_tokens": 0, "reasoning_tokens": 0,
        "cost_usd": 0.0 } }

  The field names mirror the Anthropic usage envelope (fresh input, cached-read
  input, cache-write, output, reasoning) plus the harness's own dollar figure.

  Every field is OPTIONAL: a harness that cannot report a component omits it, and
  the renderer drops absent fields rather than zero-filling them — *absent means
  unreported*, never "zero" (ADR-0046 honest-unknown discipline). An accumulator
  that reported nothing renders the empty map, and the caller omits the `usage`
  key entirely.

  This envelope is strictly additive to the `--json` contract, so `schema_version`
  does NOT bump — the same compatibility rule the ADR-0041 predicate envelope v2
  followed (`docs/schemas/run-result.md` §Compatibility). An orchestrator pinning
  the pre-envelope contract keeps reading `budget_spent.tokens` (the single
  rolled-up total) and ignores the richer split.

  T34.2 maps each harness profile's raw usage onto these fields (with a fidelity
  marker); T34.1 defines the envelope, its renderer, and the additive wiring.
  """

  # The envelope fields, in rendered order. The five token fields mirror the
  # Anthropic usage shape; `cost_usd` is the harness's reported dollar figure.
  @fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cost_usd
  ]

  @doc "The envelope's field names, in rendered order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Render a usage accumulator into the additive `usage` envelope, keeping ONLY the
  fields that were reported (a non-nil value). An absent or `nil` field is omitted,
  never zero-filled — `absent == unreported`. Accepts atom or string keys.

  Returns a (possibly empty) map; the caller omits the `usage` key when it is empty
  (`map_size(render(...)) == 0`).
  """
  @spec render(map()) :: map()
  def render(usage) when is_map(usage) do
    Enum.reduce(@fields, %{}, fn field, acc ->
      case fetch(usage, field) do
        :error -> acc
        {:ok, value} -> Map.put(acc, field, value)
      end
    end)
  end

  # Read a field under its atom or string key; a missing or nil value is `:error`
  # (unreported), so the renderer omits it.
  defp fetch(usage, field) do
    case Map.get(usage, field, Map.get(usage, Atom.to_string(field))) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end
