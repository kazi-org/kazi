defmodule Kazi.Authoring do
  @moduledoc """
  Idea → acceptance-predicate authoring (T3.5a, UC-017, ADR-0011).

  `Kazi.Authoring` is the one WRITE path the Slice-3 operator surfaces share. A
  human (via the CLI T3.5c or the dashboard) hands
  kazi a *prose idea*; kazi drives the coding harness to draft that idea into a
  `Kazi.Goal` whose **acceptance predicates** make "done" machine-checkable
  (ADR-0002), and persists the draft as a reviewable artifact with status
  `proposed`. Nothing runs yet: a proposed goal is reviewed and then approved
  into an executable goal (T3.5b) before `Kazi.Runtime` will work it. A surface
  never reaches into a running reconciliation; it only proposes through this API
  (ADR-0011 §2).

  ## The flow (`propose/2`)

  1. Build a focused prompt asking the harness to translate the idea into
     acceptance criteria (`build_prompt/1`).
  2. Drive the **injectable** harness adapter (`:harness` opt, defaulting to the
     real `Kazi.Harness.ClaudeAdapter`) via its `run/3`, exactly the seam the
     convergence loop uses — so tests inject a stub adapter and no real `claude`
     (or network) is touched.
  3. Parse the harness's structured proposal into a draft `Kazi.Goal` in
     `:create` mode with ≥1 acceptance predicate (`parse_proposal/2`). The shape
     is deterministic: the same proposal yields the same draft, with no
     timestamps or randomness in the goal itself.
  4. Persist the draft as a `proposed` `Kazi.ReadModel.ProposedGoal`, returning a
     `Kazi.Authoring.Draft` the caller reviews.

  ## Proposal contract

  The harness is asked to emit a single JSON object describing the goal. It is
  read from the result map's `:result` field (the agent's final result text in a
  `claude --output-format json` envelope, T4.1) — or, when the adapter already
  hands back a decoded map under `:result`/`:proposal`, that map directly:

      {
        "name": "Health endpoint returns 200",
        "predicates": [
          {"id": "health", "provider": "http_probe",
           "description": "GET /healthz returns 200"}
        ]
      }

  Each predicate is drafted as an **acceptance** predicate (`acceptance?: true`,
  `:create` mode) — desired NEW behavior authored to fail at t0 (T2.1). A
  proposal with no usable predicate is a `{:error, {:invalid_proposal, reason}}`,
  so a malformed or empty draft fails loudly rather than persisting a vacuous
  goal.

  ### Shape robustness (T26.8)

  A real drafting harness does not always return the predicates at the top level.
  `parse_proposal/2` therefore accepts, in addition to the canonical shape above:

    * the goal nested under a single wrapper key — `{"goal": {…}}`,
      `{"proposal": {…}}`, or `{"spec": {…}}`;
    * the goal-file singular `"predicate"` array (`{"predicate": [ … ]}`) instead
      of the plural `"predicates"`, with each predicate's config either nested
      under `"config"` or spread as sibling keys (the goal-file convention).

  The `provider` strings recognised are the loader's full catalog
  (`Kazi.Goal.Loader.provider_kinds/0`) — including the E32 providers
  (`custom_script`, `static`, `ratchet`, `metrics`, `coverage`, `property`,
  `mutation`, `cve`) — so a drafted or caller-supplied predicate naming a modern
  provider survives instead of being silently dropped.

  ## Persisted shape

  The draft goal is stored in the canonical goal-file map shape
  `Kazi.Goal.Loader.from_map/1` accepts (`serialize_goal/1`). That lets the
  approval workflow (T3.5b) rehydrate a proposal into a runnable goal through the
  same validated loader the CLI uses, instead of a bespoke deserialiser.

  ## The approval workflow (`approve/2`, `reject/2`, `edit/3`)

  A proposed goal is reviewed and then transitioned (T3.5b, ADR-0011). Surfaces
  drive these against the proposal's `proposal_ref`:

    * `approve/2` — `proposed → approved`. Rehydrates the stored goal-file map
      into a runnable `Kazi.Goal` through `Kazi.Goal.Loader.from_map/1` (the same
      loader the CLI uses), persists status `approved`, and **returns the goal**
      so the caller (the CLI T3.5c) hands it straight to `Kazi.Runtime.run/2`.
    * `reject/2` — `proposed → rejected`. Records the proposal as declined; it
      stays queryable but never runs.
    * `edit/3` — `proposed → proposed`. Replaces the draft's goal payload (e.g. a
      reviewer fixes a predicate) through the same validated loader, so an edit
      can only persist a goal the runtime would accept.

  The transitions enforce a small state machine: only a `proposed` goal may be
  approved, rejected, or edited. Approving an already-`approved`/`rejected` goal
  (or editing a terminal one) is an `{:error, {:invalid_transition, from, to}}` —
  a clear refusal, not a silent overwrite.
  """

  alias Kazi.{Goal, Predicate, ReadModel}
  alias Kazi.Authoring.Clarify
  alias Kazi.Authoring.Draft
  alias Kazi.Goal.Group
  alias Kazi.Goal.Loader
  alias Kazi.ReadModel.ProposedGoal
  alias Kazi.Repo

  # The harness adapter driven when the caller does not inject one. The real
  # `claude -p` adapter — the same default the runtime uses; tests inject a stub
  # via the `:harness` opt (the seam), so lib/ carries no stub.
  @default_harness Kazi.Harness.ClaudeAdapter

  @typedoc "A prose idea to be drafted into a goal."
  @type idea :: String.t()

  @typedoc """
  Options for `propose/2`:

    * `:harness` — the `Kazi.HarnessAdapter` module to drive (default the real
      `Kazi.Harness.ClaudeAdapter`). The injection seam: tests pass a stub.
    * `:workspace` — the target workspace the harness runs in (default `"."`).
    * `:adapter_opts` — keyword opts forwarded verbatim to the harness `run/3`
      (e.g. a stub's control pid, a model, a per-dispatch budget).
    * `:proposal_ref` — the proposal's review handle. Default: a deterministic id
      derived from the idea, so re-proposing the same idea upserts rather than
      duplicating. In caller-drafts mode the default instead derives from the
      proposal payload's own `"id"`/`"name"` (#787/#793) — see `:proposal` below.
    * `:proposal` — caller-drafts mode (ADR-0023 decision 4): a proposal payload
      (the `%{"name", "predicates", "rationale"}` map, or its JSON string) the
      caller already authored. When present, kazi does NOT spawn a harness/model
      to draft — it parses, applies the deterministic floor, and persists. The
      same one write path; only the drafter changes (the caller, not an inner
      model). The goal id and `proposal_ref` are derived from the payload's own
      `"goal_id"`/`"id"` (used verbatim) or `"name"` (slugged) so distinct
      payloads coexist instead of colliding on one hardcoded id, and a payload
      `"idea"` replaces the surface's (often placeholder) idea in the persisted
      proposal (T39.1, ADR-0049).
    * `:replace` — when the resolved `proposal_ref` already holds an `approved`
      proposal, the upsert is refused (`{:proposal_locked, ref, "approved"}`)
      unless this is `true` (#787/#793). Default `false`.
  """
  @type opts :: keyword()

  @doc """
  Proposes a draft goal from a prose `idea`.

  Drives the (injectable) harness to draft acceptance predicates for the idea,
  parses them into a `Kazi.Goal` (`:create` mode, ≥1 acceptance predicate), and
  persists it as status `proposed`. Returns `{:ok, %Kazi.Authoring.Draft{}}` —
  the reviewable artifact — or `{:error, reason}`:

    * `{:error, :empty_idea}` — the idea was blank.
    * `{:error, {:harness_failed, term}}` — the harness could not be run.
    * `{:error, {:invalid_proposal, reason}}` — the harness produced no usable
      acceptance predicate.
    * `{:error, {:invalid_goal, reason}}` — the drafted goal parsed but does not
      LOAD (e.g. a `custom_script` predicate with no non-empty `cmd`, #788):
      caught here at propose time, not later at `approve`.
    * `{:error, {:proposal_locked, proposal_ref, "approved"}}` — the resolved
      `proposal_ref` already holds an `approved` proposal and `:replace` was not
      passed (#787/#793): refused rather than silently resetting it.
    * `{:error, %Ecto.Changeset{}}` — the proposal could not be persisted.

  ## Examples

      iex> defmodule OneShotHarness do
      ...>   @behaviour Kazi.HarnessAdapter
      ...>   @impl true
      ...>   def run(_prompt, _workspace, _opts) do
      ...>     {:ok, %{result: ~s({"name":"Ship it","predicates":[{"id":"health","provider":"http_probe"}]})}}
      ...>   end
      ...> end
      iex> {:ok, draft} = Kazi.Authoring.propose("a health endpoint", harness: OneShotHarness)
      iex> {draft.status, draft.goal.mode, length(draft.goal.predicates)}
      {:proposed, :create, 1}
  """
  @spec propose(idea(), opts()) :: {:ok, Draft.t()} | {:error, term()}
  def propose(idea, opts \\ []) when is_binary(idea) and is_list(opts) do
    with {:ok, idea} <- validate_idea(idea),
         {:ok, clarifications} <- run_clarify(idea, opts),
         {:ok, proposal} <- obtain_proposal(idea, clarifications, opts),
         idea = resolve_idea(proposal, idea, opts),
         {goal_id, proposal_ref} = resolve_identity(proposal, idea, opts),
         {:ok, goal} <- parse_proposal(proposal, goal_id),
         :ok <- validate_loadable(goal),
         opts = Keyword.put_new(opts, :proposal_ref, proposal_ref),
         {:ok, draft} <- persist(idea, goal, opts) do
      {:ok, draft}
    end
  end

  @doc """
  Drafts a MULTI-GOAL roadmap payload (T45.2, UC-059): N caller-drafts goals plus
  inter-goal `needs`, persisted as a SET of LINKED proposals sharing one roadmap
  ref.

  `payload` is `%{"goals" => [entry, ...]}` (string-keyed). Each entry is a
  caller-drafts proposal map carrying an `"id"` (the node id + goal id + `needs`
  handle), an optional `"needs"` list of predecessor ids, and an optional
  `"integration"` block. Every goal runs the per-goal clarify floor UNCHANGED (via
  `propose/2`); the roadmap as a whole additionally runs the roadmap-scope floor
  (`Kazi.Authoring.Clarify.roadmap_gaps/1`).

  Returns `{:ok, %{roadmap_ref:, proposals: [Draft.t()], clarify: [Question.t()]}}`,
  or `{:error, reason}` for a malformed payload, a duplicate/unresolvable id, a
  cycle, or a per-goal draft error.
  """
  @spec propose_roadmap(map(), opts()) :: {:ok, map()} | {:error, term()}
  def propose_roadmap(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    with {:ok, entries} <- roadmap_entries(payload),
         :ok <- validate_roadmap_ids(entries),
         roadmap_ref = roadmap_ref(entries),
         {:ok, drafts} <- persist_members(entries, roadmap_ref, opts),
         {:ok, roadmap} <- build_member_roadmap(entries, drafts) do
      {:ok,
       %{roadmap_ref: roadmap_ref, proposals: drafts, clarify: Clarify.roadmap_gaps(roadmap)}}
    end
  end

  # Extract the `[[goals]]` entries as `%{id, needs, integration, proposal}`. Each
  # proposal is the entry map itself (parse_proposal ignores the `needs` key).
  defp roadmap_entries(%{"goals" => goals}) when is_list(goals) and goals != [] do
    entries =
      Enum.map(goals, fn entry ->
        %{
          id: optional_string(Map.get(entry, "id")),
          needs: Map.get(entry, "needs", []),
          integration: Map.get(entry, "integration"),
          proposal: entry
        }
      end)

    if Enum.all?(entries, &(is_binary(&1.id) and is_list(&1.needs))) do
      {:ok, entries}
    else
      {:error, {:invalid_roadmap, "each goal needs a string \"id\" and a list \"needs\""}}
    end
  end

  defp roadmap_entries(_payload),
    do: {:error, {:invalid_roadmap, "a project payload needs a non-empty \"goals\" array"}}

  # Duplicate ids and unresolvable `needs` are cheap structural errors — caught
  # before anything is persisted. (Acyclicity is validated by the roadmap artifact
  # in build_member_roadmap/2.)
  defp validate_roadmap_ids(entries) do
    ids = MapSet.new(entries, & &1.id)

    cond do
      MapSet.size(ids) != length(entries) ->
        {:error, {:invalid_roadmap, "duplicate goal id"}}

      bad = Enum.find_value(entries, fn e -> Enum.find(e.needs, &(&1 not in ids)) end) ->
        {:error, {:invalid_roadmap, "unresolvable needs id #{inspect(bad)}"}}

      true ->
        :ok
    end
  end

  # A deterministic roadmap ref over the sorted member ids.
  defp roadmap_ref(entries) do
    digest =
      entries
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.join(",")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "road-" <> digest
  end

  # Persist each member through the normal caller-drafts `propose/2` path (so the
  # per-goal floor + gate are byte-identical to a single-goal plan), threading the
  # shared roadmap ref into each row.
  defp persist_members(entries, roadmap_ref, opts) do
    member_opts = Keyword.put(opts, :roadmap_ref, roadmap_ref)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      idea = optional_string(Map.get(entry.proposal, "name")) || entry.id

      case propose(idea, Keyword.put(member_opts, :proposal, entry.proposal)) do
        {:ok, draft} -> {:cont, {:ok, [draft | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, drafts} -> {:ok, Enum.reverse(drafts)}
      {:error, _} = err -> err
    end
  end

  # Build the roadmap ARTIFACT (T45.1) from the persisted members, re-attaching each
  # entry's raw `integration` block to the serialized goal so the loader parses it
  # (serialize_goal/1 drops integration). Validates acyclicity and yields the DAG
  # the roadmap-scope clarify reads (frontier detection + per-node integration).
  defp build_member_roadmap(entries, drafts) do
    by_id = Map.new(drafts, fn d -> {to_string(d.goal.id), d} end)

    goals =
      Enum.map(entries, fn entry ->
        goal_map = serialize_goal(by_id[entry.id].goal)

        goal_map =
          if entry.integration,
            do: Map.put(goal_map, "integration", entry.integration),
            else: goal_map

        %{"id" => entry.id, "needs" => entry.needs, "goal" => goal_map}
      end)

    Kazi.Goal.Roadmap.from_map(%{"goals" => goals})
  end

  # The proposal source: caller-drafts vs kazi-drafts (ADR-0023 decision 4). A
  # caller-supplied `:proposal` (the orchestrator already reasoned) is used
  # DIRECTLY — no harness/model is spawned; kazi adds the floor + the gate, not a
  # duplicate LLM call. Otherwise kazi drives the harness to draft from the idea
  # (the existing path). Both go through the SAME `parse_proposal` → `persist`
  # tail, so propose stays the one write path.
  @spec obtain_proposal(idea(), String.t(), opts()) :: {:ok, term()} | {:error, term()}
  defp obtain_proposal(idea, clarifications, opts) do
    case Keyword.get(opts, :proposal) do
      nil -> drive_harness(idea, clarifications, opts)
      proposal -> {:ok, proposal}
    end
  end

  # --- clarify phase (T11.4, ADR-0019) ---------------------------------------

  # The clarify phase runs ONLY when an `:ask` callback is injected (the CLI
  # supplies interactive I/O; tests inject a function). Without it, propose stays
  # the one-shot it always was, so existing callers are unchanged. When present,
  # gather the questions (the deterministic floor merged with harness-drafted
  # candidates), ask them, and fold the answers into a clarifications block for the
  # draft prompt.
  @spec run_clarify(idea(), opts()) :: {:ok, String.t()}
  defp run_clarify(idea, opts) do
    # Caller-drafts (ADR-0023): the caller already supplied the predicates, so
    # there is nothing to clarify and NO inner harness is driven for candidate
    # questions — the deterministic floor is reported by the caller (the CLI)
    # against the parsed draft instead.
    if Keyword.has_key?(opts, :proposal) do
      {:ok, ""}
    else
      do_run_clarify(idea, opts)
    end
  end

  defp do_run_clarify(idea, opts) do
    case Keyword.get(opts, :ask) do
      ask when is_function(ask, 1) ->
        questions = clarify_questions(idea, opts)
        answers = normalize_answers(ask.(questions))
        {:ok, Clarify.fold_answers(questions, answers)}

      _ ->
        {:ok, ""}
    end
  end

  # The questions to ask: the deterministic floor (`Clarify.gaps/2`) merged with
  # harness-drafted candidates (T11.3), the floor authoritative. Candidate drafting
  # is fail-soft -- a harness error or malformed response degrades to the floor.
  defp clarify_questions(idea, opts) do
    Clarify.merge(Clarify.gaps(idea), drive_candidates(idea, opts))
  end

  defp drive_candidates(idea, opts) do
    {harness, harness_opts} = resolve_harness(opts)
    workspace = Keyword.get(opts, :workspace, ".")
    adapter_opts = Keyword.merge(Keyword.get(opts, :adapter_opts, []), harness_opts)

    case harness.run(Clarify.candidate_prompt(idea), workspace, adapter_opts) do
      {:ok, result} when is_map(result) -> Clarify.parse_candidates(proposal_payload(result))
      _ -> []
    end
  end

  # An `:ask` callback may return a string-keyed answers map; anything else is
  # treated as no answers, so a misbehaving caller cannot crash the draft.
  defp normalize_answers(answers) when is_map(answers), do: answers
  defp normalize_answers(_), do: %{}

  # --- approval workflow (T3.5b) ---------------------------------------------

  @doc """
  Approves the proposed goal identified by `proposal_ref`: transitions it
  `proposed → approved` and returns the **runnable** `Kazi.Goal`.

  Only a `proposed` goal may be approved (the state-machine guard). On approve the
  stored goal-file map is rehydrated through `Kazi.Goal.Loader.from_map/1` — the
  same validated loader the CLI uses — so the returned goal is exactly what
  `Kazi.Runtime.run/2` accepts; the caller (the CLI T3.5c) hands it straight to
  the runtime. The row's status is persisted as `approved` first, so the
  transition is durable before the goal is handed back.

  Returns `{:ok, %Kazi.Goal{}}`, or `{:error, reason}`:

    * `{:error, :not_found}` — no proposal carries that `proposal_ref`.
    * `{:error, {:invalid_transition, from, :approved}}` — the proposal is not in
      the `:proposed` state (e.g. already approved or rejected).
    * `{:error, {:invalid_goal, reason}}` — the stored goal-file map no longer
      rehydrates into a runnable goal.
    * `{:error, %Ecto.Changeset{}}` — the transition could not be persisted.

  ## Examples

      iex> {:ok, draft} = Kazi.Authoring.propose("a health endpoint", harness: OneShotHarness)
      iex> {:ok, %Kazi.Goal{} = goal} = Kazi.Authoring.approve(draft.proposal_ref)
      iex> goal.mode
      :create
  """
  @spec approve(String.t(), opts()) :: {:ok, Goal.t()} | {:error, term()}
  def approve(proposal_ref, opts \\ []) when is_binary(proposal_ref) and is_list(opts) do
    with {:ok, row} <- fetch_proposed(proposal_ref),
         :ok <- check_transition(row.status, "approved"),
         {:ok, goal} <- rehydrate(row.goal),
         {:ok, _row} <- ReadModel.transition_proposed_goal(proposal_ref, "approved", row.goal) do
      {:ok, goal}
    end
  end

  @doc """
  Loads the APPROVED proposal identified by `proposal_ref` as a runnable
  `Kazi.Goal` (T39.2, ADR-0049) — a pure read, no state transition.

  This is the `kazi apply <proposal-ref>` seam: `plan`/`approve` never write a
  goal-file, so `apply` loads the approved goal straight from the read-model
  instead of forcing the caller to reconstruct one on disk. The stored goal-file
  map is rehydrated through `Kazi.Goal.Loader.from_map/1` — the same validated
  loader a goal-file path goes through — so the returned goal is exactly what
  `Kazi.Runtime.run/2` accepts, guards included.

  Returns `{:ok, %Kazi.Goal{}}`, or `{:error, reason}`:

    * `{:error, :not_found}` — no proposal carries that `proposal_ref`.
    * `{:error, {:not_approved, status}}` — the proposal exists but is not
      `approved` (still `proposed`, or `rejected`): only an approved proposal
      may run.
    * `{:error, {:invalid_goal, reason}}` — the stored goal-file map no longer
      rehydrates into a runnable goal.
  """
  @spec load_approved(String.t()) :: {:ok, Goal.t()} | {:error, term()}
  def load_approved(proposal_ref) when is_binary(proposal_ref) do
    with {:ok, row} <- fetch_proposed(proposal_ref),
         :ok <- ensure_approved(row.status) do
      rehydrate(row.goal)
    end
  end

  # Only an `approved` proposal is runnable; anything else names its actual
  # state so the surface can say "approve it first" vs "it was rejected".
  @spec ensure_approved(String.t()) :: :ok | {:error, {:not_approved, String.t()}}
  defp ensure_approved("approved"), do: :ok
  defp ensure_approved(status), do: {:error, {:not_approved, status}}

  @doc """
  Rejects the proposed goal identified by `proposal_ref`: transitions it
  `proposed → rejected` and returns the updated `Kazi.Authoring.Draft`.

  Only a `proposed` goal may be rejected. A rejected proposal stays queryable
  (`Kazi.ReadModel.list_proposed_goals(status: "rejected")`) for audit but never
  runs. The goal payload is left untouched.

  Rejection is a pure lifecycle transition on the read-model row — it performs
  no reconciliation and never runs the goal — so, unlike `approve/2`, it does
  NOT require the stored goal-file map to load (#945). A proposal authored
  against a since-changed predicate schema is still rejectable: the returned
  draft carries `goal: nil` and `loadable?: false` (`goal_id` is still the
  row's, so the caller can still name what was rejected) instead of failing.

  Returns `{:ok, %Kazi.Authoring.Draft{}}` (status `:rejected`), or `{:error,
  reason}`: `{:error, :not_found}`, `{:error, {:invalid_transition, from,
  :rejected}}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec reject(String.t(), opts()) :: {:ok, Draft.t()} | {:error, term()}
  def reject(proposal_ref, opts \\ []) when is_binary(proposal_ref) and is_list(opts) do
    with {:ok, row} <- fetch_proposed(proposal_ref),
         :ok <- check_transition(row.status, "rejected"),
         {:ok, updated} <-
           ReadModel.transition_proposed_goal(proposal_ref, "rejected", row.goal) do
      {:ok, Draft.from_row(updated, rehydrate_or_nil(updated.goal))}
    end
  end

  # The goal for a `reject/2` draft, best-effort (#945): a rejected proposal
  # need not still load, so a rehydrate failure degrades to `nil` (the draft
  # carries `loadable?: false`) rather than failing the whole rejection.
  @spec rehydrate_or_nil(map()) :: Goal.t() | nil
  defp rehydrate_or_nil(goal_map) do
    case rehydrate(goal_map) do
      {:ok, goal} -> goal
      {:error, _reason} -> nil
    end
  end

  @doc """
  Edits the proposed goal identified by `proposal_ref`: replaces its draft goal
  with `changes` (a goal-file map) and keeps it `proposed` for re-review.

  Only a `proposed` goal may be edited (an approved or rejected proposal is
  terminal). The `changes` map must rehydrate through `Kazi.Goal.Loader.from_map/1`
  — so an edit can only persist a goal the runtime would accept; a malformed edit
  is `{:error, {:invalid_goal, reason}}` and nothing is written. The edited goal
  is re-serialized to the canonical shape before persisting, so it round-trips
  identically to a freshly proposed one.

  Returns `{:ok, %Kazi.Authoring.Draft{}}` (status `:proposed`, carrying the
  edited goal), or `{:error, reason}`: `{:error, :not_found}`, `{:error,
  {:invalid_transition, from, :proposed}}`, `{:error, {:invalid_goal, reason}}`,
  or `{:error, %Ecto.Changeset{}}`.
  """
  @spec edit(String.t(), map(), opts()) :: {:ok, Draft.t()} | {:error, term()}
  def edit(proposal_ref, changes, opts \\ [])
      when is_binary(proposal_ref) and is_map(changes) and is_list(opts) do
    with {:ok, row} <- fetch_proposed(proposal_ref),
         :ok <- check_transition(row.status, "proposed"),
         {:ok, goal} <- rehydrate(changes),
         serialized = serialize_goal(goal),
         {:ok, updated} <-
           ReadModel.transition_proposed_goal(proposal_ref, "proposed", serialized) do
      {:ok, Draft.from_row(updated, goal)}
    end
  end

  # Fetch the proposed-goal row by its review handle, or `{:error, :not_found}`.
  @spec fetch_proposed(String.t()) :: {:ok, ProposedGoal.t()} | {:error, :not_found}
  defp fetch_proposed(proposal_ref) do
    case ReadModel.get_proposed_goal(proposal_ref) do
      nil -> {:error, :not_found}
      %ProposedGoal{} = row -> {:ok, row}
    end
  end

  # The approval state machine: only a `proposed` proposal may transition. A
  # transition out of any other (terminal) state is refused with the from/to
  # states named, so a surface can report a clear "already approved/rejected"
  # rather than silently overwriting a terminal decision.
  @spec check_transition(String.t(), String.t()) ::
          :ok | {:error, {:invalid_transition, atom(), atom()}}
  defp check_transition("proposed", _to), do: :ok

  defp check_transition(from, to) do
    {:error, {:invalid_transition, String.to_existing_atom(from), String.to_existing_atom(to)}}
  end

  # Rehydrate a stored goal-file map into a runnable `Kazi.Goal` through the same
  # validated loader the CLI uses, so an approved/edited goal is exactly what
  # `Kazi.Runtime.run/2` accepts. A map that no longer loads is `:invalid_goal`.
  @spec rehydrate(map()) :: {:ok, Goal.t()} | {:error, {:invalid_goal, term()}}
  defp rehydrate(goal_map) when is_map(goal_map) do
    case Loader.from_map(goal_map) do
      {:ok, %Goal{} = goal} -> {:ok, goal}
      {:error, reason} -> {:error, {:invalid_goal, reason}}
    end
  end

  # #788: plan-time validation must match load-time validation -- a proposal
  # that cannot LOAD (e.g. a custom_script predicate with no non-empty "cmd")
  # must be rejected here, at `propose`, never accepted-then-failed later at
  # `approve`. Round-trips the just-drafted goal through the SAME canonical path
  # `approve/2` rehydrates through (`serialize_goal/1` -> `rehydrate/1`), so
  # there is exactly one provider-config validation to maintain -- no second
  # copy of the rules that could drift out of sync.
  @spec validate_loadable(Goal.t()) :: :ok | {:error, {:invalid_goal, term()}}
  defp validate_loadable(%Goal{} = goal) do
    case rehydrate(serialize_goal(goal)) do
      {:ok, _goal} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds the focused prompt asking the harness to translate a prose `idea` into a
  `Kazi.Goal` of acceptance predicates (concept §10, T2.1).

  Pure and total so it can be tested directly. It instructs the harness to emit a
  single JSON object — `{"name", "predicates": [{"id", "provider", "description",
  "config"}], "rationale"}` — describing checkable acceptance criteria,
  deliberately NOT prose the agent self-grades: the controller, not the agent,
  decides "done" (concept §1). The optional `clarifications` block (T11.4,
  ADR-0019) carries the author's answers to the clarify-phase questions so the
  drafted predicates reflect them; `rationale` is the inline "why these predicates
  / what is out of scope" the draft surfaces at review (T11.5).

  ## Pinning the provider config shape (T26.8)

  A real drafting harness, told only the provider NAMES, guesses each predicate's
  `config` shape — and guesses wrong. Live on v1.46.1 the claude harness drafted a
  `custom_script` predicate with an invented `{"script", "interpreter",
  "working_dir", "expected_exit_code"}` shape, so the proposal PARSED but the goal
  then failed to load (`custom_script … requires a non-empty string "cmd"`),
  killing the on-ramp at `approve`. So the prompt now EMBEDS the authoritative
  per-provider config contract, rendered straight from `Kazi.Predicate.Schema`
  (the SAME source `kazi schema <provider>` prints — no hand-duplicated field list
  to drift), and explicitly pins `custom_script` to `cmd` (NOT `script`).

  ## Examples

      iex> prompt = Kazi.Authoring.build_prompt("a health endpoint that returns 200")
      iex> prompt =~ "a health endpoint that returns 200" and prompt =~ "acceptance"
      true
  """
  @spec build_prompt(idea(), String.t()) :: String.t()
  def build_prompt(idea, clarifications \\ "")
      when is_binary(idea) and is_binary(clarifications) do
    """
    Translate the following software idea into a kazi goal: a set of
    machine-checkable acceptance predicates whose conjunction means the idea is
    done. Each predicate names a provider that can objectively evaluate it
    (#{known_providers()}); do not propose criteria a human has to judge by hand.

    Idea:
    #{idea}
    #{clarifications_section(clarifications)}
    Respond with a SINGLE JSON object and nothing else, of the shape:

      {
        "name": "<short goal name>",
        "predicates": [
          {"id": "<stable_id>", "provider": "<provider>",
           "description": "<what must become true>", "config": { }}
        ],
        "rationale": "<one or two sentences: why these predicates, and what is deliberately out of scope>"
      }

    Each predicate's `config` object MUST use the EXACT keys kazi's provider
    expects — kazi rejects an unknown config shape at load, so do NOT invent
    config keys. The config contract per provider (required keys marked
    *required*):

    #{provider_config_contract()}

    A `custom_script` config MUST use `cmd` (ONE executable, e.g. "sh" or
    "test") plus optional `args` (an array of strings), `verdict`, and `env`; it
    MUST NOT use `script`, `interpreter`, `working_dir`, or `expected_exit_code`
    — those are not kazi config keys and the goal will fail to load. Put a shell
    line in `cmd: "sh"`, `args: ["-c", "<line>"]`, never in a `script` key.

    Author at least one predicate. These are acceptance criteria for NEW
    behavior: they are expected to fail now and pass once the idea is built.

    Write each `description` as an IMPLEMENTATION BRIEF, not a label: the
    model that later converges this goal sees ONLY the goal name, the failing
    predicates, and evidence — never this conversation. Maximum implementable
    detail is the default. In the first acceptance predicate's description,
    front-load the task brief: one sentence of WHY, the exact files/modules to
    touch when known, the pieces known to be missing, and what must NOT
    change. Keep one requirement per predicate — never fold N requirements
    into one catch-all check that a partial implementation could satisfy. Pair
    any text-presence (grep-style) check with a negative-space or structural
    companion (a bare text match is satisfiable by an unrelated or stuffed
    string).
    """
  end

  # The authoritative per-provider config contract embedded into the drafting
  # prompt (T26.8), rendered from `Kazi.Predicate.Schema` — the SAME single source
  # of truth `kazi schema <provider>` prints — so the harness drafts a `config`
  # kazi's loader actually accepts instead of guessing (and guessing wrong, e.g.
  # the invented `custom_script` `script` shape that loaded-failed live on v1.46.1).
  # Sourcing it here means the field list never drifts from the providers.
  defp provider_config_contract do
    Kazi.Predicate.Schema.kinds()
    |> Enum.map_join("\n", &render_provider_contract/1)
  end

  # One provider's contract line: its config keys (required ones marked) plus a
  # concrete example config object (the schema's own example, minus the
  # predicate-envelope keys), so the harness sees the exact shape to emit.
  defp render_provider_contract(kind) do
    {:ok, schema} = Kazi.Predicate.Schema.fetch(kind)

    keys =
      Enum.map_join(schema.keys, ", ", fn key ->
        "#{key.name} (#{key.type})#{if key.required, do: " *required*", else: ""}"
      end)

    example_config =
      schema.example
      |> Map.drop(["id", "provider", "description"])
      |> Jason.encode!()

    "  - #{kind}: #{keys}\n    example config: #{example_config}"
  end

  # The clarifications block (the author's clarify-phase answers) inserted between
  # the idea and the response shape; empty when nothing was asked/answered.
  defp clarifications_section(""), do: ""
  defp clarifications_section(clarifications), do: "\n#{clarifications}\n"

  # --- harness drive ---------------------------------------------------------

  # Drive the injectable harness adapter with the authoring prompt, in the target
  # workspace, forwarding the caller's adapter opts. The same `run/3` seam the
  # convergence loop uses — a stub adapter is injected via `:harness` in tests, so
  # no real `claude` and no network are touched.
  @spec drive_harness(idea(), String.t(), opts()) :: {:ok, term()} | {:error, term()}
  defp drive_harness(idea, clarifications, opts) do
    {harness, harness_opts} = resolve_harness(opts)
    workspace = Keyword.get(opts, :workspace, ".")
    adapter_opts = Keyword.merge(Keyword.get(opts, :adapter_opts, []), harness_opts)
    prompt = build_prompt(idea, clarifications)

    case harness.run(prompt, workspace, adapter_opts) do
      {:ok, result} when is_map(result) -> {:ok, proposal_payload(result)}
      {:error, reason} -> {:error, {:harness_failed, reason}}
      other -> {:error, {:harness_failed, other}}
    end
  end

  # T8.7 (ADR-0016): pick the harness adapter. An explicitly injected `:harness`
  # MODULE (the test seam) is used as-is; otherwise the default is RESOLVED via
  # `Kazi.Harness.resolve/1` so app config can select opencode for authoring too.
  # On a resolve error the legacy `@default_harness` stands (no behaviour change).
  defp resolve_harness(opts) do
    case Keyword.get(opts, :harness) do
      nil ->
        case Kazi.Harness.resolve(model: Keyword.get(opts, :model)) do
          {:ok, {module, harness_opts}} -> {module, harness_opts}
          {:error, _reason} -> {@default_harness, []}
        end

      module ->
        {module, []}
    end
  end

  # The proposal payload out of the harness result map: a pre-decoded map under
  # `:proposal`/`:result` is used directly; otherwise the `:result` text (the
  # agent's final result in a `claude --output-format json` envelope, T4.1) is the
  # JSON to decode. Falls back to the raw `:output` so a stub that emits only raw
  # stdout still works.
  @spec proposal_payload(map()) :: term()
  defp proposal_payload(%{proposal: %{} = proposal}), do: proposal
  defp proposal_payload(%{result: %{} = result}), do: result
  defp proposal_payload(%{result: result}) when is_binary(result), do: result
  defp proposal_payload(%{output: output}) when is_binary(output), do: output
  defp proposal_payload(_result), do: nil

  # --- proposal → draft goal -------------------------------------------------

  @doc """
  Parses a harness `proposal` (a JSON string or an already-decoded map) into a
  draft `Kazi.Goal` in `:create` mode with acceptance predicates, under `goal_id`.

  Pure and total. Returns `{:ok, goal}` with ≥1 acceptance predicate, or
  `{:error, {:invalid_proposal, reason}}` when the proposal is not a usable
  object or carries no usable predicate — so a malformed draft fails loudly
  rather than persisting a vacuous goal.
  """
  @spec parse_proposal(term(), Goal.id()) :: {:ok, Goal.t()} | {:error, term()}
  def parse_proposal(proposal, goal_id) do
    with {:ok, decoded} <- decode_proposal(proposal),
         map = unwrap_proposal(decoded),
         {:ok, predicates} <- build_predicates(extract_predicates(map)) do
      {:ok,
       Goal.new(goal_id,
         name: optional_string(Map.get(map, "name")),
         mode: :create,
         predicates: predicates,
         metadata: draft_metadata(Map.get(map, "rationale"))
       )}
    end
  end

  # The wrapper keys a drafting harness routinely nests the goal under instead of
  # returning it at the top level ("goal"/"proposal"/"spec"). T26.8: after T26.7
  # the harness output PARSES, but real claude frequently returns
  # `{"goal": {"predicates": [...]}}` (or the goal-file singular `"predicate"`
  # array), so the old top-level `Map.get(map, "predicates")` saw no list and
  # `build_predicates` reported "proposal has no predicates" — the on-ramp step-1
  # blocker. Descend into a single wrapper object so any of these shapes yields a
  # usable predicate list.
  @wrapper_keys ~w(goal proposal spec)

  # When the top level already carries a predicate array, use it as-is; otherwise
  # descend into the first wrapper object that does. A map with neither stays as-is
  # so `build_predicates` still reports the "no predicates" error cleanly.
  defp unwrap_proposal(%{} = map) do
    if extract_predicates(map) do
      map
    else
      Enum.find_value(@wrapper_keys, map, fn key ->
        case Map.get(map, key) do
          %{} = nested -> if extract_predicates(nested), do: nested
          _ -> nil
        end
      end)
    end
  end

  # The predicate array out of a proposal object, accepting both the documented
  # plural `"predicates"` key and the goal-file singular `"predicate"` array (the
  # shape a harness emits when it drafts a goal-file directly). `nil` when neither
  # is a list, so `build_predicates/1` surfaces the "no predicates" error.
  defp extract_predicates(%{} = map) do
    cond do
      is_list(Map.get(map, "predicates")) -> Map.get(map, "predicates")
      is_list(Map.get(map, "predicate")) -> Map.get(map, "predicate")
      true -> nil
    end
  end

  # The drafted goal's metadata: the authoring provenance plus the optional inline
  # rationale (T11.5, ADR-0019) -- "why these predicates / what is out of scope" --
  # which `serialize_goal/1` round-trips so the review surface can print it.
  defp draft_metadata(rationale) do
    base = %{"source" => "authoring", "proposed" => true}

    case optional_string(rationale) do
      nil -> base
      text -> Map.put(base, "rationale", text)
    end
  end

  # A JSON string decodes to its object; an already-decoded map passes through;
  # anything else (a number, a list, a decode error, nil) is an invalid proposal.
  #
  # A drafting harness (a coding agent / LLM) routinely wraps the JSON it returns
  # in a Markdown code fence (```json ... ```) or surrounds it with prose ("Here
  # are the predicates: { ... }"). Feeding that raw to Jason.decode/1 fails, which
  # is why `kazi plan "<idea>"` reported "proposal is not valid JSON" even though
  # the harness ran fine (the on-ramp's step-1 bug). So extract the JSON object
  # first; a bare object passes through unchanged.
  defp decode_proposal(proposal) when is_binary(proposal) do
    case Jason.decode(extract_json_object(proposal)) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid_proposal, "proposal JSON is not an object"}}
      {:error, _} -> {:error, {:invalid_proposal, "proposal is not valid JSON"}}
    end
  end

  defp decode_proposal(%{} = map), do: {:ok, map}
  defp decode_proposal(nil), do: {:error, {:invalid_proposal, "harness returned no proposal"}}
  defp decode_proposal(_other), do: {:error, {:invalid_proposal, "proposal is not an object"}}

  # Pull the JSON object out of possibly fenced / prose-wrapped harness output:
  # prefer the contents of a ```json (or bare ```) code fence, then narrow to the
  # span from the first "{" to the last "}". Returns the input unchanged when it
  # is already a bare object or carries no braces (so a genuinely malformed result
  # still surfaces as an "invalid JSON" error rather than being masked).
  defp extract_json_object(text) do
    unfenced =
      case Regex.run(~r/```(?:json)?\s*(.*?)```/s, text, capture: :all_but_first) do
        [body] -> body
        _ -> text
      end

    with {start, _} <- :binary.match(unfenced, "{"),
         [_ | _] = closes <- :binary.matches(unfenced, "}"),
         {stop, _} <- List.last(closes),
         true <- stop >= start do
      binary_part(unfenced, start, stop - start + 1)
    else
      _ -> String.trim(unfenced)
    end
  end

  # Build the acceptance predicate list. At least one usable predicate is
  # required (a goal with no predicate is vacuously "done" — ADR-0002); an empty
  # or non-list `predicates`, or a list with no usable entry, is rejected.
  defp build_predicates(list) when is_list(list) and list != [] do
    predicates = list |> Enum.map(&build_predicate/1) |> Enum.reject(&is_nil/1)

    case predicates do
      [] -> {:error, {:invalid_proposal, "no usable predicate in proposal"}}
      built -> {:ok, built}
    end
  end

  defp build_predicates(_), do: {:error, {:invalid_proposal, "proposal has no predicates"}}

  # One acceptance predicate from a proposal entry. Requires an id and a known
  # provider; an entry missing either, or naming an unknown provider, is dropped
  # (the surviving predicates still define the goal). `config` carries through
  # verbatim as an atom-keyed map for the evaluating provider.
  defp build_predicate(%{"id" => id, "provider" => provider} = raw)
       when is_binary(id) and id != "" and is_binary(provider) do
    case provider_kind(provider) do
      nil ->
        nil

      kind ->
        Predicate.new(id, kind,
          description: optional_string(Map.get(raw, "description")),
          acceptance?: true,
          config: predicate_config(predicate_config_source(raw))
        )
    end
  end

  defp build_predicate(_raw), do: nil

  # The provider config for a proposal entry. The documented authoring shape nests
  # it under a `"config"` key; a goal-file-shaped predicate (T26.8) instead spreads
  # config as sibling keys, so when there is no nested `"config"` map, collect the
  # non-reserved siblings — the same convention the loader uses — so that shape's
  # config survives.
  @predicate_reserved_keys ~w(id provider description guard acceptance held_out group config)
  defp predicate_config_source(%{"config" => config}) when is_map(config), do: config
  defp predicate_config_source(raw) when is_map(raw), do: Map.drop(raw, @predicate_reserved_keys)

  # --- persistence -----------------------------------------------------------

  # Persist the draft goal as a `proposed` row. The goal is serialized into the
  # canonical goal-file map (`serialize_goal/1`) so T3.5b rehydrates it through
  # `Kazi.Goal.Loader.from_map/1`. Upserts on `proposal_ref` so re-proposing the
  # same idea refreshes the draft rather than failing on the unique index — UNLESS
  # the existing row is already `approved` (#787/#793): an upsert there would
  # silently reset an approved proposal (and its audit trail) back to `proposed`
  # with different predicates, so it is refused unless the caller passes
  # `replace: true` explicitly.
  @spec persist(idea(), Goal.t(), opts()) :: {:ok, Draft.t()} | {:error, term()}
  defp persist(idea, %Goal{} = goal, opts) do
    proposal_ref = Keyword.get(opts, :proposal_ref, idea_to_proposal_ref(idea))

    with :ok <- guard_replace(proposal_ref, opts) do
      serialized = serialize_goal(goal)

      attrs = %{
        proposal_ref: proposal_ref,
        idea: idea,
        goal_id: to_string(goal.id),
        status: "proposed",
        goal: serialized,
        # session provenance (part 2): the authoring session's label, so a
        # later `approve`/`apply` (possibly from a DIFFERENT session) can
        # trace this proposal back to who planned it.
        session_name: Keyword.get(opts, :session_name),
        # T45.2 (UC-059): the shared roadmap ref, set when this proposal is a
        # member of a `kazi plan --project` roadmap; nil for a single-goal plan.
        roadmap_ref: Keyword.get(opts, :roadmap_ref)
      }

      %ProposedGoal{}
      |> ProposedGoal.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace, [:idea, :goal_id, :status, :goal, :session_name, :roadmap_ref, :updated_at]},
        conflict_target: :proposal_ref
      )
      |> case do
        {:ok, row} -> {:ok, Draft.from_row(row, goal)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Serializes a `Kazi.Goal` into the canonical goal-file map shape
  `Kazi.Goal.Loader.from_map/1` accepts (string-keyed, `[[predicate]]` array).

  This is the on-disk form persisted for a proposed goal, so the approval
  workflow (T3.5b) rehydrates it into a runnable goal through the same validated
  loader the CLI uses — round-tripping `from_map(serialize_goal(goal))` back to
  an equivalent goal. Pure and total.
  """
  @spec serialize_goal(Goal.t()) :: map()
  def serialize_goal(%Goal{} = goal) do
    predicates =
      Goal.all_predicates(goal)
      |> Enum.map(&serialize_predicate/1)

    %{
      "id" => to_string(goal.id),
      "name" => goal.name,
      "mode" => Atom.to_string(goal.mode),
      "standing" => goal.standing,
      # T12.1 group taxonomy (ADR-0020): serialize back to the `[[group]]` array
      # the loader parses, so the taxonomy round-trips through
      # `from_map(serialize_goal(goal))`. Omitted when empty (an ungrouped goal
      # serializes exactly as before).
      "group" => Enum.map(goal.groups, &serialize_group/1),
      "metadata" => stringify_keys(goal.metadata),
      "predicate" => predicates
    }
  end

  # A group as a [[group]] table. nil parent/budget are dropped so a re-load is
  # byte-stable (the loader treats an absent key the same as nil).
  defp serialize_group(%Group{} = group) do
    %{"id" => group.id, "name" => group.name}
    |> maybe_put("parent", group.parent)
    |> maybe_put("budget", group.budget)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A predicate as a [[predicate]] table: the reserved keys plus its config
  # spread back out as sibling keys (the loader collects non-reserved keys into
  # config), using the provider STRING the loader maps back to the kind atom.
  defp serialize_predicate(%Predicate{} = predicate) do
    %{
      "id" => to_string(predicate.id),
      "provider" => provider_string(predicate.kind),
      "description" => predicate.description,
      "guard" => predicate.guard?,
      "acceptance" => predicate.acceptance?
    }
    # T12.2 (ADR-0020): emit the declared group id back to the `[[predicate]]`
    # table only when set, so an ungrouped predicate round-trips byte-stably.
    |> maybe_put("group", predicate.group)
    |> Map.merge(stringify_keys(predicate.config))
  end

  # --- validation / id derivation --------------------------------------------

  defp validate_idea(idea) do
    case String.trim(idea) do
      "" -> {:error, :empty_idea}
      trimmed -> {:ok, trimmed}
    end
  end

  # A stable, human-legible goal id derived from the idea: a slug of its leading
  # words. Deterministic (same idea → same id), so re-proposing is idempotent and
  # the draft shape carries no randomness.
  @spec idea_to_goal_id(idea()) :: String.t()
  defp idea_to_goal_id(idea) do
    slug =
      idea
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.split("-", trim: true)
      |> Enum.take(6)
      |> Enum.join("-")

    case slug do
      "" -> "proposed-goal"
      slug -> slug
    end
  end

  # The proposal's review handle. Derived from the idea so re-proposing the same
  # idea upserts onto the same row; deterministic and content-stable.
  @spec idea_to_proposal_ref(idea()) :: String.t()
  defp idea_to_proposal_ref(idea) do
    digest = :crypto.hash(:sha256, idea) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "prop-" <> idea_to_goal_id(idea) <> "-" <> digest
  end

  # T39.1 (ADR-0049): in caller-drafts mode the payload's own `"idea"` — the
  # orchestrator naming the intent it is authoring — replaces the (often
  # placeholder, e.g. "caller-supplied predicates") idea the surface passed in,
  # so the persisted proposal and the `--json` result carry the caller's words.
  # Absent (or blank / undecodable payload — the parse error surfaces later in
  # `parse_proposal/2`), the given idea stands. Kazi-drafts is unchanged.
  @spec resolve_idea(term(), idea(), opts()) :: idea()
  defp resolve_idea(proposal, idea, opts) do
    with true <- Keyword.has_key?(opts, :proposal),
         {:ok, decoded} <- decode_proposal(proposal),
         map = unwrap_proposal(decoded),
         supplied when is_binary(supplied) <- Map.get(map, "idea"),
         trimmed when trimmed != "" <- String.trim(supplied) do
      trimmed
    else
      _ -> idea
    end
  end

  # The `{goal_id, proposal_ref}` pair a proposal is identified by (#787/#793).
  # Kazi-drafts (no `:proposal` opt) keeps the historical idea-derived pair
  # unchanged. Caller-drafts derives identity from the PAYLOAD itself instead of
  # the (often placeholder, e.g. "caller-supplied predicates") idea text, so two
  # differently-identified payloads land as DISTINCT proposals rather than
  # collapsing onto the same upsert slot.
  @spec resolve_identity(term(), idea(), opts()) :: {Goal.id(), String.t()}
  defp resolve_identity(proposal, idea, opts) do
    if Keyword.has_key?(opts, :proposal) do
      caller_drafts_identity(proposal, idea)
    else
      {idea_to_goal_id(idea), idea_to_proposal_ref(idea)}
    end
  end

  # Prefers an explicit payload `"goal_id"` (T39.1/ADR-0049: the orchestrator's
  # own name for the goal, used verbatim) or `"id"` (#787/#793, same verbatim
  # treatment — so re-submitting the SAME id upserts the SAME slot, same as an
  # idea-derived ref does for kazi-drafts); else a payload `"name"` (slugged,
  # digest-salted like the idea-derived ref); else falls back to the idea-derived
  # pair unchanged (the historical anonymous-payload behavior).
  defp caller_drafts_identity(proposal, idea) do
    with {:ok, decoded} <- decode_proposal(proposal) do
      map = unwrap_proposal(decoded)

      case optional_string(Map.get(map, "goal_id")) || optional_string(Map.get(map, "id")) do
        nil ->
          case optional_string(Map.get(map, "name")) do
            nil -> {idea_to_goal_id(idea), idea_to_proposal_ref(idea)}
            name -> {idea_to_goal_id(name), idea_to_proposal_ref(name)}
          end

        id ->
          {id, "prop-" <> id}
      end
    else
      _ -> {idea_to_goal_id(idea), idea_to_proposal_ref(idea)}
    end
  end

  # A CALLER-DRAFTS upsert onto a proposal_ref already `approved` would silently
  # discard that goal's approval + audit trail (#787/#793) — refuse it unless the
  # caller opts in loudly via `replace: true`. Scoped to caller-drafts (a
  # `:proposal` opt) only: kazi-drafts keeps its documented "re-proposing the
  # same idea upserts" idempotency (the idea, not the id, IS the identity there,
  # and there is no distinct-payload-collision risk to guard against).
  @spec guard_replace(String.t(), opts()) ::
          :ok | {:error, {:proposal_locked, String.t(), String.t()}}
  defp guard_replace(proposal_ref, opts) do
    caller_drafts? = Keyword.has_key?(opts, :proposal)
    replace? = Keyword.get(opts, :replace, false)

    case {caller_drafts?, ReadModel.get_proposed_goal(proposal_ref), replace?} do
      {true, %ProposedGoal{status: "approved"}, false} ->
        {:error, {:proposal_locked, proposal_ref, "approved"}}

      _ ->
        :ok
    end
  end

  # --- provider mapping ------------------------------------------------------
  #
  # Defer to the loader's provider string ↔ kind mapping (its `provider_kinds/0`,
  # the single source of truth — ADR-0002) so a proposal naming a provider maps to
  # the SAME kind the loader would, and a serialized goal round-trips through
  # `Kazi.Goal.Loader.from_map/1`. Before T26.8 authoring kept its own 4-entry copy
  # that omitted the E32 providers (`custom_script`, `static`, `ratchet`,
  # `metrics`, `coverage`, `property`, `mutation`, `cve`), so a drafted/caller
  # predicate naming one was silently dropped; delegating closes that gap and keeps
  # the catalogs from drifting again.

  defp provider_kind(provider), do: Map.get(Loader.provider_kinds(), provider)

  # Map a kind atom back to the loader's provider string. `:tests` serialises as
  # "test_runner" (the loader's name for it); an unmapped kind falls back to its
  # own atom name.
  defp provider_string(kind) do
    Enum.find_value(Loader.provider_kinds(), Atom.to_string(kind), fn {string, k} ->
      if k == kind, do: string
    end)
  end

  defp known_providers do
    Loader.provider_kinds() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end

  # --- small helpers ---------------------------------------------------------

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  # Proposal config → atom-keyed map handed to the provider (the loader's
  # convention). A non-map (or absent) config is an empty map.
  #
  # M3 (deep-review-001): a proposal is HARNESS OUTPUT — an inner agent's raw
  # stdout, i.e. untrusted input — so config keys are atomized via
  # `String.to_existing_atom/1` (never the unbounded `String.to_atom/1`), and any
  # key no provider has ever declared an atom for is dropped rather than minting
  # a fresh atom. Every legitimate provider config key is already interned at
  # compile time, so this never drops a real field.
  defp predicate_config(config) when is_map(config) do
    config
    |> Enum.flat_map(fn {key, value} ->
      case to_atom(key) do
        {:ok, atom_key} -> [{atom_key, value}]
        :unknown -> []
      end
    end)
    |> Map.new()
  end

  defp predicate_config(_config), do: %{}

  defp to_atom(key) when is_atom(key), do: {:ok, key}

  defp to_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :unknown
  end

  # Stringify map keys for the JSON/goal-file on-disk shape (atoms don't survive
  # the round-trip; the loader re-atomises config keys).
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_map), do: %{}
end
