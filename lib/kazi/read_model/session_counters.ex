defmodule Kazi.ReadModel.SessionCounters do
  @moduledoc """
  A row in the `session_counters` projection (T67.3, ADR-0079 decision 3): the
  per-session AGGREGATE counters the opt-in session-stats collector derives from
  a local harness transcript, keyed by the E65 session UUID. See
  `priv/repo/migrations/20260719000000_create_session_counters.exs`.

  Last-write-wins: the collector ships CUMULATIVE totals, so a re-post upserts on
  `(session_uuid, machine)` and duplicate ships collapse to one current row
  (ADR-0079 idempotency). Honest-unknown (ADR-0046): a token counter the
  transcript never exposes stays `nil`, never 0.

  PRIVACY BOUNDARY (R-E67-3): the field set here is the CLOSED counter whitelist —
  it holds no transcript content, prompt/response text, tool names, or file paths.
  The single source of truth for that whitelist is `Kazi.Velocity.Counters`, whose
  `to_row/2` builds this schema's attrs; `session_counters_wire_shape_test.exs`
  pins that nothing outside the whitelist can be persisted or shipped.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "session_counters" do
    field(:session_uuid, :string)
    field(:session_name, :string)
    field(:machine, :string)

    field(:input_tokens, :integer)
    field(:cached_input_tokens, :integer)
    field(:cache_write_tokens, :integer)
    field(:output_tokens, :integer)
    field(:reasoning_tokens, :integer)

    field(:message_count, :integer)
    field(:tool_call_count, :integer)
    field(:active_time_s, :integer)

    field(:first_observed_at, :utc_datetime_usec)
    field(:last_observed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:session_uuid]
  @optional [
    :session_name,
    :machine,
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

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:session_uuid, :machine],
      name: :session_counters_session_uuid_machine_index
    )
  end
end
