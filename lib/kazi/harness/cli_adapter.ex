defmodule Kazi.Harness.CliAdapter do
  @moduledoc """
  The generic `Kazi.HarnessAdapter` implementation, parameterized by a resolved
  `Kazi.Harness.Profile` (ADR-0016, T8.2).

  This is the one adapter that drives ANY CLI coding harness — `claude -p`,
  `opencode run`, Codex, gemini-cli, … — through the same thin subprocess
  boundary (ADR-0001, ADR-0008): build the argv from the profile, run
  `System.cmd` with `cd:` set to the workspace so the agent's edits land in
  place, and parse stdout via the profile's parser. The two points where
  harnesses genuinely diverge — argv assembly and stdout parsing — live in the
  profile's `build_args/parse` functions (`Kazi.Harness.Profile`); everything
  else here is shared.

  It supersedes the bespoke `Kazi.Harness.ClaudeAdapter`: driving CliAdapter with
  the `:claude` profile produces byte-identical behaviour, because that profile
  (`Kazi.Harness.Profiles.Claude`) carries Claude's exact argv + JSON-envelope
  parsing (pinned by the golden test in `profile_registry_test.exs`). T8.3 then
  makes `ClaudeAdapter` a thin shim over this adapter.

  ## Profile resolution

  `run/3` resolves the profile from `opts`, in order:

    * `opts[:profile]` — a pre-resolved `%Kazi.Harness.Profile{}` (the resolution
      seam, T8.5, hands one in). Used as-is.
    * `opts[:harness]` — an atom id (`:claude`, `:opencode`, …) looked up in
      `Kazi.Harness.Registry`. An unknown id surfaces as
      `{:error, {:unknown_harness, id}}` rather than crashing.
    * neither — defaults to `:claude`, so a caller that passes no harness gets the
      back-compatible Claude behaviour.

  The binary itself can still be overridden per run with `opts[:command]` (the
  test-stub seam, exactly as `ClaudeAdapter` does); absent it, the profile's
  default `command` is used.

  ## Prompt delivery (`profile.prompt_via`)

  Most harnesses take the prompt as an argv argument (`profile.prompt_via ==
  :argv`, the default): `build_args` renders the prompt text directly and there is
  no extra IO. A harness that must receive the prompt as a FILE sets
  `prompt_via: :file`; then this adapter writes the prompt to a TEMP FILE inside
  the workspace, threads its path to `build_args` as `opts[:prompt_file]`, runs the
  harness, and DELETES the temp file afterwards (even on error). This keeps
  `build_args` PURE — the profile only references the path the adapter
  materialized; the file IO + lifecycle live here.

  This seam exists for Antigravity (ADR-0022, T14.3): under a non-TTY subprocess
  the bare `--prompt`/`-p` flag silently drops stdout
  (`google-antigravity/antigravity-cli#76`), so the profile uses `run
  --prompt-file <tmp> --output json --yes` instead. For every other profile
  `prompt_via` defaults to `:argv` and this path is byte-identical to before.

  ## Provider env (`opts[:env]`)

  Some harnesses are pointed at a local endpoint (e.g. opencode at a locally-hosted
  Qwen3.6 model on a GPU host) via environment variables rather than CLI flags. An
  optional `opts[:env]` — a list of `{name, value}` string pairs OR a map — is
  normalized to the `[{String.t, String.t}]` shape `System.cmd/3` expects and
  forwarded as its `:env`. Malformed entries (non-string name/value) are dropped.
  When `:env` is absent or normalizes to empty, `:env` is NOT passed to
  `System.cmd` at all, so the behaviour is byte-identical to today.

  ## Transcript sink (`opts[:transcript_sink_path]`)

  T46.3 (ADR-0057 decision 3): when `opts[:transcript_sink_path]` is set, the
  harness's raw captured output is teed — as a passive, best-effort side
  effect — to that path as redacted JSONL via `Kazi.Sink.Transcript.tee/3`.
  Absent the opt, this is a no-op and the dispatch is byte-identical to the
  tee never having existed. `opts[:transcript_cap_bytes]` overrides the sink's
  default size cap.

  ## Result map

  On a successful invocation (the *process* ran; whether the agent fixed anything
  is the predicates' job to judge later), the always-present base map —

      %{output: binary(), exit: integer(), command: binary(), workspace: binary()}

  — is merged with whatever the profile's parser extracted from stdout
  (`:result`, `:tokens`, `:cost_usd`, `:touched`, `:cost => %{tokens: n}`). The
  parser is additive: a harness that reports nothing structured contributes
  nothing, and the result degrades cleanly to the base map (ADR-0008: the
  budget's token dimension then falls back to an estimate).

  When the harness could not be run at all:

      {:error, :empty_prompt}                       # nothing to dispatch
      {:error, {:command_not_found, binary()}}      # the binary is not on PATH
      {:error, {:unknown_harness, atom()}}          # no profile for the requested id
      {:error, {:prompt_file_write_failed, term()}} # a :file profile's temp write failed
  """

  @behaviour Kazi.HarnessAdapter

  alias Kazi.Economy.PriceMap
  alias Kazi.Harness.Profile
  alias Kazi.Harness.Registry
  alias Kazi.Sink.Transcript

  @default_harness :claude

  @impl true
  def run("", _workspace, _opts), do: {:error, :empty_prompt}

  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    with {:ok, profile} <- resolve_profile(opts) do
      command = opts[:command] || profile.command

      # For a `prompt_via: :file` profile (Antigravity's non-TTY workaround), write
      # the prompt to a temp file in the workspace and thread its path to
      # build_args; build_args stays pure (it only reads opts[:prompt_file]). For
      # the default `:argv` profiles this is a no-op and the path is unchanged.
      case materialize_prompt(profile, prompt, workspace, opts) do
        {:ok, build_opts, cleanup} ->
          try do
            dispatch(profile, command, prompt, workspace, build_opts)
          after
            cleanup.()
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Render the argv, run the harness in the workspace, and merge the parsed subset
  # over the always-present base map. Shared by every prompt-delivery mode.
  defp dispatch(profile, command, prompt, workspace, build_opts) do
    args = Profile.build_args(profile, prompt, build_opts)
    cmd_opts = cmd_opts(workspace, build_opts)

    try do
      {output, exit_status} = System.cmd(command, args, cmd_opts)

      base = %{
        output: output,
        exit: exit_status,
        command: command,
        workspace: workspace
      }

      # Best-effort, additive: merge the parsed structured fields over the
      # always-present base. A non-structured / field-light stdout contributes
      # nothing, so the result degrades to exactly the base map.
      result = Map.merge(base, Profile.parse(profile, output))

      # T46.3 (ADR-0057 decision 3): passive tee of the raw captured output to the
      # run's transcript sink, if configured. Best-effort and side-effect only —
      # `Kazi.Sink.Transcript.tee/3` never raises, so the dispatch result below is
      # byte-identical whether or not a sink path was threaded in.
      transcript_opts =
        case Keyword.get(build_opts, :transcript_cap_bytes) do
          nil -> []
          cap_bytes -> [cap_bytes: cap_bytes]
        end

      Transcript.tee(Keyword.get(build_opts, :transcript_sink_path), output, transcript_opts)

      # T34.5 (ADR-0046): if the harness did NOT report a dollar figure but DID
      # report a token split for a model the dated price map (`Kazi.Economy.PriceMap`)
      # prices, derive `cost_usd` from the accounted tokens. A harness-reported
      # `cost_usd` always wins (kept untouched); an unknown model omits cost
      # entirely — never a guessed figure (honest-unknown).
      {:ok, put_priced_cost(result, build_opts)}
    rescue
      error in ErlangError ->
        # :enoent surfaces here when the configured binary is not on PATH —
        # an inability to run the harness, not failing work for the agent.
        case error.original do
          :enoent -> {:error, {:command_not_found, command}}
          other -> {:error, other}
        end
    end
  end

  # T34.5 (ADR-0046): derive `cost_usd` from the dated price map ONLY when the
  # harness reported a token split but no dollar figure, and the run's model is
  # one the map prices. A harness-reported `:cost_usd` (Claude's `total_cost_usd`)
  # is authoritative and left untouched; a missing token split, a missing model,
  # or a model the map does not name leaves `cost_usd` ABSENT — never guessed.
  @spec put_priced_cost(map(), keyword()) :: map()
  defp put_priced_cost(result, build_opts) do
    with false <- Map.has_key?(result, :cost_usd),
         %{} = usage <- Map.get(result, :usage),
         model when is_binary(model) <- Keyword.get(build_opts, :model),
         {:ok, cost} <- PriceMap.cost_usd(model, usage) do
      Map.put(result, :cost_usd, cost)
    else
      _ -> result
    end
  end

  # Prepare prompt delivery for the profile's `:prompt_via` mode, returning the
  # opts to thread to build_args plus a cleanup thunk run after dispatch (always,
  # even on error/raise). `:argv` (the default) is a pure no-op. `:file` writes the
  # prompt to a unique temp file under the workspace and adds `prompt_file: <path>`
  # so build_args can reference it; the cleanup deletes the file.
  @spec materialize_prompt(Profile.t(), binary(), binary(), keyword()) ::
          {:ok, keyword(), (-> any())} | {:error, term()}
  defp materialize_prompt(%Profile{prompt_via: :file}, prompt, workspace, opts) do
    path =
      Path.join(
        workspace,
        ".kazi-prompt-#{System.unique_integer([:positive])}.txt"
      )

    case File.write(path, prompt) do
      :ok ->
        cleanup = fn -> File.rm(path) end
        {:ok, Keyword.put(opts, :prompt_file, path), cleanup}

      {:error, reason} ->
        {:error, {:prompt_file_write_failed, reason}}
    end
  end

  defp materialize_prompt(%Profile{}, _prompt, _workspace, opts) do
    {:ok, opts, fn -> :ok end}
  end

  # Assemble the `System.cmd/3` opts: always run in the workspace with stderr
  # folded into stdout (ADR-0008); pass `:env` ONLY when `opts[:env]` normalizes
  # to a non-empty list, so an absent/empty `:env` is byte-identical to today.
  @spec cmd_opts(binary(), keyword()) :: keyword()
  defp cmd_opts(workspace, opts) do
    base = [cd: workspace, stderr_to_stdout: true]

    case normalize_env(Keyword.get(opts, :env)) do
      [] -> base
      env -> Keyword.put(base, :env, env)
    end
  end

  # Normalize an `:env` opt (a `{name, value}` list OR a map) into the
  # `[{String.t, String.t}]` shape `System.cmd/3` wants, dropping malformed
  # entries (a non-string name or value). Anything else yields `[]`.
  @spec normalize_env(term()) :: [{String.t(), String.t()}]
  defp normalize_env(nil), do: []
  defp normalize_env(%{} = env), do: normalize_env(Map.to_list(env))

  defp normalize_env(env) when is_list(env) do
    Enum.flat_map(env, fn
      {name, value} when is_binary(name) and is_binary(value) -> [{name, value}]
      _ -> []
    end)
  end

  defp normalize_env(_), do: []

  # Resolve the profile: an explicit `%Profile{}` wins; else look up the `:harness`
  # atom id (defaulting to `:claude`) in the built-in registry, surfacing an
  # unknown id as a tagged error.
  @spec resolve_profile(keyword()) :: {:ok, Profile.t()} | {:error, {:unknown_harness, atom()}}
  defp resolve_profile(opts) do
    case Keyword.get(opts, :profile) do
      %Profile{} = profile -> {:ok, profile}
      _ -> Registry.fetch(Keyword.get(opts, :harness, @default_harness))
    end
  end
end
