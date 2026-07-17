defmodule Kazi.Goal.IntegrationLint do
  @moduledoc """
  Advisory lint over a goal-file's `[integration]` block (T44.1, ADR-0055) —
  warns on an unknown `mode` value.

  The loader (`Kazi.Goal.Loader`) is the STRICT net: an unknown `[integration]`
  `mode` is a hard load error, so `kazi apply` refuses to run a goal with a
  garbage mode. This module is the ADVISORY net `kazi lint` uses: it inspects the
  RAW decoded TOML (independent of whether the goal loads) and reports an unknown
  mode as a warning, so an author running `kazi lint` on a draft sees the exact
  bad value pointed out even though the goal would not load.

  It is ADVISORY ONLY — it returns warnings, it never fails anything. The known
  modes are `Kazi.Goal.Loader.integration_modes/0`, so this net cannot drift from
  the loader's accepted set.

  Pure and total: a function of the decoded TOML map only — no I/O, no process
  state. The same input always yields the same warnings.
  """

  @typedoc "An unknown-integration-mode warning, naming the offending `mode` value."
  @type warning :: %{mode: term()}

  @doc """
  Lints a decoded goal-file TOML map's `[integration]` block for an unknown
  `mode`.

  Returns `[]` when the block is absent, has no `mode`, or names a KNOWN mode;
  otherwise a one-element list naming the bad value. ADVISORY — never an error.

  ## Examples

      iex> Kazi.Goal.IntegrationLint.warnings(%{"integration" => %{"mode" => "branch"}})
      []

      iex> Kazi.Goal.IntegrationLint.warnings(%{"integration" => %{"mode" => "rebase"}})
      [%{mode: "rebase"}]

      iex> Kazi.Goal.IntegrationLint.warnings(%{"id" => "g"})
      []
  """
  @spec warnings(map()) :: [warning()]
  def warnings(data) when is_map(data) do
    case Map.get(data, "integration") do
      integration when is_map(integration) ->
        mode_warning(Map.get(integration, "mode"))

      _ ->
        []
    end
  end

  def warnings(_), do: []

  # No mode declared -> the loader defaults it to "none"; nothing to warn about.
  defp mode_warning(nil), do: []

  defp mode_warning(mode) do
    if is_binary(mode) and Map.has_key?(Kazi.Goal.Loader.integration_modes(), mode) do
      []
    else
      [%{mode: mode}]
    end
  end

  @doc """
  The known `[integration]` modes, sorted, for a warning message. Delegates to
  the loader so the advisory net names exactly the set the loader accepts.

  ## Examples

      iex> Kazi.Goal.IntegrationLint.known_modes()
      "branch, commit, merge, none, pr"
  """
  @spec known_modes() :: String.t()
  def known_modes do
    Kazi.Goal.Loader.integration_modes() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end
end
