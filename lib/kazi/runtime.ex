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
  the last carrying the exceeded budget dimension as `:reason`, T1.4). Predicate
  configs may name their own provider (a goal authored against a not-yet-shipped
  provider fails loudly here, not silently at dispatch).
  """

  alias Kazi.{Goal, Loop, Predicate, ReadModel}

  require Logger

  # The concrete provider module for each predicate `kind` the Slice-0 runtime
  # can evaluate. Extending the runtime to a new provider is one entry here,
  # mirroring the loader's `provider` → `kind` table (ADR-0002).
  @provider_modules %{
    tests: Kazi.Providers.TestRunner,
    http_probe: Kazi.Providers.HttpProbe,
    prod_log: Kazi.Providers.ProdLog
  }

  # The real Slice-0 behaviour implementations bound to the loop's seams.
  @harness Kazi.Harness.ClaudeAdapter
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
    * `:integrator` — the PR/merge seam forwarded to the integrate action
      (`context.integrator`); defaults to the real `gh`-based integrator.
    * `:deploy_cmd` — the deploy command forwarded to the deploy action
      (`context.deploy_cmd`); defaults to real `gcloud`.
    * `:integrate_params` / `:deploy_params` — extra params merged into the
      integrate / deploy actions (e.g. the Cloud Run `service`/`project`/`region`
      the deploy action requires).
    * `:persist?` — project each iteration into the read-model (default `true`).
      Set `false` to run without touching SQLite.
    * `:goal_ref` — the read-model `goal_ref` (default `goal.id`).
    * `:await_timeout` — how long `run/2` blocks for termination (default
      `:infinity`).
    * `:providers` — override the predicate-kind → provider-module map (advanced;
      defaults to the built-in Slice-0 map).
    * any other option (`:live_kinds`, `:reobserve_interval_ms`, `:name`) is
      forwarded verbatim to `Kazi.Loop.start_link/1`.

  Returns `{:ok, result}` once the loop terminates, or `{:error, reason}` if the
  loop could not be started or a predicate names an unknown provider.
  """
  @spec run(Goal.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(%Goal{} = goal, opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || goal.scope.workspace
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    with {:ok, providers} <- resolve_providers(goal, opts) do
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
          :extra_action_context
        ])
        |> Keyword.merge(
          goal: goal,
          providers: providers,
          harness: @harness,
          integrate: @integrate,
          deploy: @deploy,
          workspace: workspace,
          adapter_opts: build_adapter_opts(goal, opts),
          on_iteration: build_on_iteration(goal, opts),
          integrate_params: Keyword.get(opts, :integrate_params, %{}),
          deploy_params: Keyword.get(opts, :deploy_params, %{}),
          extra_action_context: build_action_context(opts)
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
  # Harness / action context threading
  # =============================================================================

  # The harness adapter reads its command from adapter_opts (the
  # ClaudeAdapter :command seam); tests inject a stub binary the same way prod
  # passes model/flags. Anything the caller passes in :adapter_opts wins.
  defp build_adapter_opts(_goal, opts) do
    Keyword.get(opts, :adapter_opts, [])
  end

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
  # is disabled so the loop runs without the seam at all.
  defp build_on_iteration(goal, opts) do
    if Keyword.get(opts, :persist?, true) do
      goal_ref = Keyword.get(opts, :goal_ref, goal.id)

      fn payload ->
        persist_iteration(goal_ref, payload)
      end
    else
      nil
    end
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
        converged: converged?
      }
      |> maybe_put_budget_stop(Map.get(payload, :stop_reason))

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
