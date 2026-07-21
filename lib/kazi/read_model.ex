defmodule Kazi.ReadModel do
  @moduledoc """
  The read side of the iteration / evidence log (concept §5, §7).

  `Kazi.ReadModel` is the small API the loop (T0.7) uses to *record* each
  iteration into the local SQLite read-model, and that history (T1.1) and
  convergence analytics use to *read* it back. It owns the translation between
  kazi's in-memory domain shapes (`Kazi.PredicateVector`, `Kazi.Action`) and the
  JSON columns of `Kazi.ReadModel.Iteration`:

    * a `Kazi.PredicateVector` round-trips through `predicate_vector` as
      `%{"<id>" => %{"status" => "<status>", "evidence" => <evidence>}}`;
    * a `Kazi.Action` is flattened into `action_kind` + `action_params`.

  The store is never authoritative — it is a rebuildable projection of the
  `kazi.events` log (concept §7). Recording is therefore best understood as
  *projecting an already-true event*, not as deciding anything.
  """

  @behaviour Kazi.Context.Cache
  @behaviour Kazi.Retrieval.Cache

  import Ecto.Query, only: [from: 2]

  alias Kazi.Context.Pack
  alias Kazi.{Action, PredicateResult, PredicateVector, Repo}

  alias Kazi.ReadModel.{
    DebriefHypothesis,
    GoalGapFields,
    GoalProgressRate,
    GoalSummary,
    Iteration,
    LandedRef,
    OrientationPackCache,
    PredicateAudit,
    ProposedGoal,
    ProposedMemory,
    RetrievalSnippetCache,
    Run,
    RunRegistry,
    Writer
  }

  alias Kazi.Retrieval.Snippet

  # The PubSub topic the read-model broadcasts an iteration record on (T3.6b,
  # ADR-0011). The goal board LiveView subscribes to it so a freshly recorded
  # iteration pushes a live update without polling. The payload is
  # `{:iteration_recorded, goal_ref}`. Exposed via `goal_board_topic/0`.
  @goal_board_topic "read_model:goal_board"

  @typedoc """
  Attributes for `record_iteration/1`. `:goal_ref` and `:iteration_index` are
  required; `:predicate_vector` accepts a `Kazi.PredicateVector` (or a plain map
  of `id => PredicateResult`); `:action` accepts a `Kazi.Action` (or `nil`).
  """
  @type record_attrs :: %{
          required(:goal_ref) => Kazi.Goal.id(),
          required(:iteration_index) => non_neg_integer(),
          optional(:predicate_vector) => PredicateVector.t() | map(),
          optional(:action) => Action.t() | nil,
          optional(:converged) => boolean(),
          optional(:regressions) => [map()],
          optional(:release_ref) => String.t() | nil,
          optional(:context) => map(),
          optional(:tools) => map(),
          optional(:observed_at) => DateTime.t()
        }

  @doc """
  Records (projects) one convergence-loop iteration into the read-model.

  Serializes the predicate vector and action into the row's JSON columns and
  inserts it. Returns `{:ok, iteration}` or `{:error, changeset}` (e.g. a
  duplicate `(goal_ref, iteration_index)`).

  `:converged` defaults to whether the supplied vector is satisfied
  (`PredicateVector.satisfied?/1`); pass it explicitly to override. `:observed_at`
  defaults to now.
  """
  @spec record_iteration(record_attrs()) ::
          {:ok, Iteration.t()} | {:error, Ecto.Changeset.t() | :read_model_unavailable}
  def record_iteration(attrs) do
    Kazi.ReadModel.Guard.run("iteration record", fn -> do_record_iteration(attrs) end)
  end

  defp do_record_iteration(attrs) do
    vector = normalize_vector(Map.get(attrs, :predicate_vector, PredicateVector.new()))
    action = Map.get(attrs, :action)
    observed_at = Map.get(attrs, :observed_at, DateTime.utc_now())
    converged = Map.get_lazy(attrs, :converged, fn -> PredicateVector.satisfied?(vector) end)

    row = %{
      goal_ref: to_string(Map.fetch!(attrs, :goal_ref)),
      iteration_index: Map.fetch!(attrs, :iteration_index),
      predicate_vector: serialize_vector(vector),
      converged: converged,
      action_kind: action && to_string(action.kind),
      action_params: serialize_action_params(action),
      # T1.2 regression: serialize the green→red flags for this observation.
      regressions: serialize_regressions(Map.get(attrs, :regressions, [])),
      # T3.3c release tagging: the release ref recorded on a successful deploy.
      release_ref: Map.get(attrs, :release_ref),
      # T34.3 (ADR-0046 §2): the per-iteration context + tool counters, serialized
      # JSON-safe (string keys; values are already strings/integers). Absent ⇒ %{}.
      context: serialize_counters(Map.get(attrs, :context, %{})),
      tools: serialize_counters(Map.get(attrs, :tools, %{})),
      observed_at: observed_at
    }

    result =
      %Iteration{}
      |> Iteration.changeset(row)
      |> Writer.insert(insert_opts(attrs))

    # T3.6b (ADR-0011): on a successful record, broadcast on the goal-board topic
    # so a subscribed dashboard LiveView re-reads and pushes a live diff. This is
    # an additive, fire-and-forget projection signal — the loop neither waits on
    # nor depends on a subscriber, so the read path stays decoupled from the core
    # (the dashboard subscribes; the loop does not call into it). Broadcasting is
    # best-effort: a missing PubSub (e.g. the escript, which boots no web tree)
    # must not fail a record.
    with {:ok, iteration} <- result do
      broadcast_iteration_recorded(iteration.goal_ref)
    end

    result
  end

  # T18.3: a terminal projection (the loop's stuck-stop reuses the LAST observed
  # `iteration_index`; see Kazi.Loop.notify_stuck_stop) re-records an index that
  # the normal observation already wrote, hitting the `(goal_ref, iteration_index)`
  # unique index and erroring. When the caller marks the record `upsert?: true`
  # (the terminal/budget-stop path does, keyed off `:stop_reason`), replace the
  # mutable columns so the final state lands idempotently. Normal records omit the
  # flag and keep the duplicate-rejecting contract.
  @upsert_replace_columns [
    :predicate_vector,
    :converged,
    :action_kind,
    :action_params,
    :regressions,
    :release_ref,
    # T34.3 (ADR-0046 §2): a terminal upsert (stuck/budget stop) replaces the
    # context + tool counters with the final dispatch's, keeping the row current.
    :context,
    :tools,
    :observed_at,
    :updated_at
  ]

  defp insert_opts(attrs) do
    if Map.get(attrs, :upsert?, false) do
      [
        on_conflict: {:replace, @upsert_replace_columns},
        conflict_target: [:goal_ref, :iteration_index]
      ]
    else
      []
    end
  end

  @doc """
  The Phoenix.PubSub topic the read-model broadcasts iteration records on
  (T3.6b). Subscribe to it to receive `{:iteration_recorded, goal_ref}` whenever
  `record_iteration/1` persists a new iteration.
  """
  @spec goal_board_topic() :: String.t()
  def goal_board_topic, do: @goal_board_topic

  defp broadcast_iteration_recorded(goal_ref) do
    # The dashboard's PubSub server is supervised only when the web tree boots
    # (Kazi.Application). When it isn't running (escript / non-web contexts), the
    # broadcast is a no-op rather than a crash.
    if Process.whereis(Kazi.PubSub) do
      Phoenix.PubSub.broadcast(
        Kazi.PubSub,
        @goal_board_topic,
        {:iteration_recorded, goal_ref}
      )
    end

    :ok
  end

  @doc """
  Lists the recorded iterations for a goal, in ascending `iteration_index`
  order (the history T1.1 reads).
  """
  @spec list_iterations(Kazi.Goal.id()) :: [Iteration.t()]
  def list_iterations(goal_ref) do
    ref = to_string(goal_ref)

    Repo.all(
      from(i in Iteration,
        where: i.goal_ref == ^ref,
        order_by: [asc: i.iteration_index]
      )
    )
  end

  @doc """
  Returns the goal's full per-iteration vector history (T1.1) read back from the
  read-model: a list of `{iteration_index, Kazi.PredicateVector.t()}` in
  ascending `iteration_index` (oldest-first).

  This is the DB-side counterpart to `Kazi.Loop.history/1` (which serves the same
  shape from the running loop's in-memory state): the regression (T1.2) and stuck
  (T1.5) detectors read either, depending on whether they analyse a live loop or
  a persisted run. Vectors are keyed by string predicate ids (their on-disk
  form), as rehydrated by `to_predicate_vector/1`.
  """
  @spec iteration_history(Kazi.Goal.id()) :: [{non_neg_integer(), PredicateVector.t()}]
  def iteration_history(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.map(fn %Iteration{iteration_index: index} = iteration ->
      {index, to_predicate_vector(iteration)}
    end)
  end

  @doc """
  Returns the goal's recorded regression flags (T1.2) across all iterations, in
  ascending `iteration_index` order: a list of `{iteration_index, [flag]}` for
  every iteration that flagged at least one regression. Iterations with no
  regression are omitted (empty result means the goal never regressed).

  Each flag is the string-keyed on-disk form of `Kazi.Loop.RegressionDetector`'s
  flag: `%{"predicate_id", "green_iteration", "red_iteration", "status",
  "attributed_dispatch"}`. This is the queryable surface acceptance #2 requires —
  a regression recorded by the loop is readable back from the read-model.
  """
  @spec regressions(Kazi.Goal.id()) :: [{non_neg_integer(), [map()]}]
  def regressions(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.flat_map(fn %Iteration{iteration_index: index, regressions: regressions} ->
      case regressions || [] do
        [] -> []
        flags -> [{index, flags}]
      end
    end)
  end

  @doc """
  Returns the goal's recorded release refs (T3.3c, UC-015) across all
  iterations, in ascending `iteration_index` order: a list of
  `{iteration_index, release_ref}` for every iteration that recorded one.
  Iterations with no release ref are omitted (empty result means the goal never
  deployed an artifact whose release was tagged).

  This is the queryable surface acceptance #2 requires — a release tagged on a
  successful deploy is readable back from the read-model.
  """
  @spec release_refs(Kazi.Goal.id()) :: [{non_neg_integer(), String.t()}]
  def release_refs(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.flat_map(fn %Iteration{iteration_index: index, release_ref: ref} ->
      case ref do
        nil -> []
        "" -> []
        ref -> [{index, ref}]
      end
    end)
  end

  @typedoc """
  Attributes for `record_debrief_hypotheses/1`. `:goal_ref`, `:iteration`, and
  `:items` are required; `:run_id` is optional (nullable — recorded honestly as
  `nil` when the loop is driven without a run identity).
  """
  @type debrief_attrs :: %{
          required(:goal_ref) => Kazi.Goal.id(),
          required(:iteration) => non_neg_integer(),
          required(:items) => [String.t()],
          optional(:run_id) => String.t() | nil
        }

  @doc """
  Records (projects) one debrief answer's items as hypothesis rows (T48.11,
  ADR-0058 §3) — one row per item in `:items`. `:items` is expected to already
  be capped/redacted (`Kazi.Harness.Debrief.extract/1` does this); an empty list
  is a no-op (`{:ok, []}`), so a goal with debrief enabled but no items reported
  this iteration writes nothing rather than an empty marker row.

  **WRITE-ONLY.** This function only INSERTS. There is no corresponding read
  path wired into any prompt-building code — see the write-only invariant on
  `Kazi.ReadModel.DebriefHypothesis` and `Kazi.Harness.Debrief`.
  """
  @spec record_debrief_hypotheses(debrief_attrs()) ::
          {:ok, [DebriefHypothesis.t()]} | {:error, Ecto.Changeset.t()}
  def record_debrief_hypotheses(%{items: items} = attrs) when is_list(items) do
    goal_ref = to_string(Map.fetch!(attrs, :goal_ref))
    iteration = Map.fetch!(attrs, :iteration)
    run_id = Map.get(attrs, :run_id)

    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      row = %{goal_ref: goal_ref, run_id: run_id, iteration: iteration, item: item}

      case %DebriefHypothesis{} |> DebriefHypothesis.changeset(row) |> Writer.insert() do
        {:ok, hypothesis} -> {:cont, {:ok, [hypothesis | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hypotheses} -> {:ok, Enum.reverse(hypotheses)}
      error -> error
    end
  end

  @doc """
  Returns the goal's recorded debrief hypotheses (T48.11), in ascending
  `iteration` order. Read-only tooling surface for a later analysis pass
  (T48.10/T48.12) — never consumed by prompt construction.
  """
  @spec list_debrief_hypotheses(Kazi.Goal.id()) :: [DebriefHypothesis.t()]
  def list_debrief_hypotheses(goal_ref) do
    Repo.all(
      from(h in DebriefHypothesis,
        where: h.goal_ref == ^to_string(goal_ref),
        order_by: [asc: h.iteration, asc: h.id]
      )
    )
  end

  @doc """
  Fetches one iteration by `(goal_ref, iteration_index)`, or `nil`.
  """
  @spec get_iteration(Kazi.Goal.id(), non_neg_integer()) :: Iteration.t() | nil
  def get_iteration(goal_ref, iteration_index) do
    ref = to_string(goal_ref)
    Repo.get_by(Iteration, goal_ref: ref, iteration_index: iteration_index)
  end

  @doc """
  Returns the most recently recorded iteration for a goal (highest
  `iteration_index`), or `nil` if none has been recorded.
  """
  @spec latest_iteration(Kazi.Goal.id()) :: Iteration.t() | nil
  def latest_iteration(goal_ref) do
    ref = to_string(goal_ref)

    Repo.one(
      from(i in Iteration,
        where: i.goal_ref == ^ref,
        order_by: [desc: i.iteration_index],
        limit: 1
      )
    )
  end

  # --- landed-ref store (T62.6, issue #1241 part 2) --------------------------

  @doc """
  Records (projects) a run's per-group landed refs into the read-model so
  `kazi status <run-ref>` can show the same per-group `{branch, pr,
  merge_commit}` landing detail AFTER the run exits that the immediate
  `apply --parallel` output carried (T62.6, issue #1241 part 2).

  `entries` is a list of `%{partition_id, branch, pr, merge_commit}` maps (a
  `--parallel` run supplies one per landed group; a single-goal landing one with
  `partition_id: ""`). Each entry UPSERTS on `(run_ref, partition_id)`, so
  re-running the same goal overwrites its prior landed refs rather than
  accumulating stale rows. Reuses T44.3/T44.10's landed-ref shape — one storage
  mechanism for both single-goal and parallel landing, not a parallel side
  table.

  Best-effort like every projection: a degraded read-model (`Guard`) returns
  `{:error, :read_model_unavailable}` and never fails the run — including when
  the guarded write dies from an exit it cannot catch, which `Guard.run/3`
  contains in an unlinked worker rather than propagating (#1652).
  """
  @spec record_landed_refs(Kazi.Goal.id(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_landed_refs(run_ref, entries) when is_list(entries) do
    Kazi.ReadModel.Guard.run("landed-refs record", fn ->
      do_record_landed_refs(to_string(run_ref), entries)
    end)
  end

  defp do_record_landed_refs(run_ref, entries) do
    now = DateTime.utc_now()

    count =
      Enum.reduce(entries, 0, fn entry, acc ->
        row = %{
          run_ref: run_ref,
          partition_id: to_string(Map.get(entry, :partition_id, "")),
          branch: ref_string(Map.get(entry, :branch)),
          pr: ref_string(Map.get(entry, :pr)),
          merge_commit: ref_string(Map.get(entry, :merge_commit)),
          inserted_at: now,
          updated_at: now
        }

        case %LandedRef{}
             |> LandedRef.changeset(row)
             |> Writer.insert(
               on_conflict: {:replace, [:branch, :pr, :merge_commit, :updated_at]},
               conflict_target: [:run_ref, :partition_id]
             ) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  # A landed ref value is stored as text; a PR handle the integrator returned as
  # an integer (a `gh` PR number) is stringified. nil stays nil (honest-unknown).
  defp ref_string(nil), do: nil
  defp ref_string(v) when is_binary(v), do: v
  defp ref_string(v), do: to_string(v)

  @doc """
  Lists a run's persisted per-group landed refs (T62.6), ordered by
  `partition_id` for a deterministic surface. Empty list for a run that never
  landed (or a pre-T62.6 row) — never an error.
  """
  @spec landed_refs(Kazi.Goal.id()) :: [LandedRef.t()]
  def landed_refs(run_ref) do
    ref = to_string(run_ref)

    Repo.all(
      from(l in LandedRef,
        where: l.run_ref == ^ref,
        order_by: [asc: l.partition_id]
      )
    )
  end

  # --- predicate mutation audit store (T68.9, #1501) -------------------------

  @doc """
  Records a goal's sampled predicate mutation audit (T68.9, #1501) — the
  verification-of-verification score from `Kazi.Audit.PredicateSensitivity`.

  `summary` is that module's `t/0` map (`:tested`, `:constrained`, `:survived`,
  `:sensitivity`, `:survivors`). UPSERTS on `goal_ref` (last-write-wins), so a
  re-audit overwrites the goal's prior score rather than accumulating rows.
  `:sensitivity` persists NULL when the audit had nothing to test (honest-unknown,
  ADR-0046). Best-effort like every projection: a degraded read-model returns
  `{:error, :read_model_unavailable}` and never fails the caller — a guarantee
  that holds whether or not the caller traps exits, because `Guard.run/3` runs
  the write in an unlinked monitored worker (#1652).
  """
  @spec record_predicate_audit(Kazi.Goal.id(), map()) ::
          {:ok, PredicateAudit.t()} | {:error, term()}
  def record_predicate_audit(goal_ref, summary) when is_map(summary) do
    Kazi.ReadModel.Guard.run("predicate-audit record", fn ->
      do_record_predicate_audit(to_string(goal_ref), summary)
    end)
  end

  defp do_record_predicate_audit(goal_ref, summary) do
    now = DateTime.utc_now()

    row = %{
      goal_ref: goal_ref,
      tested: Map.fetch!(summary, :tested),
      constrained: Map.fetch!(summary, :constrained),
      survived: Map.fetch!(summary, :survived),
      sensitivity: Map.get(summary, :sensitivity),
      survivors: encode_survivors(Map.get(summary, :survivors, [])),
      sampled_at: now,
      inserted_at: now,
      updated_at: now
    }

    %PredicateAudit{}
    |> PredicateAudit.changeset(row)
    |> Writer.insert(
      on_conflict:
        {:replace,
         [:tested, :constrained, :survived, :sensitivity, :survivors, :sampled_at, :updated_at]},
      conflict_target: :goal_ref,
      returning: true
    )
  end

  # Survivor ids are stored as a JSON array of strings so the audit surface can
  # name the weak/gamed predicates. Stringified for a stable on-disk form.
  defp encode_survivors(survivors) when is_list(survivors) do
    Jason.encode!(Enum.map(survivors, &to_string/1))
  end

  @doc """
  The goal's most recent predicate mutation audit (T68.9, #1501), or `nil` when
  it has never been audited. A pure read.
  """
  @spec latest_predicate_audit(Kazi.Goal.id()) :: PredicateAudit.t() | nil
  def latest_predicate_audit(goal_ref) do
    Repo.get_by(PredicateAudit, goal_ref: to_string(goal_ref))
  end

  @doc """
  Decodes a `PredicateAudit` row's `survivors` JSON back to a list of predicate
  id strings (empty list when absent or unparseable).
  """
  @spec audit_survivors(PredicateAudit.t()) :: [String.t()]
  def audit_survivors(%PredicateAudit{survivors: nil}), do: []

  def audit_survivors(%PredicateAudit{survivors: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # --- proposed-goal store (T3.5a authoring / T3.5b approval) ----------------

  @doc """
  Fetches one proposed-goal row by its `proposal_ref` (the review handle), or
  `nil`. The approval workflow (T3.5b) reads the current row through this to know
  the proposal's lifecycle state before transitioning it.
  """
  @spec get_proposed_goal(String.t()) :: ProposedGoal.t() | nil
  def get_proposed_goal(proposal_ref) when is_binary(proposal_ref) do
    Repo.get_by(ProposedGoal, proposal_ref: proposal_ref)
  end

  @doc """
  Lists proposed-goal rows, newest first, optionally filtered by lifecycle
  `status` (`"proposed"` / `"approved"` / `"rejected"`).

  This is the queryable surface an operator surface (the CLI T3.5c or the
  dashboard) reviews proposals through: with no `:status` it returns every
  proposal; `status: "proposed"` is the review queue, `status: "approved"` the
  goals now runnable by `Kazi.Runtime`.
  """
  @spec list_proposed_goals(keyword()) :: [ProposedGoal.t()]
  def list_proposed_goals(opts \\ []) when is_list(opts) do
    base = from(p in ProposedGoal, order_by: [desc: p.inserted_at, desc: p.id])

    query =
      case Keyword.get(opts, :status) do
        nil -> base
        status -> from(p in base, where: p.status == ^to_string(status))
      end

    Repo.all(query)
  end

  @doc """
  Lists the proposed goals sharing `roadmap_ref` (T45.2, UC-059), in stable id
  order — the member proposals a single `kazi plan --project` payload drafted.
  `[]` for an unknown ref.
  """
  @spec list_proposed_goals_by_roadmap(String.t()) :: [ProposedGoal.t()]
  def list_proposed_goals_by_roadmap(roadmap_ref) when is_binary(roadmap_ref) do
    Repo.all(
      from(p in ProposedGoal, where: p.roadmap_ref == ^roadmap_ref, order_by: [asc: p.goal_id])
    )
  end

  @doc """
  Persists an approval-workflow transition (T3.5b) on the proposed-goal row
  identified by `proposal_ref`: a new `status` and the (possibly refreshed)
  serialized `goal` payload.

  Returns `{:ok, row}`, `{:error, :not_found}` when no proposal carries that ref,
  or `{:error, changeset}` on a validation failure. The valid-transition guard is
  enforced by `Kazi.Authoring`; this only writes the already-validated state.
  """
  @spec transition_proposed_goal(String.t(), String.t(), map()) ::
          {:ok, ProposedGoal.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def transition_proposed_goal(proposal_ref, status, goal)
      when is_binary(proposal_ref) and is_binary(status) and is_map(goal) do
    case get_proposed_goal(proposal_ref) do
      nil ->
        {:error, :not_found}

      %ProposedGoal{} = row ->
        row
        |> ProposedGoal.transition_changeset(%{status: status, goal: goal})
        |> Writer.update()
    end
  end

  # --- proposed-memory store (ADR-0063 Slice 3: gated harvest + promotion) --

  @doc """
  Records (projects) one memory candidate `Kazi.Memory.Harvest` detected as a
  proposed-memory row, IDEMPOTENTLY keyed by `attrs[:fingerprint]` (ADR-0063
  decision 3: a candidate is never re-proposed). A row already carrying that
  fingerprint -- `proposed`, `approved`, or `rejected` -- is returned as-is;
  only a genuinely new fingerprint inserts.

  Returns `{:ok, row}` (new or pre-existing) or `{:error, changeset}` on a
  validation failure.
  """
  @spec propose_memory(map()) :: {:ok, ProposedMemory.t()} | {:error, Ecto.Changeset.t()}
  def propose_memory(attrs) when is_map(attrs) do
    fingerprint = Map.get(attrs, :fingerprint) || Map.get(attrs, "fingerprint")

    case Repo.get_by(ProposedMemory, fingerprint: fingerprint) do
      nil -> %ProposedMemory{} |> ProposedMemory.changeset(attrs) |> Writer.insert()
      %ProposedMemory{} = existing -> {:ok, existing}
    end
  end

  @doc """
  Fetches one proposed-memory row by its `proposal_ref` (the review handle),
  or `nil`.
  """
  @spec get_proposed_memory(String.t()) :: ProposedMemory.t() | nil
  def get_proposed_memory(proposal_ref) when is_binary(proposal_ref) do
    Repo.get_by(ProposedMemory, proposal_ref: proposal_ref)
  end

  @doc """
  Lists proposed-memory rows, newest first, optionally filtered by lifecycle
  `status` (`"proposed"` / `"approved"` / `"rejected"`) -- the review queue
  `kazi memory list-proposed` reads.
  """
  @spec list_proposed_memories(keyword()) :: [ProposedMemory.t()]
  def list_proposed_memories(opts \\ []) when is_list(opts) do
    base = from(m in ProposedMemory, order_by: [desc: m.inserted_at, desc: m.id])

    query =
      case Keyword.get(opts, :status) do
        nil -> base
        status -> from(m in base, where: m.status == ^to_string(status))
      end

    Repo.all(query)
  end

  @doc """
  Transitions a proposed-memory row identified by `proposal_ref` to `status`
  (`"approved"` / `"rejected"`). Only a `"proposed"` row may transition; an
  already-`approved`/`rejected` row refuses with `{:error, {:invalid_transition,
  from, to}}` so a proposal's terminal state can never be silently overwritten.

  Returns `{:ok, row}`, `{:error, :not_found}` when no proposal carries that
  ref, `{:error, {:invalid_transition, from, to}}`, or `{:error, changeset}`
  on a validation failure.
  """
  @spec transition_proposed_memory(String.t(), String.t()) ::
          {:ok, ProposedMemory.t()}
          | {:error,
             :not_found | {:invalid_transition, String.t(), String.t()} | Ecto.Changeset.t()}
  def transition_proposed_memory(proposal_ref, status)
      when is_binary(proposal_ref) and is_binary(status) do
    case get_proposed_memory(proposal_ref) do
      nil ->
        {:error, :not_found}

      %ProposedMemory{status: "proposed"} = row ->
        row |> ProposedMemory.transition_changeset(%{status: status}) |> Writer.update()

      %ProposedMemory{status: current} ->
        {:error, {:invalid_transition, current, status}}
    end
  end

  @doc """
  Summarises every goal that has at least one recorded iteration, newest-active
  first — the goal board's data source (T3.6b, UC-018, ADR-0011).

  Each `Kazi.ReadModel.GoalSummary` carries the goal ref, a derived lifecycle
  `status`, the goal's latest `Kazi.PredicateVector`, the iteration count, and
  when it was last observed. The board renders one row per summary; an empty list
  is the board's empty state.

  Goals are ordered by `last_observed_at` descending (most-recently-active
  first), so a freshly recorded iteration floats its goal to the top. This is a
  pure read over the iterations projection — it never touches the loop or harness.
  """
  @spec list_goals() :: [GoalSummary.t()]
  def list_goals do
    # One pass over the projection grouped by goal_ref: count, latest index, and
    # latest observation per goal. SQLite has no DISTINCT ON, so we fetch the
    # per-goal aggregates first, then load each goal's latest iteration row to
    # rehydrate its vector and converged flag.
    aggregates =
      Repo.all(
        from(i in Iteration,
          group_by: i.goal_ref,
          select: %{
            goal_ref: i.goal_ref,
            iteration_count: count(i.id),
            latest_index: max(i.iteration_index),
            last_observed_at: max(i.observed_at)
          }
        )
      )

    aggregates
    |> Enum.map(&build_goal_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.last_observed_at, {:desc, DateTime})
  end

  # A concurrent invalidate/reset between the aggregate scan (above) and this
  # per-goal fetch can delete the iteration `get_iteration/2` expects, yielding
  # `nil` — guard it and skip the summary rather than crashing the whole board
  # render on a race (deep review L7).
  defp build_goal_summary(%{
         goal_ref: goal_ref,
         iteration_count: iteration_count,
         latest_index: latest_index,
         last_observed_at: last_observed_at
       }) do
    case get_iteration(goal_ref, latest_index) do
      nil ->
        nil

      latest ->
        vector = to_predicate_vector(latest)

        %GoalSummary{
          goal_ref: goal_ref,
          status: derive_status(latest, vector),
          latest_vector: vector,
          iteration_count: iteration_count,
          last_observed_at: last_observed_at
        }
    end
  end

  # The board's lifecycle status is derived from the latest iteration, not stored:
  # a converged latest iteration is :converged; otherwise the goal is still
  # :in_progress. (Richer states — :stuck, :over_budget — are a later read once
  # the loop persists its terminal reason; the board surfaces the objective
  # convergence signal it already records, T0.8.)
  defp derive_status(%Iteration{converged: true}, _vector), do: :converged
  defp derive_status(%Iteration{}, _vector), do: :in_progress

  @doc """
  Projects the three T63.3 gap-list field groups for a goal (E63, UC-062,
  ADR-0011 — projection only): narrative-intent per iteration, display grouping
  tags for the latest vector's predicate ids, and a per-goal tally of iterations
  missing their tool/context counters. See `Kazi.ReadModel.GoalGapFields` for the
  shape and the honest-unknown rules.

  Absent data is surfaced as explicit `nil`/empty, never a fabricated value: a
  goal with no recorded iterations yields empty narrative + groups and a zeroed
  `total_iterations`; an observe-only iteration contributes a `nil` `action_kind`;
  a predicate id with no separable prefix maps to a `nil` group. This is a pure
  read over the iterations projection — it never touches the loop or a write path.
  """
  @spec goal_gap_fields(Kazi.Goal.id()) :: GoalGapFields.t()
  def goal_gap_fields(goal_ref) do
    ref = to_string(goal_ref)
    iterations = list_iterations(ref)

    narrative_intent =
      Enum.map(iterations, fn %Iteration{} = it ->
        %{
          iteration_index: it.iteration_index,
          action_kind: it.action_kind,
          action_params: it.action_params || %{}
        }
      end)

    predicate_groups =
      case List.last(iterations) do
        nil ->
          %{}

        latest ->
          %PredicateVector{results: results} = to_predicate_vector(latest)

          Map.new(results, fn {id, _result} ->
            id = to_string(id)
            {id, GoalGapFields.group_for(id)}
          end)
      end

    missing_counters = %{
      tools_missing: Enum.count(iterations, &(map_size(&1.tools) == 0)),
      context_missing: Enum.count(iterations, &(map_size(&1.context) == 0)),
      total_iterations: length(iterations)
    }

    %GoalGapFields{
      goal_ref: ref,
      narrative_intent: narrative_intent,
      predicate_groups: predicate_groups,
      missing_counters: missing_counters
    }
  end

  # The recent iteration TRANSITIONS the flip-velocity figure is measured over.
  # A window, not the whole history, so the "how fast is it greening lately"
  # answer reflects recent momentum rather than being diluted by an old run.
  @flip_window 5

  @doc """
  Projects the per-goal progress-RATE fields for the mission-control "how long
  until done" panel (E63/T63.9, UC-061/UC-068, ADR-0011 — projection only, no
  write path). Returns a `Kazi.ReadModel.GoalProgressRate` carrying the predicate
  pass/total ratio, the red→green flip velocity over recent iteration
  transitions, and the run's iteration budget consumed vs cap.

  ADR-0046 honest-unknown: NOTHING here is a date, duration, or ETA — only
  objective rates/ratios the read-model already records. A single-iteration goal
  has no transition to measure, so `per_iteration` is `nil` (never a fabricated
  `0.0`); an unbounded goal (or a run that captured no ceiling) has a `nil` budget
  `cap`. This is a pure read over the iterations projection plus the run registry;
  it never touches the loop or a write path.
  """
  @spec goal_progress_rate(Kazi.Goal.id()) :: GoalProgressRate.t()
  def goal_progress_rate(goal_ref) do
    ref = to_string(goal_ref)
    history = iteration_history(ref)

    %GoalProgressRate{
      goal_ref: ref,
      predicates: latest_predicate_ratio(history),
      flip_velocity: flip_velocity(history),
      budget: iteration_budget(ref)
    }
  end

  # The current pass/total ratio over the newest vector — {0, 0} for a goal with
  # no recorded iteration (honest empty, not a fabricated ratio).
  defp latest_predicate_ratio([]), do: {0, 0}

  defp latest_predicate_ratio(history) do
    {_index, %PredicateVector{results: results}} = List.last(history)
    total = map_size(results)
    passing = Enum.count(results, fn {_id, result} -> PredicateResult.passed?(result) end)
    {passing, total}
  end

  # Red→green flips summed over the last @flip_window transitions: for each
  # adjacent iteration pair, count predicates that were not-passing then passing.
  # `per_iteration` is nil when there is no transition (single-iteration goal) —
  # an honest unknown, never a fabricated 0.0.
  defp flip_velocity(history) do
    transitions =
      history
      |> Enum.map(fn {_index, vector} -> vector end)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.take(-@flip_window)

    flips = Enum.sum(Enum.map(transitions, fn [before, later] -> red_to_green(before, later) end))
    count = length(transitions)

    per_iteration =
      case count do
        0 -> nil
        n -> Float.round(flips / n, 1)
      end

    %{flips: flips, transitions: count, per_iteration: per_iteration}
  end

  defp red_to_green(%PredicateVector{results: before}, %PredicateVector{results: later}) do
    Enum.count(later, fn {id, result} ->
      PredicateResult.passed?(result) and not was_passing?(Map.get(before, id))
    end)
  end

  defp was_passing?(nil), do: false
  defp was_passing?(result), do: PredicateResult.passed?(result)

  # Iteration budget consumed vs cap, from the goal's most-recently-started run:
  # `dispatch_count` (always known) vs `max_iterations` (nil when unbounded, or a
  # run predating the captured ceiling — ADR-0057). No run at all yields a zeroed
  # consumed with a nil cap, an honest "no run recorded".
  defp iteration_budget(ref) do
    case RunRegistry.list_by_goal_ref(ref, "") do
      [%Run{} = run | _] -> %{consumed: run.dispatch_count || 0, cap: run.max_iterations}
      [] -> %{consumed: 0, cap: nil}
    end
  end

  @doc """
  Rehydrates a stored row's `predicate_vector` back into a
  `Kazi.PredicateVector`. The vector is keyed by string ids (their on-disk
  form); callers that need atom ids re-map them against their own predicate set.
  """
  @spec to_predicate_vector(Iteration.t()) :: PredicateVector.t()
  def to_predicate_vector(%Iteration{predicate_vector: serialized}) do
    serialized
    |> Enum.map(fn {id, %{"status" => status} = entry} ->
      {id, deserialize_result(status, entry)}
    end)
    |> PredicateVector.new()
  end

  # Rehydrate one stored result. The envelope-v2 fields (ADR-0041) are read back
  # additively: absent keys yield the boolean defaults, so a pre-v2 row (no score
  # / direction / diagnostics) round-trips to exactly the boolean struct.
  defp deserialize_result(status, entry) do
    PredicateResult.new(
      deserialize_status(status),
      Map.get(entry, "evidence", %{}),
      score: entry["score"],
      prior_score: entry["prior_score"],
      direction: deserialize_direction(entry["direction"]),
      diagnostics: deserialize_diagnostics(entry["diagnostics"])
    )
  end

  defp deserialize_direction(nil), do: nil
  defp deserialize_direction("higher_better"), do: :higher_better
  defp deserialize_direction("lower_better"), do: :lower_better
  defp deserialize_direction(_), do: nil

  defp deserialize_diagnostics(nil), do: []

  defp deserialize_diagnostics(items) when is_list(items),
    do: Enum.map(items, &Kazi.Evidence.from_map/1)

  # --- orientation-pack cache (T4.6, ADR-0010 §4) ----------------------------

  @doc """
  Caches an orientation `Kazi.Context.Pack` under `cache_key`
  (`Kazi.Context.cache_key/3`), recording the `workspace`/`git_sha` it was built at
  and the pack's blast radius (`Kazi.Context.Pack.blast_radius/1`) for incremental
  invalidation (T4.6, ADR-0010 §4).

  Upserts: re-storing under the same key replaces the prior entry (a refreshed pack
  at the same `(workspace, git-SHA, failing-set)` whose blast radius changed). The
  pack is serialized via `Kazi.Context.Pack.to_serializable/1`; `get_cached_pack/2`
  rehydrates it.

  Returns `{:ok, row}` or `{:error, changeset}`.
  """
  @impl Kazi.Context.Cache
  @spec put_cached_pack(String.t(), String.t(), String.t(), Pack.t()) ::
          {:ok, OrientationPackCache.t()} | {:error, Ecto.Changeset.t()}
  def put_cached_pack(cache_key, workspace, git_sha, %Pack{} = pack)
      when is_binary(cache_key) and is_binary(workspace) and is_binary(git_sha) do
    attrs = %{
      cache_key: cache_key,
      workspace: workspace,
      git_sha: git_sha,
      pack: Pack.to_serializable(pack),
      blast_radius: Pack.blast_radius(pack)
    }

    %OrientationPackCache{}
    |> OrientationPackCache.changeset(attrs)
    |> Writer.insert(
      on_conflict: {:replace, [:workspace, :git_sha, :pack, :blast_radius, :updated_at]},
      conflict_target: :cache_key
    )
  end

  @doc """
  Fetches the cached orientation `Kazi.Context.Pack` for `cache_key`, applying
  incremental blast-radius invalidation (T4.6, ADR-0010 §4).

  Returns the rehydrated pack only on a **fresh hit**: an entry exists *and* its
  stored blast radius equals `current_blast_radius` (the impacted files/symbols the
  pack would be scoped to now). On a miss, or when the blast radius changed (the
  cached pack is stale), returns `nil` so the caller rebuilds.

  Pass `current_blast_radius` as the already-sorted set the fresh survey yields
  (`Kazi.Context.Pack.blast_radius/1`); equality is set-wise on the stored,
  sorted column.
  """
  @impl Kazi.Context.Cache
  @spec get_cached_pack(String.t(), [String.t()]) :: Pack.t() | nil
  def get_cached_pack(cache_key, current_blast_radius)
      when is_binary(cache_key) and is_list(current_blast_radius) do
    case Repo.get_by(OrientationPackCache, cache_key: cache_key) do
      nil ->
        nil

      %OrientationPackCache{blast_radius: stored, pack: serialized} ->
        if Enum.sort(stored) == Enum.sort(current_blast_radius) do
          Pack.from_serializable(serialized)
        else
          # Blast radius changed at the same key: the cached pack is stale. Treat
          # as a miss; the caller rebuilds and re-stores (upsert) the fresh pack.
          nil
        end
    end
  end

  @doc """
  Deletes the cached orientation pack for `cache_key`, if any. Returns the number
  of rows removed (`0` or `1`). Used to explicitly evict an entry; routine
  invalidation is handled inline by `get_cached_pack/2` (a blast-radius mismatch
  is a miss, and the next `put_cached_pack/4` overwrites the stale row).
  """
  @spec invalidate_cached_pack(String.t()) :: non_neg_integer()
  def invalidate_cached_pack(cache_key) when is_binary(cache_key) do
    Writer.delete_all(OrientationPackCache, %{cache_key: cache_key})
  end

  # --- retrieval-snippet cache (T4.9c, ADR-0012 §4) --------------------------

  @doc """
  Caches a retrieved `[Kazi.Retrieval.Snippet]` under `cache_key`
  (`Kazi.Context.cache_key/3`), recording the `workspace`/`git_sha` it was
  retrieved at and the `blast_radius` it was scoped to for incremental invalidation
  (T4.9c, ADR-0012 §4 — the same scheme as the T4.6 orientation-pack cache).

  Upserts: re-storing under the same key replaces the prior entry (a refreshed
  retrieval at the same `(workspace, git-SHA, failing-set)` whose blast radius
  changed). Each snippet is serialized via `Kazi.Retrieval.Snippet.to_serializable/1`;
  `get_cached_snippets/2` rehydrates them.

  Returns `{:ok, row}` or `{:error, changeset}`.
  """
  @impl Kazi.Retrieval.Cache
  @spec put_cached_snippets(String.t(), String.t(), String.t(), [Snippet.t()], [String.t()]) ::
          {:ok, RetrievalSnippetCache.t()} | {:error, Ecto.Changeset.t()}
  def put_cached_snippets(cache_key, workspace, git_sha, snippets, blast_radius)
      when is_binary(cache_key) and is_binary(workspace) and is_binary(git_sha) and
             is_list(snippets) and is_list(blast_radius) do
    attrs = %{
      cache_key: cache_key,
      workspace: workspace,
      git_sha: git_sha,
      snippets: Enum.map(snippets, &Snippet.to_serializable/1),
      blast_radius: Enum.sort(blast_radius)
    }

    %RetrievalSnippetCache{}
    |> RetrievalSnippetCache.changeset(attrs)
    |> Writer.insert(
      on_conflict: {:replace, [:workspace, :git_sha, :snippets, :blast_radius, :updated_at]},
      conflict_target: :cache_key
    )
  end

  @doc """
  Fetches the cached `[Kazi.Retrieval.Snippet]` for `cache_key`, applying
  incremental blast-radius invalidation (T4.9c, ADR-0012 §4).

  Returns the rehydrated snippets only on a **fresh hit**: an entry exists *and* its
  stored blast radius equals `current_blast_radius` (the impacted files/symbols the
  snippets would be scoped to now). On a miss, or when the blast radius changed (the
  cached snippets are stale because the target moved under us), returns `nil` so the
  caller re-retrieves.

  Equality is set-wise on the stored, sorted column — the same invalidation
  `get_cached_pack/2` applies to orientation packs.
  """
  @impl Kazi.Retrieval.Cache
  @spec get_cached_snippets(String.t(), [String.t()]) :: [Snippet.t()] | nil
  def get_cached_snippets(cache_key, current_blast_radius)
      when is_binary(cache_key) and is_list(current_blast_radius) do
    case Repo.get_by(RetrievalSnippetCache, cache_key: cache_key) do
      nil ->
        nil

      %RetrievalSnippetCache{blast_radius: stored, snippets: serialized} ->
        if Enum.sort(stored) == Enum.sort(current_blast_radius) do
          Enum.map(serialized, &Snippet.from_serializable/1)
        else
          # Blast radius changed at the same key: the cached snippets are stale.
          # Treat as a miss; the caller re-retrieves and re-stores (upsert).
          nil
        end
    end
  end

  @doc """
  Deletes the cached snippet list for `cache_key`, if any. Returns the number of
  rows removed (`0` or `1`). Used to explicitly evict an entry; routine invalidation
  is handled inline by `get_cached_snippets/2` (a blast-radius mismatch is a miss,
  and the next `put_cached_snippets/5` overwrites the stale row).
  """
  @spec invalidate_cached_snippets(String.t()) :: non_neg_integer()
  def invalidate_cached_snippets(cache_key) when is_binary(cache_key) do
    Writer.delete_all(RetrievalSnippetCache, %{cache_key: cache_key})
  end

  # --- serialization helpers -------------------------------------------------

  defp normalize_vector(%PredicateVector{} = vector), do: vector
  defp normalize_vector(results) when is_map(results), do: PredicateVector.new(results)

  # id => %{"status" => "<status>", "evidence" => <evidence>}. Ids are stored as
  # strings (atoms don't survive a JSON round-trip).
  #
  # ADR-0041 envelope v2: `score` / `prior_score` / `direction` / `diagnostics`
  # are serialized ADDITIVELY — a key is written ONLY when the field is non-default
  # (a non-nil score/direction, a non-empty diagnostics list). A boolean predicate
  # (the default shape) therefore serializes to EXACTLY `%{"status", "evidence"}`,
  # byte-identical to the pre-v2 store. Diagnostics are mapped to JSON-safe
  # string-keyed maps by construction (`Kazi.Evidence.to_map/1`), so they need no
  # deep-sanitize (cf. lore L-0010, which is about raw provider evidence terms).
  defp serialize_vector(%PredicateVector{results: results}) do
    Map.new(results, fn {id, %PredicateResult{} = result} ->
      {to_string(id), serialize_result(result)}
    end)
  end

  defp serialize_result(%PredicateResult{status: status, evidence: evidence} = result) do
    %{"status" => to_string(status), "evidence" => sanitize_evidence(evidence)}
    |> put_when("score", result.score)
    |> put_when("prior_score", result.prior_score)
    |> put_when("direction", result.direction && to_string(result.direction))
    |> put_diagnostics(result.diagnostics)
  end

  defp put_when(map, _key, nil), do: map
  defp put_when(map, key, value), do: Map.put(map, key, value)

  defp put_diagnostics(map, []), do: map

  defp put_diagnostics(map, diagnostics) when is_list(diagnostics) do
    Map.put(map, "diagnostics", Enum.map(diagnostics, &Kazi.Evidence.to_map/1))
  end

  # T18.2: make evidence JSON-safe before it hits the Ecto `:map` column. A
  # PredicateResult's evidence is provider-supplied and, for an `:error` result,
  # carries non-encodable terms -- e.g. `reason: {:cmd_unrunnable, "..."}` (a
  # tuple) and atom keys. Stored verbatim those fail the `:map` cast and
  # `record_iteration/1` raises (the iteration is silently lost). Deep-sanitize:
  # stringify keys, keep JSON scalars, stringify atoms, and render any other term
  # (tuples, structs, pids) via `inspect/1`. Idempotent on an already-sanitized map
  # (string keys stay strings; scalars unchanged), so re-recording is safe.
  defp sanitize_evidence(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize_evidence(v) when is_atom(v), do: to_string(v)
  defp sanitize_evidence(v) when is_list(v), do: Enum.map(v, &sanitize_evidence/1)

  defp sanitize_evidence(v) when is_map(v) and not is_struct(v) do
    Map.new(v, fn {k, val} -> {to_string(k), sanitize_evidence(val)} end)
  end

  defp sanitize_evidence(v), do: inspect(v)

  defp serialize_action_params(nil), do: %{}

  # Same class as the sanitized `evidence` above: `action.params` is stored
  # verbatim, so a non-JSON-safe param (a tuple, an atom key) would fail the
  # `:map` cast and lose the iteration (deep review L13). Route it through the
  # same deep-sanitizer defensively, even though today's dispatch evidence only
  # carries `:fail` (already JSON-safe) results.
  defp serialize_action_params(%Action{params: params}), do: sanitize_evidence(params)

  # T34.3 (ADR-0046 §2): serialize a per-iteration counter map (`context`/`tools`)
  # JSON-safe — stringify the keys (atoms don't survive JSON); the values are
  # already strings/integers. A non-map (or absent) counter is the empty object,
  # so a no-counters iteration records `{}`. Already-string-keyed maps (read back
  # and re-recorded) pass through unchanged, keeping re-recording idempotent.
  @spec serialize_counters(term()) :: map()
  defp serialize_counters(counters) when is_map(counters) do
    Map.new(counters, fn {key, value} -> {to_string(key), value} end)
  end

  defp serialize_counters(_), do: %{}

  # T1.2 regression: serialize the detector's flags into JSON-safe maps. Each
  # flag's :attributed_dispatch is a %Kazi.Action{} (or nil); it is flattened to
  # its kind/params/metadata so the whole flag survives the JSON round-trip, and
  # all keys are stringified (atoms don't survive JSON). Already-serialized
  # (string-keyed) flags pass through unchanged so re-recording is idempotent.
  defp serialize_regressions(flags) when is_list(flags) do
    Enum.map(flags, &serialize_regression/1)
  end

  defp serialize_regression(%{predicate_id: _} = flag) do
    %{
      "predicate_id" => to_string(flag.predicate_id),
      "green_iteration" => flag.green_iteration,
      "red_iteration" => flag.red_iteration,
      "status" => to_string(flag.status),
      "attributed_dispatch" => serialize_dispatch(Map.get(flag, :attributed_dispatch))
    }
  end

  # An already string-keyed flag (e.g. read back and re-recorded): pass through.
  defp serialize_regression(%{} = flag), do: flag

  defp serialize_dispatch(nil), do: nil

  defp serialize_dispatch(%Action{kind: kind, params: params, metadata: metadata}) do
    %{"kind" => to_string(kind), "params" => params, "metadata" => metadata}
  end

  defp deserialize_status(status) when is_binary(status) do
    valid = Enum.map(PredicateResult.statuses(), &to_string/1)

    if status in valid do
      String.to_existing_atom(status)
    else
      raise ArgumentError, "unknown predicate status #{inspect(status)} in read-model"
    end
  end
end
