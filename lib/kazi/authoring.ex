defmodule Kazi.Authoring do
  @moduledoc """
  Idea → acceptance-predicate authoring (T3.5a, UC-017, ADR-0011).

  `Kazi.Authoring` is the one WRITE path the Slice-3 operator surfaces share. A
  human (via the CLI T3.5c, the Telegram bridge T3.7a, or the dashboard) hands
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
  alias Kazi.Authoring.Draft
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
      duplicating.
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
         {:ok, proposal} <- drive_harness(idea, opts),
         {:ok, goal} <- parse_proposal(proposal, idea_to_goal_id(idea)),
         {:ok, draft} <- persist(idea, goal, opts) do
      {:ok, draft}
    end
  end

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
  Rejects the proposed goal identified by `proposal_ref`: transitions it
  `proposed → rejected` and returns the updated `Kazi.Authoring.Draft`.

  Only a `proposed` goal may be rejected. A rejected proposal stays queryable
  (`Kazi.ReadModel.list_proposed_goals(status: "rejected")`) for audit but never
  runs. The goal payload is left untouched.

  Returns `{:ok, %Kazi.Authoring.Draft{}}` (status `:rejected`), or `{:error,
  reason}`: `{:error, :not_found}`, `{:error, {:invalid_transition, from,
  :rejected}}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec reject(String.t(), opts()) :: {:ok, Draft.t()} | {:error, term()}
  def reject(proposal_ref, opts \\ []) when is_binary(proposal_ref) and is_list(opts) do
    with {:ok, row} <- fetch_proposed(proposal_ref),
         :ok <- check_transition(row.status, "rejected"),
         {:ok, updated} <-
           ReadModel.transition_proposed_goal(proposal_ref, "rejected", row.goal),
         {:ok, goal} <- rehydrate(updated.goal) do
      {:ok, Draft.from_row(updated, goal)}
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

  @doc """
  Builds the focused prompt asking the harness to translate a prose `idea` into a
  `Kazi.Goal` of acceptance predicates (concept §10, T2.1).

  Pure and total so it can be tested directly. It instructs the harness to emit a
  single JSON object — `{"name", "predicates": [{"id", "provider", "description",
  "config"}]}` — describing checkable acceptance criteria, deliberately NOT prose
  the agent self-grades: the controller, not the agent, decides "done" (concept
  §1).

  ## Examples

      iex> prompt = Kazi.Authoring.build_prompt("a health endpoint that returns 200")
      iex> prompt =~ "a health endpoint that returns 200" and prompt =~ "acceptance"
      true
  """
  @spec build_prompt(idea()) :: String.t()
  def build_prompt(idea) when is_binary(idea) do
    """
    Translate the following software idea into a kazi goal: a set of
    machine-checkable acceptance predicates whose conjunction means the idea is
    done. Each predicate names a provider that can objectively evaluate it
    (#{known_providers()}); do not propose criteria a human has to judge by hand.

    Idea:
    #{idea}

    Respond with a SINGLE JSON object and nothing else, of the shape:

      {
        "name": "<short goal name>",
        "predicates": [
          {"id": "<stable_id>", "provider": "<provider>",
           "description": "<what must become true>", "config": { }}
        ]
      }

    Author at least one predicate. These are acceptance criteria for NEW
    behavior: they are expected to fail now and pass once the idea is built.
    """
  end

  # --- harness drive ---------------------------------------------------------

  # Drive the injectable harness adapter with the authoring prompt, in the target
  # workspace, forwarding the caller's adapter opts. The same `run/3` seam the
  # convergence loop uses — a stub adapter is injected via `:harness` in tests, so
  # no real `claude` and no network are touched.
  @spec drive_harness(idea(), opts()) :: {:ok, term()} | {:error, term()}
  defp drive_harness(idea, opts) do
    {harness, harness_opts} = resolve_harness(opts)
    workspace = Keyword.get(opts, :workspace, ".")
    adapter_opts = Keyword.merge(Keyword.get(opts, :adapter_opts, []), harness_opts)
    prompt = build_prompt(idea)

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
    with {:ok, map} <- decode_proposal(proposal),
         {:ok, predicates} <- build_predicates(Map.get(map, "predicates")) do
      {:ok,
       Goal.new(goal_id,
         name: optional_string(Map.get(map, "name")),
         mode: :create,
         predicates: predicates,
         metadata: %{"source" => "authoring", "proposed" => true}
       )}
    end
  end

  # A JSON string decodes to its object; an already-decoded map passes through;
  # anything else (a number, a list, a decode error, nil) is an invalid proposal.
  defp decode_proposal(proposal) when is_binary(proposal) do
    case Jason.decode(proposal) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid_proposal, "proposal JSON is not an object"}}
      {:error, _} -> {:error, {:invalid_proposal, "proposal is not valid JSON"}}
    end
  end

  defp decode_proposal(%{} = map), do: {:ok, map}
  defp decode_proposal(nil), do: {:error, {:invalid_proposal, "harness returned no proposal"}}
  defp decode_proposal(_other), do: {:error, {:invalid_proposal, "proposal is not an object"}}

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
          config: predicate_config(Map.get(raw, "config"))
        )
    end
  end

  defp build_predicate(_raw), do: nil

  # --- persistence -----------------------------------------------------------

  # Persist the draft goal as a `proposed` row. The goal is serialized into the
  # canonical goal-file map (`serialize_goal/1`) so T3.5b rehydrates it through
  # `Kazi.Goal.Loader.from_map/1`. Upserts on `proposal_ref` so re-proposing the
  # same idea refreshes the draft rather than failing on the unique index.
  @spec persist(idea(), Goal.t(), opts()) :: {:ok, Draft.t()} | {:error, Ecto.Changeset.t()}
  defp persist(idea, %Goal{} = goal, opts) do
    proposal_ref = Keyword.get(opts, :proposal_ref, idea_to_proposal_ref(idea))
    serialized = serialize_goal(goal)

    attrs = %{
      proposal_ref: proposal_ref,
      idea: idea,
      goal_id: to_string(goal.id),
      status: "proposed",
      goal: serialized
    }

    %ProposedGoal{}
    |> ProposedGoal.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:idea, :goal_id, :status, :goal, :updated_at]},
      conflict_target: :proposal_ref
    )
    |> case do
      {:ok, row} -> {:ok, Draft.from_row(row, goal)}
      {:error, changeset} -> {:error, changeset}
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
      "metadata" => stringify_keys(goal.metadata),
      "predicate" => predicates
    }
  end

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

  # --- provider mapping ------------------------------------------------------
  #
  # Mirror the loader's provider string ↔ kind mapping so a serialized goal
  # round-trips through `Kazi.Goal.Loader.from_map/1` and a proposal naming a
  # provider maps to the same kind the loader would.

  @provider_kinds %{
    "test_runner" => :tests,
    "http_probe" => :http_probe,
    "prod_log" => :prod_log,
    "browser" => :browser
  }

  @kind_providers Map.new(@provider_kinds, fn {string, kind} -> {kind, string} end)

  defp provider_kind(provider), do: Map.get(@provider_kinds, provider)

  # Map a kind atom back to the loader's provider string. `:tests` serialises as
  # "test_runner" (the loader's name for it).
  defp provider_string(kind), do: Map.get(@kind_providers, kind, Atom.to_string(kind))

  defp known_providers do
    @provider_kinds |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end

  # --- small helpers ---------------------------------------------------------

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  # Proposal config → atom-keyed map handed to the provider (the loader's
  # convention). A non-map (or absent) config is an empty map.
  defp predicate_config(config) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_atom(key), value} end)
  end

  defp predicate_config(_config), do: %{}

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  # Stringify map keys for the JSON/goal-file on-disk shape (atoms don't survive
  # the round-trip; the loader re-atomises config keys).
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_map), do: %{}
end
