defmodule Kazi.ReadModel.DebriefHypothesis do
  @moduledoc """
  One row of the SELF-REPORT (hypothesis) tier of the economy feedback loop
  (T48.11, ADR-0058 §3): a single capped item the agent named, in an opted-in
  debrief answer, as something it needed but had to discover itself.

  This is a read-model projection like `Kazi.ReadModel.Iteration` — authoritative
  for nothing, rebuildable, and it exists ONLY as a hypothesis for later
  analysis. **WRITE-ONLY invariant**: nothing in kazi reads this table back into
  a prompt (`Kazi.Harness.Debrief.question/0` is a fixed string with no
  dependency on this schema) — a debrief answer never mutates a future dispatch
  (ADR-0058's gaming-surface rule, cf. T32.5). A later BENCHMARK-GATED tool
  (T48.10/T48.12) may read these rows to PROPOSE a prompt/context variant, but
  proposing is not the same as wiring it live.

  Fields:

    * `goal_ref` — the `Kazi.Goal.id` this hypothesis belongs to.
    * `run_id` — the fleet run registry id (`Kazi.Runtime`'s `Ecto.UUID`) the
      dispatch that produced it belongs to; `nil` when the loop is driven
      without a run identity (e.g. a bare `Kazi.Loop` in a test).
    * `iteration` — the 0-based per-goal iteration index the answer rides in on
      (mirrors `Kazi.ReadModel.Iteration.iteration_index`, but this is a
      separate table since one iteration can carry many hypothesis items).
    * `item` — one capped, redacted hypothesis string (`Kazi.Harness.Debrief`
      enforces `max_items/0` / `max_item_bytes/0` before this schema ever sees
      a row).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "debrief_hypotheses" do
    field(:goal_ref, :string)
    field(:run_id, :string)
    field(:iteration, :integer)
    field(:item, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:goal_ref, :iteration, :item]
  @optional [:run_id]

  @doc """
  Builds a changeset for inserting one hypothesis row.

  Validates the required fields and that `iteration` is non-negative. `run_id`
  is optional (nullable) — a debrief captured off a run-id-less loop still
  persists, honestly recorded as `nil` rather than a fabricated id.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(hypothesis, attrs) do
    hypothesis
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:iteration, greater_than_or_equal_to: 0)
  end
end
