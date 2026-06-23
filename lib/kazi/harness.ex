defmodule Kazi.Harness do
  @moduledoc """
  The harness **resolution seam** (ADR-0016, §Decision item 3): given a run's
  options, picks which coding harness kazi will drive and returns the
  `{adapter_module, adapter_opts}` the loop already consumes.

  kazi drives a coding agent as a replaceable subprocess (ADR-0001), and
  `Kazi.Loop` is already generic over its `:harness` module — but nothing fed it
  anything but Claude, because `Kazi.Runtime` hard-coded `Kazi.Harness.ClaudeAdapter`.
  This module is the single place that decides *which* harness, by a fixed
  precedence, and assembles the opts the generic adapter needs.

  ## Resolution precedence (HIGHEST first)

  The harness *id* (a stable atom like `:claude`/`:opencode`) is the first of
  these that is present:

    1. an explicit `opts[:harness]` (the CLI `--harness` flag). It may be an atom,
       or a string; a string is mapped to a KNOWN id only (never
       `String.to_atom/1`, which would leak atoms / crash) — an unrecognised
       string surfaces the same `{:unknown_harness, id}` error as an unknown atom.
    2. the goal-file `[harness]` table value `opts[:goal_harness]` (`nil` for now;
       T8.6 populates it from the loaded goal).
    3. app config `Application.get_env(:kazi, :harness)`.
    4. the default, `:claude`.

  ## Return shape

  `resolve/1` returns `{:ok, {adapter_module, adapter_opts}}` on success, or
  `{:error, {:unknown_harness, id}}` when the resolved id is not a known harness —
  so callers (Runtime/Authoring/Adopt, T8.7) can report a clean message instead
  of crashing. The id is looked up via `Kazi.Harness.Registry.fetch/1`, whose
  unknown-id error is propagated verbatim.

  ## `adapter_module`

  Always `Kazi.Harness.CliAdapter` — the one generic `Kazi.HarnessAdapter`
  implementation, parameterized by the resolved profile (ADR-0016 item 2).
  NOTE: that module is delivered in parallel by task **T8.2** and may not yet
  exist on this branch. `resolve/1` is PURE — it only returns the module as an
  atom and never calls a function on it — so referencing it compiles and runs
  fine whether or not the module is present.

  ## `adapter_opts`

  Built from the passthrough `opts[:adapter_opts]` (default `[]`), then:

    * every key NOT in the resolved profile's `supported_opts` is DROPPED, so a
      Claude-only hygiene flag (e.g. `:permission_mode`) is never forwarded to a
      harness that does not understand it. The keys `:profile`, `:model` and
      `:command` are ALWAYS kept (they are adapter-level, not harness flags);
    * `:profile` is set to the resolved `%Kazi.Harness.Profile{}` (overwriting any
      passed-through value);
    * `:model` is set from `opts[:model]` when present (a non-nil top-level
      `:model` opt overrides any `:model` already in `adapter_opts`).

  Pure apart from the single `Application.get_env/3` read.
  """

  alias Kazi.Harness.Profile
  alias Kazi.Harness.Registry

  # Delivered in parallel by T8.2; referenced as a bare atom only (never called
  # here), so this compiles whether or not the module is present on the branch.
  @cli_adapter Kazi.Harness.CliAdapter

  @default_harness :claude

  # Adapter-level opts that are ALWAYS forwarded to the CliAdapter regardless of a
  # profile's `supported_opts` (they are not harness CLI flags):
  #   * :profile — the resolved profile the generic adapter is parameterized by;
  #   * :model   — the model id (provider/model) the adapter passes to the harness;
  #   * :command — the per-run binary override (the test-stub seam, ADR-0008).
  @always_kept_opts [:profile, :model, :command]

  @typedoc "The loop-ready harness binding: the generic adapter plus its opts."
  @type binding :: {module(), keyword()}

  @doc """
  Resolves the harness for a run and returns `{:ok, {adapter_module, adapter_opts}}`,
  or `{:error, {:unknown_harness, id}}` if the resolved id is not a known harness.

  ## Options

    * `:harness` — explicit harness id (atom or string). Highest precedence.
    * `:goal_harness` — the goal-file `[harness]` value (atom; `nil` for now).
    * `:adapter_opts` — keyword opts passed through to the adapter; opts not in the
      resolved profile's `supported_opts` (except `:profile`/`:model`/`:command`)
      are dropped.
    * `:model` — the model id; placed into `adapter_opts` as `:model` when present.

  See the moduledoc for the full precedence and opt keep/drop rules.
  """
  @spec resolve(keyword()) :: {:ok, binding()} | {:error, {:unknown_harness, atom()}}
  def resolve(opts) when is_list(opts) do
    with {:ok, id} <- resolve_id(opts),
         {:ok, %Profile{} = profile} <- Registry.fetch(id) do
      {:ok, {@cli_adapter, build_adapter_opts(profile, opts)}}
    end
  end

  # --- id resolution (precedence) -------------------------------------------

  # Walks the precedence rungs and normalizes the first present value to an id.
  @spec resolve_id(keyword()) :: {:ok, atom()} | {:error, {:unknown_harness, atom()}}
  defp resolve_id(opts) do
    raw =
      first_present([
        Keyword.get(opts, :harness),
        Keyword.get(opts, :goal_harness),
        Application.get_env(:kazi, :harness)
      ]) || @default_harness

    normalize_id(raw)
  end

  # The first non-nil element, or nil if all are nil.
  @spec first_present([term()]) :: term() | nil
  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  # An atom id is taken as-is (its validity is checked by Registry.fetch/1). A
  # string is mapped to a KNOWN id only — never String.to_atom/1 — so an unknown
  # string surfaces {:unknown_harness, _} instead of crashing or leaking an atom.
  @spec normalize_id(term()) :: {:ok, atom()} | {:error, {:unknown_harness, term()}}
  defp normalize_id(id) when is_atom(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Enum.find(Registry.ids(), &(Atom.to_string(&1) == id)) do
      nil -> {:error, {:unknown_harness, id}}
      known -> {:ok, known}
    end
  end

  defp normalize_id(other), do: {:error, {:unknown_harness, other}}

  # --- adapter opts ---------------------------------------------------------

  @spec build_adapter_opts(Profile.t(), keyword()) :: keyword()
  defp build_adapter_opts(%Profile{supported_opts: supported} = profile, opts) do
    allowed = supported ++ @always_kept_opts

    (opts[:adapter_opts] || [])
    |> Keyword.take(allowed)
    |> Keyword.put(:profile, profile)
    |> put_model(opts)
  end

  # A non-nil top-level :model opt wins over any :model carried in :adapter_opts.
  @spec put_model(keyword(), keyword()) :: keyword()
  defp put_model(adapter_opts, opts) do
    case Keyword.get(opts, :model) do
      nil -> adapter_opts
      model -> Keyword.put(adapter_opts, :model, model)
    end
  end
end
