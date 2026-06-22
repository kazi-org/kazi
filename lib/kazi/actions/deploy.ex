defmodule Kazi.Actions.Deploy do
  @moduledoc """
  The Slice 0 **deploy** action (T0.10b, UC-015): ship the target's released
  artifact to its cloud target and return a **deploy ref** the loop records as
  evidence.

  This is the `:deploy` arm of the reconcile loop (concept §5): once a fix has
  been integrated (T0.10a) and the artifact released, the loop deploys it so the
  *live* probe (T0.5b) can verify the goal against running infrastructure — not
  just green tests. It is the thin-but-genuine version of deploy that ADR-0007's
  walking skeleton calls for; richer deploy (multi-env, rollback) is Slice 3
  (T3.3).

  ## Mechanism

  The real default mirrors the fixture's Cloud Run workflow
  (`.github/workflows/deploy-fixture.yml`, T0.13): a single

      gcloud run deploy <service> --source <dir> \\
        --project <project> --region <region> \\
        --port <port> --allow-unauthenticated --quiet \\
        --format value(status.url)

  invocation, which builds the container from source and prints the resulting
  service URL. That URL is the **deploy ref** — the exact URL the live
  `http_probe` predicate then checks (T0.5b/T0.12).

  ## Config

  Read from the action's `params`:

    * `:service` — Cloud Run service name (required)
    * `:project` — GCP project id (required)
    * `:region` — Cloud Run region, e.g. `"us-central1"` (required)
    * `:source` — directory built from source (default `"."`)
    * `:port` — container port (default `8080`, matching the fixture)
    * `:allow_unauthenticated` — pass `--allow-unauthenticated` (default `true`)

  ## Multi-environment targets (T3.3a, UC-015)

  Slice 3 deepens deploy so one action can target *different environments*
  (staging vs prod) without re-architecting (ADR-0007: deepen, don't
  re-architect). Two **additive** params drive it:

    * `:env` — the environment to deploy, e.g. `:staging` / `:prod` (an atom or
      a string). When given, its per-environment target is selected.
    * `:envs` — a map from environment to a map of per-env target overrides,
      e.g. `%{staging: %{service: "kazi-staging", project: "p-staging",
      region: "us-central1"}, prod: %{...}}`. The env's overrides are merged
      *over* the top-level params, so shared settings (`:source`, `:port`,
      `:cmd`, …) can stay at the top level and only the differing target fields
      need to live under each env.

  Selection is **back-compatible**: with neither `:env` nor `:envs` the action
  behaves exactly as before — the top-level `:service`/`:project`/`:region` are
  used. Supplying `:env` for an environment absent from `:envs` (or `:env`
  without any `:envs` map) returns a clear `{:error, {:unknown_env, env}}`
  result rather than raising.

  ## Injectable deployer (the test seam)

  The deployer command is **injectable** so tests never make a real cloud call.
  The real default is genuine `gcloud`; tests point it at a stub that emulates
  `gcloud run deploy` (echoes args, prints a fake URL, exits 0/non-zero). The
  command is resolved, in order, from:

    1. `params[:cmd]` on the action,
    2. `context[:deploy_cmd]`,
    3. application env `:kazi, Kazi.Actions.Deploy, :cmd`,
    4. the real default `"gcloud"`.

  Only tests substitute the stub; lib/ carries the real deploy logic
  (zero-stub policy).
  """

  @behaviour Kazi.Action

  alias Kazi.Action

  @default_cmd "gcloud"
  @default_source "."
  @default_port 8080

  @impl true
  def execute(%Action{kind: :deploy} = action, context) do
    with {:ok, params} <- select_env_params(action.params),
         {:ok, service} <- fetch(params, :service),
         {:ok, project} <- fetch(params, :project),
         {:ok, region} <- fetch(params, :region) do
      source = Map.get(params, :source, @default_source)
      port = Map.get(params, :port, @default_port)
      allow_unauth? = Map.get(params, :allow_unauthenticated, true)

      cmd = resolve_cmd(params, context)
      args = build_args(service, project, region, source, port, allow_unauth?)

      run(cmd, args, %{service: service, project: project, region: region})
    end
  end

  def execute(%Action{kind: kind}, _context), do: {:error, {:unsupported_kind, kind}}

  # Resolve the effective params for the chosen environment (T3.3a, UC-015).
  #
  # Back-compat: with no `:env` the params pass through unchanged, so the
  # single-target behaviour is exactly as before. With `:env`, its per-env
  # overrides from `:envs` are merged *over* the top-level params (env-specific
  # target fields win; shared fields like `:source`/`:cmd` are inherited). An
  # `:env` with no matching entry under `:envs` is a clear error, not a crash.
  defp select_env_params(params) do
    case Map.get(params, :env) do
      nil ->
        {:ok, params}

      env ->
        case Map.fetch(Map.get(params, :envs, %{}), env) do
          {:ok, overrides} when is_map(overrides) ->
            {:ok, params |> Map.drop([:env, :envs]) |> Map.merge(overrides)}

          _ ->
            {:error, {:unknown_env, env}}
        end
    end
  end

  # Build the `gcloud run deploy` argument vector. `--format value(status.url)`
  # makes gcloud emit only the service URL on stdout, which becomes the deploy
  # ref. Mirrors .github/workflows/deploy-fixture.yml.
  defp build_args(service, project, region, source, port, allow_unauth?) do
    base = [
      "run",
      "deploy",
      service,
      "--source",
      source,
      "--project",
      project,
      "--region",
      region,
      "--port",
      to_string(port)
    ]

    base
    |> maybe_append(allow_unauth?, "--allow-unauthenticated")
    |> Kernel.++(["--quiet", "--format", "value(status.url)"])
  end

  defp maybe_append(args, true, flag), do: args ++ [flag]
  defp maybe_append(args, _false, _flag), do: args

  defp run(cmd, args, meta) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        ref = parse_ref(output)

        {:ok,
         Map.merge(meta, %{
           deploy_ref: ref,
           url: ref,
           output: String.trim(output)
         })}

      {output, code} ->
        {:error, {:deploy_failed, code, String.trim(output)}}
    end
  rescue
    # System.cmd raises if the command cannot be found/executed; surface it as a
    # result so the loop branches rather than crashing.
    e in [ErlangError, ArgumentError] ->
      {:error, {:deploy_command_error, Exception.message(e)}}
  end

  # The deploy ref is the service URL gcloud prints. `value(status.url)` yields a
  # single line, but builds-from-source can emit progress lines first; take the
  # last non-empty line as the URL.
  defp parse_ref(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> ""
      line -> String.trim(line)
    end
  end

  defp resolve_cmd(params, context) do
    params[:cmd] ||
      context[:deploy_cmd] ||
      Application.get_env(:kazi, __MODULE__, [])[:cmd] ||
      @default_cmd
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:missing_param, key}}
      "" -> {:error, {:missing_param, key}}
      value -> {:ok, value}
    end
  end
end
