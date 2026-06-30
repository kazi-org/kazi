defmodule Kazi.Economy.PriceMap do
  @moduledoc """
  The single, dated price table that turns a `Kazi.CLI.Usage` token envelope into
  a `cost_usd` figure (T34.5, ADR-0046).

  ## One canonical, dated location

  Every per-token price kazi knows lives in `@prices` below, and the table is
  stamped with the date it was compiled (`as_of/0`). There is no second copy:
  the budget guard, the run-end KPIs, and the harness adapter all derive cost
  from this one map, so when a provider reprices, the fix is a single dated edit
  here. Prices are quoted in **US dollars per 1,000,000 tokens** — the unit every
  major provider publishes — so the entries read against the public price sheet
  without conversion.

  ## Omit, never guess (ADR-0046 honest-unknown discipline)

  `cost_usd/2` returns `{:ok, cost}` ONLY for a model present in the table; for a
  model the table does not name it returns `:error`, and the caller OMITS
  `cost_usd` from the usage envelope rather than reporting a fabricated number.
  A token count with no priced cost is honest; a guessed dollar figure is not.
  This is the same discipline `Kazi.Harness.Usage` applies to the token split:
  absent means unreported, never zero.

  ## What each token class costs

  The five token classes of the envelope are priced independently, because a
  provider prices them differently:

    * `input_tokens`        — fresh prompt input (full input rate);
    * `cached_input_tokens` — cache READS, billed far below fresh input
      (~0.1× input on the Anthropic models below) — the saving the T19.2 stable
      prefix and E35 stuck-bundle are meant to produce;
    * `cache_write_tokens`  — cache WRITES (the 5-minute-TTL write rate,
      ~1.25× input — the one-time cost of seeding the cache);
    * `output_tokens`       — generated output (full output rate);
    * `reasoning_tokens`    — extended-thinking tokens, billed at the output rate
      on the Anthropic models below.

  A token class absent from the envelope contributes nothing to the cost — it is
  a count of zero tokens spent on that class, not an unknown.

  ## Prices

  Anthropic public list pricing as of `as_of/0` (per 1M tokens), with cache reads
  at the documented ~0.1× input ratio and cache writes at the 5-minute-TTL
  ~1.25× input ratio. Update BOTH the entries and `@as_of` together when prices
  move; never edit one without the other.
  """

  alias Kazi.CLI.Usage

  @typedoc "A per-1M-token price sheet for one model, in USD."
  @type sheet :: %{
          input: number(),
          cached: number(),
          cache_write: number(),
          output: number(),
          reasoning: number()
        }

  # The date this table was compiled against the providers' published pricing.
  # Bump it in lockstep with any `@prices` edit so a stale table is self-evident.
  @as_of "2026-06-30"

  # Prices in USD per 1,000,000 tokens. Anthropic list pricing as of `@as_of`:
  # input/output from the published sheet; `cached` = input × 0.1 (cache-read
  # ratio); `cache_write` = input × 1.25 (5-minute-TTL write ratio); `reasoning`
  # = output (extended-thinking tokens bill at the output rate). Exact model ids
  # only — no alias resolution, so a typo's cost is omitted, not mispriced.
  @prices %{
    "claude-opus-4-8" => %{
      input: 5.00,
      cached: 0.50,
      cache_write: 6.25,
      output: 25.00,
      reasoning: 25.00
    },
    "claude-sonnet-4-6" => %{
      input: 3.00,
      cached: 0.30,
      cache_write: 3.75,
      output: 15.00,
      reasoning: 15.00
    },
    # List pricing (the introductory $2/$10 rate runs through 2026-08-31; this
    # table tracks list, not the promo, per the moduledoc's dated-table policy).
    "claude-sonnet-5" => %{
      input: 3.00,
      cached: 0.30,
      cache_write: 3.75,
      output: 15.00,
      reasoning: 15.00
    },
    "claude-haiku-4-5" => %{
      input: 1.00,
      cached: 0.10,
      cache_write: 1.25,
      output: 5.00,
      reasoning: 5.00
    },
    "claude-fable-5" => %{
      input: 10.00,
      cached: 1.00,
      cache_write: 12.50,
      output: 50.00,
      reasoning: 50.00
    }
  }

  # USD per 1M tokens -> USD per token.
  @per_million 1_000_000

  # The token classes this map prices, each paired with its `@prices` sheet key.
  # cost_usd is the one envelope field that is COMPUTED here, not priced.
  @priced_fields [
    {:input_tokens, :input},
    {:cached_input_tokens, :cached},
    {:cache_write_tokens, :cache_write},
    {:output_tokens, :output},
    {:reasoning_tokens, :reasoning}
  ]

  # Compile-time coupling guard: the token classes we price must be exactly the
  # token fields `Kazi.CLI.Usage` renders (its fields minus the computed
  # `cost_usd`). A rename or addition there fails the build HERE rather than
  # silently mispricing — keeping the cost model honest against the one renderer.
  @renderer_token_fields Usage.fields() -- [:cost_usd]
  unless Enum.sort(Enum.map(@priced_fields, &elem(&1, 0))) == Enum.sort(@renderer_token_fields) do
    raise "Kazi.Economy.PriceMap token classes drifted from Kazi.CLI.Usage: " <>
            "priced=#{inspect(Enum.map(@priced_fields, &elem(&1, 0)))} " <>
            "renderer=#{inspect(@renderer_token_fields)}"
  end

  @doc "The date (`YYYY-MM-DD`) the price table was last compiled against published pricing."
  @spec as_of() :: String.t()
  def as_of, do: @as_of

  @doc "The full price table, model id -> per-1M-token price sheet."
  @spec prices() :: %{optional(String.t()) => sheet()}
  def prices, do: @prices

  @doc "The model ids the table prices, sorted."
  @spec models() :: [String.t()]
  def models, do: @prices |> Map.keys() |> Enum.sort()

  @doc "Whether the table prices `model` (an exact-id match)."
  @spec known?(term()) :: boolean()
  def known?(model) when is_binary(model), do: Map.has_key?(@prices, model)
  def known?(_model), do: false

  @doc """
  Compute the `cost_usd` of a `Kazi.CLI.Usage` token envelope for `model`.

  Returns `{:ok, cost}` for a model present in the table, summing each token
  class at its own price; returns `:error` for any other model (the caller then
  OMITS `cost_usd` — never a guessed cost, ADR-0046).

  `usage` is the envelope shape (`%{input_tokens: …, cached_input_tokens: …,
  cache_write_tokens: …, output_tokens: …, reasoning_tokens: …}`), atom or string
  keys; a token class absent from the envelope costs nothing. The result is
  rounded to the nearest micro-dollar (6 dp) so repeated runs sum without
  binary-float drift in the last digits.
  """
  @spec cost_usd(term(), map()) :: {:ok, float()} | :error
  def cost_usd(model, usage) when is_binary(model) and is_map(usage) do
    case Map.fetch(@prices, model) do
      {:ok, sheet} -> {:ok, compute(sheet, usage)}
      :error -> :error
    end
  end

  def cost_usd(_model, _usage), do: :error

  # Sum each priced token class (price-per-1M × tokens ÷ 1M) and round to 6 dp.
  @spec compute(sheet(), map()) :: float()
  defp compute(sheet, usage) do
    cost =
      Enum.reduce(@priced_fields, 0.0, fn {field, price_key}, acc ->
        acc + tokens(usage, field) * Map.fetch!(sheet, price_key) / @per_million
      end)

    Float.round(cost, 6)
  end

  # Read a token field under its atom or string key; a missing or non-integer
  # value is 0 tokens for that class (it cost nothing), distinct from an unknown
  # MODEL (which omits cost entirely).
  @spec tokens(map(), atom()) :: non_neg_integer()
  defp tokens(usage, field) do
    case Map.get(usage, field, Map.get(usage, Atom.to_string(field))) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
