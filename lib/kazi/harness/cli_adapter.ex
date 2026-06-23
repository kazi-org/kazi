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

  ## Provider env (`opts[:env]`)

  Some harnesses are pointed at a local endpoint (e.g. opencode at the operator's
  DGX-hosted Qwen3.6 model) via environment variables rather than CLI flags. An
  optional `opts[:env]` — a list of `{name, value}` string pairs OR a map — is
  normalized to the `[{String.t, String.t}]` shape `System.cmd/3` expects and
  forwarded as its `:env`. Malformed entries (non-string name/value) are dropped.
  When `:env` is absent or normalizes to empty, `:env` is NOT passed to
  `System.cmd` at all, so the behaviour is byte-identical to today.

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

      {:error, :empty_prompt}                  # nothing to dispatch
      {:error, {:command_not_found, binary()}} # the binary is not on PATH
      {:error, {:unknown_harness, atom()}}     # no profile for the requested id
  """

  @behaviour Kazi.HarnessAdapter

  alias Kazi.Harness.Profile
  alias Kazi.Harness.Registry

  @default_harness :claude

  @impl true
  def run("", _workspace, _opts), do: {:error, :empty_prompt}

  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    with {:ok, profile} <- resolve_profile(opts) do
      command = opts[:command] || profile.command
      args = Profile.build_args(profile, prompt, opts)
      cmd_opts = cmd_opts(workspace, opts)

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
        {:ok, Map.merge(base, Profile.parse(profile, output))}
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
