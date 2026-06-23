defmodule Kazi.Harness.Registry do
  @moduledoc """
  The built-in registry of `Kazi.Harness.Profile`s (ADR-0016): the harnesses kazi
  ships with, looked up by their stable atom id.

  `:claude` is the default harness (and the one whose behaviour every other path
  is pinned against). Further built-in harnesses (`:opencode` in T8.4, then
  `:codex`/`:gemini_cli`/…) are added here as profile DATA — a `command`, an argv
  renderer, and a parser — not as new adapter modules. A fully custom harness is
  declared in config and resolved by the resolution seam (T8.5) without touching
  this module.

  Lookup is total: an unknown id returns a tagged `{:error, {:unknown_harness, id}}`
  so the resolution seam can report a clear message instead of crashing.
  """

  alias Kazi.Harness.Profile
  alias Kazi.Harness.Profiles

  @doc """
  Fetches the built-in profile for `id`, or `{:error, {:unknown_harness, id}}`.
  """
  @spec fetch(atom()) :: {:ok, Profile.t()} | {:error, {:unknown_harness, atom()}}
  def fetch(:claude), do: {:ok, claude()}
  def fetch(id) when is_atom(id), do: {:error, {:unknown_harness, id}}

  @doc """
  Fetches the built-in profile for `id`, raising `ArgumentError` on an unknown id.
  For call sites that have already validated the id (e.g. the default `:claude`).
  """
  @spec fetch!(atom()) :: Profile.t()
  def fetch!(id) when is_atom(id) do
    case fetch(id) do
      {:ok, profile} -> profile
      {:error, {:unknown_harness, ^id}} -> raise ArgumentError, "unknown harness: #{inspect(id)}"
    end
  end

  @doc "The ids of all built-in harnesses."
  @spec ids() :: [atom()]
  def ids, do: [:claude]

  # The :claude profile — the default. Its argv + parser are the canonical
  # Claude-specific boundary logic (`Kazi.Harness.Profiles.Claude`), pinned
  # byte-for-byte against the real `Kazi.Harness.ClaudeAdapter` by a golden test.
  # supported_opts are the claw-code hygiene flags (T4.8) Claude understands plus
  # the per-run `:command` override (the test-stub seam); a Claude-only flag is
  # therefore never forwarded to a different harness.
  @spec claude() :: Profile.t()
  defp claude do
    %Profile{
      id: :claude,
      command: "claude",
      build_args: &Profiles.Claude.build_args/2,
      parse: &Profiles.Claude.parse/1,
      supported_opts: [:command, :max_budget_usd, :allowed_tools, :permission_mode]
    }
  end
end
