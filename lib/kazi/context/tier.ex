defmodule Kazi.Context.Tier do
  @moduledoc """
  The context-budget tier ladder (ADR-0047 decision 2, T36.3): how MUCH context a
  reconcile dispatch assembles, named `0`–`4` and defaulting to **tier 1**.

  | Tier | Adds (cumulative)                   | Use when |
  |------|-------------------------------------|----------|
  | 0    | failing evidence only               | tiny obvious test failures |
  | 1    | + cached orientation pack (DEFAULT) | the default |
  | 2    | + code-review-graph MCP             | cross-file impact, refactors |
  | 3    | + semantic retrieval snippets       | ambiguous failures, missing local signal |
  | 4    | + compact repo snapshot             | architecture/design tasks, not repair loops |

  Tiers are **cumulative**: each adds its feature on top of every lower tier's, so
  a tier is a feature SET, exposed as `features/1`:

      %{orientation: boolean(), graph: boolean(), retrieval: boolean(), snapshot: boolean()}

  The active tier drives what `Kazi.Loop` assembles for a dispatch:

    * `orientation?/1` — gate the cached orientation prefix (ADR-0010 §3). Tier 0
      DROPS it; tier ≥ 1 keeps it (still subject to the T19.4 `:orientation_prefix`
      toggle).
    * `graph?/1` — gate the live code-review-graph MCP server in the dispatch
      surface (`Kazi.Harness.DispatchSurface`). Tier ≤ 1 EXCLUDES it (the agent has
      the cached orientation TEXT but cannot query the graph live); tier ≥ 2 exposes
      it.
    * `retrieval?/1` / `snapshot?/1` — gate the tier-3 retrieval snippets and the
      tier-4 compact repo snapshot. Named and selectable now; their richer content
      sources are wired in later tasks (the ladder is scaffolded, not stubbed).

  ## Default and escalation (why no policy lives here)

  The default is **tier 1** (`default/0`). ADR-0047 explicitly forbids shipping a
  guessed tier LADDER as proven: T36.3 only DEFINES the ladder and defaults to tier
  1. The escalation trigger (non-progress against the same failing set) and its
  thresholds are T36.4, gated on the E19/E34 benchmark. So this module is pure,
  total scaffolding — the names, the cumulative feature sets, the default, and the
  `:context_tier` opt resolution — with NO escalation policy baked in.

  The active tier is RESOLVED from a dispatch's adapter opts (`:context_tier`) by
  `resolve/1` and RECORDED per iteration in the ADR-0046 `context` envelope
  (`Kazi.Loop.Counters`), so a benchmark can attribute convergence/stuck outcomes
  to the tier it ran at.

  Pure and total: every function is a lookup over a fixed table; a malformed
  `:context_tier` never crashes a dispatch (`normalize/1` falls back to the
  default).
  """

  @typedoc "A context-budget tier: an integer in `0..4`."
  @type t :: 0..4

  @typedoc "The cumulative feature set a tier assembles."
  @type features :: %{
          orientation: boolean(),
          graph: boolean(),
          retrieval: boolean(),
          snapshot: boolean()
        }

  @min 0
  @max 4
  @default 1

  # The adapter-opt key a goal/operator sets to select a tier (threaded through
  # `adapter_opts`, like `:orientation_prefix` (T19.4) and `:retriever`).
  @opt_key :context_tier

  # The cumulative feature table. Tier N enables every feature tiers 0..N enable —
  # ordered orientation → graph → retrieval → snapshot, matching the ADR-0047 ladder.
  @features %{
    0 => %{orientation: false, graph: false, retrieval: false, snapshot: false},
    1 => %{orientation: true, graph: false, retrieval: false, snapshot: false},
    2 => %{orientation: true, graph: true, retrieval: false, snapshot: false},
    3 => %{orientation: true, graph: true, retrieval: true, snapshot: false},
    4 => %{orientation: true, graph: true, retrieval: true, snapshot: true}
  }

  @doc """
  The default context tier (ADR-0047: tier 1 — failing evidence + the cached
  orientation pack).

  ## Examples

      iex> Kazi.Context.Tier.default()
      1
  """
  @spec default() :: t()
  def default, do: @default

  @doc """
  The adapter-opt key that selects a tier (`:context_tier`).

  ## Examples

      iex> Kazi.Context.Tier.opt_key()
      :context_tier
  """
  @spec opt_key() :: atom()
  def opt_key, do: @opt_key

  @doc """
  The valid tier range, low → high.

  ## Examples

      iex> Kazi.Context.Tier.range()
      0..4
  """
  @spec range() :: Range.t()
  def range, do: @min..@max

  @doc """
  Whether `tier` is a defined tier (an integer in `0..4`).

  ## Examples

      iex> Kazi.Context.Tier.valid?(2)
      true
      iex> Kazi.Context.Tier.valid?(9)
      false
      iex> Kazi.Context.Tier.valid?("1")
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(tier) when is_integer(tier), do: tier >= @min and tier <= @max
  def valid?(_), do: false

  @doc """
  Coerce `tier` to a valid tier, falling back to the default for any
  out-of-range / non-integer value — a malformed `:context_tier` opt never crashes
  a dispatch, it conservatively assembles the default tier.

  ## Examples

      iex> Kazi.Context.Tier.normalize(3)
      3
      iex> Kazi.Context.Tier.normalize(42)
      1
      iex> Kazi.Context.Tier.normalize(:bogus)
      1
  """
  @spec normalize(term()) :: t()
  def normalize(tier) do
    if valid?(tier), do: tier, else: @default
  end

  @doc """
  Resolve the active tier from a dispatch's `adapter_opts` (`:context_tier`),
  defaulting to tier 1 when unset and normalizing any malformed value.

  ## Examples

      iex> Kazi.Context.Tier.resolve([])
      1
      iex> Kazi.Context.Tier.resolve(context_tier: 2)
      2
      iex> Kazi.Context.Tier.resolve(context_tier: 99)
      1
  """
  @spec resolve(keyword()) :: t()
  def resolve(adapter_opts) when is_list(adapter_opts) do
    case Keyword.get(adapter_opts, @opt_key) do
      nil -> @default
      tier -> normalize(tier)
    end
  end

  def resolve(_), do: @default

  @doc """
  The cumulative feature set `tier` assembles. A malformed tier normalizes first,
  so this is total.

  ## Examples

      iex> Kazi.Context.Tier.features(0)
      %{orientation: false, graph: false, retrieval: false, snapshot: false}
      iex> Kazi.Context.Tier.features(2)
      %{orientation: true, graph: true, retrieval: false, snapshot: false}
  """
  @spec features(term()) :: features()
  def features(tier), do: Map.fetch!(@features, normalize(tier))

  @doc """
  Whether `tier` assembles the cached orientation prefix (tier ≥ 1).

  ## Examples

      iex> Kazi.Context.Tier.orientation?(0)
      false
      iex> Kazi.Context.Tier.orientation?(1)
      true
  """
  @spec orientation?(term()) :: boolean()
  def orientation?(tier), do: features(tier).orientation

  @doc """
  Whether `tier` exposes the live code-review-graph MCP server (tier ≥ 2).

  ## Examples

      iex> Kazi.Context.Tier.graph?(1)
      false
      iex> Kazi.Context.Tier.graph?(2)
      true
  """
  @spec graph?(term()) :: boolean()
  def graph?(tier), do: features(tier).graph

  @doc """
  Whether `tier` appends the semantic retrieval snippets (tier ≥ 3).

  ## Examples

      iex> Kazi.Context.Tier.retrieval?(2)
      false
      iex> Kazi.Context.Tier.retrieval?(3)
      true
  """
  @spec retrieval?(term()) :: boolean()
  def retrieval?(tier), do: features(tier).retrieval

  @doc """
  Whether `tier` appends the compact repo snapshot (tier 4).

  ## Examples

      iex> Kazi.Context.Tier.snapshot?(3)
      false
      iex> Kazi.Context.Tier.snapshot?(4)
      true
  """
  @spec snapshot?(term()) :: boolean()
  def snapshot?(tier), do: features(tier).snapshot
end
