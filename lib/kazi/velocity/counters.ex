defmodule Kazi.Velocity.Counters do
  @moduledoc """
  T67.3 (ADR-0079 decision 2): the CLOSED aggregate-counter whitelist and the
  accumulator the session-stats collector folds a transcript into.

  This module is the ONE definition of what a session's counters ARE and, by
  `to_wire/2`, the ONE definition of what may cross a machine boundary or land in
  the read-model. It is the privacy boundary (R-E67-3): the struct holds ONLY
  aggregate numbers and window timestamps — never transcript content, prompt or
  response text, tool names, or file paths. `to_wire/2` emits a map whose keys are
  exactly `@wire_fields ++ @identity_fields`, so anything outside the whitelist is
  structurally unable to be shipped. `session_counters_wire_shape_test.exs` pins
  this.

  Honest-unknown (ADR-0046): `reasoning_tokens` starts `nil` and stays `nil` when a
  transcript never reports it — never coerced to 0. The token counters use the
  ADR-0046 cached-vs-fresh split (`input`/`cached_input`/`cache_write`/`output`) so
  they reconcile with `runs.budget_*` and `kazi economy`.

  `merge/2` combines two accumulators additively (cumulative counters), taking the
  min `first_observed_at` and max `last_observed_at`. The collector's incremental
  cursor carries an accumulator across passes; a fresh chunk parsed from bytes past
  the cursor is `merge`d in, so re-scanning yields identical totals (idempotency).
  """

  @typedoc "A UTC timestamp, or nil when no event has been observed yet."
  @type ts :: DateTime.t() | nil

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer() | nil,
          message_count: non_neg_integer(),
          tool_call_count: non_neg_integer(),
          active_time_s: non_neg_integer(),
          first_observed_at: ts(),
          last_observed_at: ts()
        }

  defstruct input_tokens: 0,
            cached_input_tokens: 0,
            cache_write_tokens: 0,
            output_tokens: 0,
            reasoning_tokens: nil,
            message_count: 0,
            tool_call_count: 0,
            active_time_s: 0,
            first_observed_at: nil,
            last_observed_at: nil

  # The CLOSED counter whitelist. NOTHING outside this list is a counter, and
  # `to_wire/2` will not emit a key outside `@wire_fields ++ @identity_fields`.
  @wire_fields [
    :input_tokens,
    :cached_input_tokens,
    :cache_write_tokens,
    :output_tokens,
    :reasoning_tokens,
    :message_count,
    :tool_call_count,
    :active_time_s,
    :first_observed_at,
    :last_observed_at
  ]

  # Session IDENTITY that rides alongside the counters. `session_uuid` is the E65
  # join key; `session_name` is a display alias; `machine` is the opted-in host.
  # These are identity, not transcript content — the privacy boundary forbids
  # CONTENT (text, tool names, file paths), not the session's own identity.
  @identity_fields [:session_uuid, :session_name, :machine]

  @doc "The closed list of counter field names (no identity, no content)."
  @spec wire_fields() :: [atom()]
  def wire_fields, do: @wire_fields

  @doc "The identity fields that accompany the counters on the wire."
  @spec identity_fields() :: [atom()]
  def identity_fields, do: @identity_fields

  @doc """
  Combine two accumulators additively. Token/event/active-time counters sum
  (nil-aware for the honest-unknown `reasoning_tokens`: nil + nil = nil, nil + n =
  n); the window takes the earliest `first_observed_at` and latest
  `last_observed_at`.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      cached_input_tokens: a.cached_input_tokens + b.cached_input_tokens,
      cache_write_tokens: a.cache_write_tokens + b.cache_write_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      reasoning_tokens: sum_optional(a.reasoning_tokens, b.reasoning_tokens),
      message_count: a.message_count + b.message_count,
      tool_call_count: a.tool_call_count + b.tool_call_count,
      active_time_s: a.active_time_s + b.active_time_s,
      first_observed_at: earliest(a.first_observed_at, b.first_observed_at),
      last_observed_at: latest(a.last_observed_at, b.last_observed_at)
    }
  end

  @doc """
  The wire/row payload: a map whose keys are EXACTLY the counter whitelist plus
  the session identity, timestamps rendered as ISO-8601 strings. This is the ONLY
  shape that crosses the daemon socket (as a bus fact and as the read-model
  insert attrs), so a content field cannot leak by construction.

  `identity` supplies `:session_uuid` (required), `:session_name`, `:machine`.
  """
  @spec to_wire(t(), map()) :: %{optional(atom()) => term()}
  def to_wire(%__MODULE__{} = c, identity) when is_map(identity) do
    counters =
      Map.new(@wire_fields, fn field ->
        {field, encode(Map.fetch!(c, field))}
      end)

    ident =
      Map.new(@identity_fields, fn field ->
        {field, Map.get(identity, field)}
      end)

    Map.merge(counters, ident)
  end

  @doc """
  The read-model insert attrs for `Kazi.ReadModel.SessionCounters` — the same
  whitelisted shape as `to_wire/2`, keyed by the schema's atoms. Built here so the
  schema and the wire share ONE whitelist.
  """
  @spec to_row(t(), map()) :: %{optional(atom()) => term()}
  def to_row(%__MODULE__{} = c, identity), do: to_wire(c, identity)

  defp encode(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode(other), do: other

  defp sum_optional(nil, nil), do: nil
  defp sum_optional(nil, b), do: b
  defp sum_optional(a, nil), do: a
  defp sum_optional(a, b), do: a + b

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
end
