defmodule Kazi.Runtime do
  @moduledoc """
  Assembles the real Slice-0 components into a running convergence loop (T0.7b,
  UC-004) — the wiring the CLI (T0.10) calls to drive a loaded `Kazi.Goal` to
  convergence.

  `Kazi.Loop` depends only on behaviours; it never names a concrete provider,
  harness, or action (see its `start_link/1` opts). This module is where the
  *concrete* Slice-0 implementations are bound to those seams:

    * **predicate → provider dispatch** — each predicate's `kind` is mapped to its
      real provider module (`:tests` → `Kazi.Providers.TestRunner`, `:http_probe`
      → `Kazi.Providers.HttpProbe`), and the loop evaluates a predicate through
      that provider's real `evaluate/2` callback (concept §3, ADR-0002);
    * **harness** — the real `Kazi.Harness.ClaudeAdapter` (drives `claude -p` in
      the workspace, ADR-0001);
    * **integrate / deploy** — the real `Kazi.Actions.Integrate` and
      `Kazi.Actions.Deploy` (T0.10a / T0.10b);
    * **persistence** — each observed iteration is projected into the SQLite
      read-model via `Kazi.ReadModel.record_iteration/1` (T0.9), wired through the
      loop's side-effect-only `:on_iteration` seam.

  Nothing here is a stub: it is the genuine production wiring (zero-stub policy).
  Tests exercise it end-to-end by pointing the *injectable seams the underlying
  modules already expose* at local stubs — the harness binary
  (`:harness_command`), the integrator (`context.integrator`), and the deploy
  command (`context.deploy_cmd`) — never by swapping a fake module in here.

  ## Entry point

      {:ok, goal} = Kazi.Goal.Loader.load("goal.toml")
      {:ok, result} = Kazi.Runtime.run(goal, workspace: "/path/to/target")

  `run/2` starts the loop, blocks until it reaches a terminal state, and returns
  the loop's `t:Kazi.Loop.result/0` (`:converged` | `:stopped` | `:over_budget`,
  the last carrying the exceeded budget dimension as `:reason`, T1.4). The result
  also carries `:release_ref` (T3.3d) — the release ref of the artifact deployed
  during the run (T3.3c tagging), or `nil` if nothing was deployed. Predicate
  configs may name their own provider (a goal authored against a not-yet-shipped
  provider fails loudly here, not silently at dispatch).
  """

  alias Kazi.{Goal, Loop, Predicate, PredicateResult, PredicateVector, ReadModel}

  require Logger

  # The concrete provider module for each predicate `kind` the Slice-0 runtime
  # can evaluate. Extending the runtime to a new provider is one entry here,
  # mirroring the loader's `provider` → `kind` table (ADR-0002).
  @provider_modules %{
    tests: Kazi.Providers.TestRunner,
    http_probe: Kazi.Providers.HttpProbe,
    prod_log: Kazi.Providers.ProdLog,
    browser: Kazi.Providers.Browser
  }

  # The real Slice-0 behaviour implementations bound to the loop's seams. The
  # harness adapter is no longer hard-coded here: it is resolved per run via
  # `Kazi.Harness.resolve/1` (T8.7, ADR-0016) so a goal/CLI/config can select
  # opencode or any other harness.
  @integrate Kazi.Actions.Integrate
  @deploy Kazi.Actions.Deploy

  @typedoc "Result handed back to the caller — the loop's terminal result."
  @type result :: Loop.result()

  @doc """
  Runs `goal` to a terminal state with the real component wiring and returns the
  loop result.

  ## Options

    * `:workspace` — the target workspace path threaded to providers / harness /
      actions (where the agent edits and where code predicates are evaluated). If
      omitted, falls back to `goal.scope.workspace`.
    * `:adapter_opts` — keyword opts forwarded to the harness adapter (e.g.
      `[command: "/path/to/stub"]` in tests, model/flags in production).
    * `:workspace_opts` — keyword opts forwarded verbatim to
      `Kazi.Workspace.prepare/2`, which runs once before each agent dispatch to
      expose the `code-review-graph` MCP in the target's `.mcp.json` and refresh
      its code graph (T4.5, ADR-0010 §3). Tests inject the `:graph_cmd` seam here
      so freshness needs no real binary; empty in production (real binary).
    * `:integrator` — the PR/merge seam forwarded to the integrate action
      (`context.integrator`); defaults to the real `gh`-based integrator.
    * `:deploy_cmd` — the deploy command forwarded to the deploy action
      (`context.deploy_cmd`); defaults to real `gcloud`.
    * `:integrate_params` / `:deploy_params` — extra params merged into the
      integrate / deploy actions (e.g. the Cloud Run `service`/`project`/`region`
      the deploy action requires).

      T3.3d deploy wiring: `:deploy_params` is also how the deepened deploy
      (T3.3a-c) is driven through the runtime — it is forwarded VERBATIM to the
      `Kazi.Actions.Deploy` action, so:

        * multi-environment selection (T3.3a): pass `env:` + an `envs:` map of
          per-environment targets, e.g.
          `deploy_params: %{env: :prod, envs: %{staging: %{...}, prod: %{...}}}`;
          the action selects the env's `service`/`project`/`region`;
        * release tagging (T3.3c) happens automatically on a successful deploy;
          its release ref is surfaced in the run outcome (the result's
          `:release_ref`) and the loop snapshot, and projected to the read-model's
          `release_ref` column (queryable via `Kazi.ReadModel.release_refs/1`).
          Override the tag with `deploy_params: %{release_ref: "v1.2.3"}` (or
          inject a tagger seam with `:tag_cmd` in tests).

      Rollback (T3.3b) is a distinct `:rollback` action the deploy module also
      implements; it is invoked directly (`Kazi.Actions.Deploy.execute(...)`) with
      the same env-aware params rather than as a step of the convergence loop,
      which never rolls back a successful reconcile.
    * `:persist?` — project each iteration into the read-model (default `true`).
      Set `false` to run without touching SQLite.
    * `:stream` — a 1-arity side-effect-only observer invoked once per observation
      with the loop's `on_iteration` payload (T15.4, ADR-0023 decision 3). Composed
      OVER the read-model projection on the SAME `on_iteration` seam, so streaming
      and persistence coexist. The CLI uses it to emit one JSONL progress event per
      iteration under `run --json --stream`. A raising observer is contained (it
      never alters convergence). Default `nil` (no streaming).
    * `:goal_ref` — the read-model `goal_ref` (default `goal.id`).
    * `:await_timeout` — how long `run/2` blocks for termination (default
      `:infinity`).
    * `:providers` — override the predicate-kind → provider-module map (advanced;
      defaults to the built-in Slice-0 map).
    * `:standing` — run as a standing (continuous/maintenance) reconciler (T3.4a,
      UC-016): the loop does not terminate at convergence but keeps re-observing
      on the bounded interval to hold the goal's predicates true. Forwarded to
      `Kazi.Loop.start_link/1`. T3.4d: when omitted it DEFAULTS to the goal's own
      declared `standing` field (so a goal-file `standing = true` runs standing
      without a flag); an explicit `:standing` here (the CLI `--standing` flag)
      OVERRIDES the goal-file. Default (neither set) `false` (converge-and-stop).
    * any other option (`:live_kinds`, `:reobserve_interval_ms`, `:name`) is
      forwarded verbatim to `Kazi.Loop.start_link/1`.

  Returns `{:ok, result}` once the loop terminates, or `{:error, reason}` if the
  loop could not be started, a predicate names an unknown provider, or the goal is
  vacuous (`{:error, :vacuous_goal}` — see the t0 guard below).

  ## Vacuous-goal guard (T2.3, UC-010, Risk R3)

  Before entering the convergence loop, `run/2` observes the goal's FULL predicate
  vector ONCE at t0 — every predicate evaluated through its real provider, the
  same dispatch the loop uses. If the whole vector is already satisfied at t0
  (every predicate passes before kazi does anything), the goal is **vacuous /
  underspecified**: a creation or repair goal must have at least one predicate
  failing at t0, otherwise "converged" would mean kazi built and verified nothing
  (concept §"creation mode", R3). Such a goal is REJECTED with
  `{:error, :vacuous_goal}`; the loop never starts and nothing is persisted as
  converged. A goal with ≥1 failing predicate at t0 proceeds to the loop normally.
  """
  @spec run(Goal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Goal{} = goal, opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || goal.scope.workspace
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    with {:ok, {adapter_module, harness_opts}} <- resolve_harness(goal, opts),
         {:ok, providers} <- resolve_providers(goal, opts),
         :ok <- guard_not_vacuous(goal, providers, workspace) do
      loop_opts =
        opts
        |> Keyword.drop([
          :workspace,
          :await_timeout,
          :integrator,
          :deploy_cmd,
          :integrate_params,
          :deploy_params,
          :persist?,
          :goal_ref,
          :providers,
          :adapter_opts,
          :extra_action_context,
          # T15.4 (ADR-0023 decision 3): the streaming observer is consumed by
          # build_on_iteration/2 (composed over the persistence projection), not
          # a Loop opt.
          :stream,
          # T8.7 harness selection: consumed by resolve_harness/2 below, not a Loop opt.
          :harness,
          :model,
          # T3.4d standing wiring: dropped here and re-set in the merge below so
          # the loop's standing mode defaults to the goal-file's declared
          # `standing`, overridable by an explicit `:standing` opt (CLI flag).
          :standing
        ])
        |> Keyword.merge(
          goal: goal,
          providers: providers,
          # T8.7 (ADR-0016): the harness adapter is RESOLVED (CLI `--harness`/`--model`
          # > goal-file `[harness]` > config > default `:claude`), not hard-coded. The
          # resolved `harness_opts` (the profile, model) are merged INTO adapter_opts so
          # the prompt-construction opts (`:retriever` etc.) survive alongside them.
          harness: adapter_module,
          integrate: @integrate,
          deploy: @deploy,
          workspace: workspace,
          adapter_opts: build_adapter_opts(goal, opts, harness_opts),
          on_iteration: build_on_iteration(goal, opts),
          integrate_params: Keyword.get(opts, :integrate_params, %{}),
          deploy_params: Keyword.get(opts, :deploy_params, %{}),
          extra_action_context: build_action_context(opts),
          # T3.4d standing wiring: the CLI `--standing` flag (an explicit
          # `:standing` opt) wins; otherwise fall back to the goal-file's own
          # declared `standing` field. So a goal authored standing runs standing
          # with no flag, and the flag can still force it on for any goal.
          standing: Keyword.get(opts, :standing, goal.standing)
        )

      with {:ok, loop} <- Loop.start_link(loop_opts) do
        result = Loop.await(loop, await_timeout)
        Loop.stop(loop)
        normalize_await(result)
      end
    end
  end

  @doc """
  The predicate-kind → concrete-provider map the runtime dispatches on. Exposed
  for tests / introspection; mirrors the loader's provider table (ADR-0002).
  """
  @spec provider_modules() :: %{optional(Predicate.provider_kind()) => module()}
  def provider_modules, do: @provider_modules

  # =============================================================================
  # Provider dispatch
  # =============================================================================

  # Build the provider map the loop needs, keyed by every predicate kind the goal
  # actually carries. A predicate naming a kind with no real provider is an
  # assembly error surfaced here (fail loud), not a silent no_provider at
  # dispatch time.
  defp resolve_providers(%Goal{} = goal, opts) do
    table = Keyword.get(opts, :providers, @provider_modules)

    kinds =
      goal
      |> Goal.all_predicates()
      |> Enum.map(& &1.kind)
      |> Enum.uniq()

    case Enum.reject(kinds, &Map.has_key?(table, &1)) do
      [] -> {:ok, Map.take(table, kinds)}
      unknown -> {:error, {:unknown_provider_kinds, unknown}}
    end
  end

  # =============================================================================
  # Vacuous-goal guard (T2.3, UC-010, Risk R3)
  # =============================================================================

  # Observe the goal's full predicate vector ONCE at t0 — every predicate through
  # its real provider, the same dispatch the loop performs each iteration — and
  # reject the goal as vacuous if the WHOLE vector is already satisfied before
  # kazi does anything. A creation/repair goal must have at least one predicate
  # failing at t0; an all-pass-at-t0 goal is underspecified, and letting it
  # "converge" would mean kazi built and verified nothing (R3). On rejection the
  # loop never starts, so nothing is persisted as converged.
  @spec guard_not_vacuous(Goal.t(), %{optional(Predicate.provider_kind()) => module()}, term()) ::
          :ok | {:error, :vacuous_goal}
  defp guard_not_vacuous(%Goal{} = goal, providers, workspace) do
    if goal |> observe_t0(providers, workspace) |> PredicateVector.satisfied?() do
      {:error, :vacuous_goal}
    else
      :ok
    end
  end

  # The t0 observation: evaluate every predicate the goal carries (predicates ++
  # guards) through its registered provider, building the same PredicateVector the
  # loop builds each iteration. A predicate whose kind has no provider can't be
  # asserted satisfied, so it is recorded :unknown (never :pass) — a goal can only
  # be vacuous if every predicate genuinely passes against the real world.
  @spec observe_t0(Goal.t(), %{optional(Predicate.provider_kind()) => module()}, term()) ::
          PredicateVector.t()
  defp observe_t0(%Goal{} = goal, providers, workspace) do
    context = %{
      goal: goal,
      scope: goal.scope,
      workspace: workspace,
      landed?: false,
      deployed?: false,
      iteration: 0
    }

    goal
    |> Goal.all_predicates()
    |> Enum.map(fn %Predicate{id: id, kind: kind} = predicate ->
      result =
        case Map.get(providers, kind) do
          nil -> PredicateResult.unknown()
          provider -> provider.evaluate(predicate, context)
        end

      {id, result}
    end)
    |> PredicateVector.new()
  end

  # =============================================================================
  # Harness / action context threading
  # =============================================================================

  # The harness adapter reads its command from adapter_opts (the
  # ClaudeAdapter :command seam); tests inject a stub binary the same way prod
  # passes model/flags. Anything the caller passes in :adapter_opts wins.
  #
  # T4.9c (ADR-0012): per-goal retrieval opt-in. Retrieval is OFF by default — a
  # goal that does not DECLARE a retriever (in `metadata[:retriever]`) threads NO
  # `:retriever` into adapter_opts, so `build_prompt/3` resolves the no-op default
  # and the prompt/loop are byte-identical to the pre-retrieval path (ADR-0012's
  # central constraint). A goal that declares one wires it into the dispatch path.
  # The caller's explicit `:adapter_opts` still wins (it is merged last), so a
  # test/operator can override or disable the goal-declared retriever.
  defp build_adapter_opts(%Goal{} = goal, opts, harness_opts) do
    caller_opts = Keyword.get(opts, :adapter_opts, [])

    base =
      case goal_retriever(goal) do
        nil -> caller_opts
        retriever -> Keyword.merge([retriever: retriever], caller_opts)
      end

    # T8.7: fold the resolved harness opts (the profile, and the resolved model)
    # over the prompt-construction opts, so `:retriever`/`:context_pack` survive
    # ALONGSIDE the harness selection. A goal-file `[harness] command` override
    # (T8.6) is applied only when nothing already set `:command` (caller/test stub
    # wins), keeping it the lowest-precedence command source.
    base
    |> Keyword.merge(harness_opts)
    |> maybe_put_goal_command(goal)
  end

  defp maybe_put_goal_command(adapter_opts, %Goal{harness: %{command: cmd}})
       when is_binary(cmd) and cmd != "",
       do: Keyword.put_new(adapter_opts, :command, cmd)

  defp maybe_put_goal_command(adapter_opts, _goal), do: adapter_opts

  # T8.7 (ADR-0016): resolve which harness adapter drives this run. Precedence is
  # the CLI `--harness`/`--model` opts > the goal-file `[harness]` table (T8.6) >
  # app config > the `:claude` default — exactly the order `Kazi.Harness.resolve/1`
  # encodes. Returns `{adapter_module, harness_opts}` or surfaces an
  # `{:error, {:unknown_harness, id}}` that aborts the run with a clear message.
  defp resolve_harness(%Goal{harness: goal_harness}, opts) do
    gh = goal_harness || %{}

    Kazi.Harness.resolve(
      harness: Keyword.get(opts, :harness),
      goal_harness: Map.get(gh, :id),
      model: Keyword.get(opts, :model) || Map.get(gh, :model)
    )
  end

  # The retriever a goal DECLARES, if any, for per-goal retrieval opt-in (T4.9c).
  # Read from `goal.metadata[:retriever]` (string or atom key, since goal-file
  # metadata may carry either): a `Kazi.Retrieval` module or `{module, init_opts}`
  # tuple. Absent the key, returns `nil` — the off-by-default state.
  @spec goal_retriever(Goal.t()) :: Kazi.Retrieval.t() | nil
  defp goal_retriever(%Goal{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :retriever) || Map.get(metadata, "retriever")
  end

  defp goal_retriever(%Goal{}), do: nil

  # Static context the loop threads into every integrate/deploy action. This is
  # how the runtime points the actions' OWN injectable seams — the integrate
  # action's `:integrator` (PR/merge) and the deploy action's `:deploy_cmd` — at
  # local stubs in tests and at the real `gh`/`gcloud` defaults in production
  # (each action falls back to its real default when the key is absent).
  defp build_action_context(opts) do
    %{}
    |> maybe_put(:integrator, Keyword.get(opts, :integrator))
    |> maybe_put(:deploy_cmd, Keyword.get(opts, :deploy_cmd))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # =============================================================================
  # Persistence (read-model projection, T0.9)
  # =============================================================================

  # Build the loop's :on_iteration side-effect callback that projects each
  # observed iteration into the SQLite read-model. Returns nil when persistence
  # is disabled AND no `:stream` observer is supplied, so the loop runs without
  # the seam at all.
  #
  # T15.4 (ADR-0023 decision 3): an optional `:stream` callback is COMPOSED here
  # over the persistence projection — the loop fires ONE `on_iteration` per
  # observation, so both the read-model write and the streaming JSONL emit happen
  # on that single seam. The stream observer runs FIRST (so an event is emitted
  # even when persistence is off / fails), then the read-model projection. Both
  # are side-effect only; a raising stream callback is contained here so it never
  # alters convergence or blocks the projection.
  defp build_on_iteration(goal, opts) do
    stream = Keyword.get(opts, :stream)
    persist? = Keyword.get(opts, :persist?, true)
    goal_ref = Keyword.get(opts, :goal_ref, goal.id)

    cond do
      is_function(stream, 1) and persist? ->
        fn payload ->
          run_stream_observer(stream, payload)
          persist_iteration(goal_ref, payload)
        end

      is_function(stream, 1) ->
        fn payload -> run_stream_observer(stream, payload) end

      persist? ->
        fn payload -> persist_iteration(goal_ref, payload) end

      true ->
        nil
    end
  end

  # T15.4: run the streaming observer, contained — a raising stream callback must
  # never alter convergence or block the persistence projection that follows it.
  defp run_stream_observer(stream, payload) do
    stream.(payload)
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.runtime stream observer raised: #{Exception.message(error)}"
      end)

      :ok
  end

  # Project one iteration. Best-effort: a read-model write must never stall or
  # alter convergence (the loop already contains the callback, but we also keep
  # the error local and logged rather than surfaced).
  #
  # T1.4 budget: an optional `:stop_reason` (present only on the loop's budget-stop
  # projection) is recorded as a `budget_stop` action so the exceeded dimension is
  # visible in the persisted iteration log.
  defp persist_iteration(
         goal_ref,
         %{
           iteration: index,
           vector: vector,
           converged?: converged?
         } = payload
       ) do
    attrs =
      %{
        goal_ref: goal_ref,
        iteration_index: index,
        predicate_vector: vector,
        converged: converged?,
        # T1.2 regression: project the observation's green→red flags so they are
        # queryable from the read-model (Kazi.ReadModel.regressions/1).
        regressions: Map.get(payload, :regressions, [])
      }
      # T3.3d deploy wiring: project the release ref recorded on a successful
      # deploy (T3.3c) into the read-model's `release_ref` column so the shipped
      # artifact is queryable via Kazi.ReadModel.release_refs/1.
      |> maybe_put_release_ref(Map.get(payload, :release_ref))
      |> maybe_put_budget_stop(Map.get(payload, :stop_reason))
      # T18.3: persistence is a PROJECTION of observed state, so re-projecting an
      # iteration_index must be idempotent. A terminal projection (stuck stop
      # reuses iterations-1; some budget paths re-touch the last index) otherwise
      # collides on the (goal_ref, iteration_index) unique index and the iteration
      # is logged as a failed insert. Always upsert from the runtime projection
      # (replace the row's final state); the read-model keeps its duplicate-
      # rejecting contract for direct callers.
      |> Map.put(:upsert?, true)

    case ReadModel.record_iteration(attrs) do
      {:ok, _iteration} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "kazi.runtime failed to persist iteration #{index} for goal=#{goal_ref}: " <>
            inspect(reason)
        end)

        :ok
    end
  end

  # T3.3d deploy wiring: stamp the iteration with the release ref of the deployed
  # artifact (T3.3c) when present, so it lands in the read-model's `release_ref`
  # column. A nil ref (nothing deployed yet) is omitted, leaving the column NULL.
  defp maybe_put_release_ref(attrs, nil), do: attrs

  defp maybe_put_release_ref(attrs, ref) when is_binary(ref),
    do: Map.put(attrs, :release_ref, ref)

  # T1.4 budget: stamp a budget-stop iteration with the action that ended the run
  # so the persisted log names the exceeded dimension.
  defp maybe_put_budget_stop(attrs, nil), do: attrs

  defp maybe_put_budget_stop(attrs, reason) do
    Map.put(attrs, :action, Kazi.Action.new(:budget_stop, params: %{reason: reason}))
  end

  # =============================================================================
  # Result normalization
  # =============================================================================

  # The loop is left running after it terminates (late await/snapshot still
  # work), but run/2 owns this loop's lifecycle, so a timeout is a real error.
  defp normalize_await({:ok, result}), do: {:ok, result}
  defp normalize_await({:error, :timeout}), do: {:error, :await_timeout}
end
