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
  @type mode_warning :: %{mode: term()}

  @typedoc """
  T44.5: an explicit `[harness] allowed_tools` that would DENY the git operations
  the declared landing mode performs. Names the mode and the missing operations,
  so the author sees exactly which grant is absent.
  """
  @type permission_warning :: %{
          integration_mode: String.t(),
          missing_tools: [String.t()],
          allowed_tools: [String.t()]
        }

  @type warning :: mode_warning() | permission_warning()

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
    mode_warnings(data) ++ permission_warnings(data)
  end

  def warnings(_), do: []

  defp mode_warnings(data) do
    case Map.get(data, "integration") do
      integration when is_map(integration) -> mode_warning(Map.get(integration, "mode"))
      _ -> []
    end
  end

  # T44.5 (ADR-0055): an EXPLICIT `[harness] allowed_tools` that cannot perform
  # the declared landing mode's git work.
  #
  # This is the #769 failure shape with a different trigger: the agent converges
  # the code predicates, then every `git commit` is refused, the harness exits 0,
  # and the run reports a stall no evidence explains. kazi INJECTS the right
  # defaults when no allow-list is given (Kazi.Runtime), but an explicit list is
  # the author's decision — so it is never silently widened behind their back.
  # They get told instead.
  #
  # Advisory only, and deliberately so: a house allow-list may name the same
  # operations in a form this cannot parse, and a false hard-failure on a goal
  # that would run fine is worse than a warning that is occasionally redundant.
  defp permission_warnings(data) do
    integration = map_at(data, "integration")
    harness = map_at(data, "harness")
    mode = Map.get(integration, "mode", "none")
    allowed = Map.get(harness, "allowed_tools")

    with true <- is_binary(mode) and mode != "none",
         true <- claude?(harness),
         tools when is_list(tools) and tools != [] <- allowed,
         [_ | _] = missing <- missing_operations(mode, tools) do
      [%{integration_mode: mode, missing_tools: missing, allowed_tools: tools}]
    else
      _ -> []
    end
  end

  # The git operations each landing mode performs, as the operator would write
  # them. Mirrors `Kazi.Runtime.landing_tools/1`'s intent in the vocabulary a
  # human reads (`git commit`, not `Bash(git commit:*)`), because this string is
  # what the warning shows them.
  @mode_operations %{
    "commit" => ["git add", "git commit"],
    "branch" => ["git add", "git commit", "git push"],
    "pr" => ["git add", "git commit", "git push", "gh pr"],
    "merge" => ["git add", "git commit", "git push", "gh pr"]
  }

  # An operation counts as granted when ANY allow-list entry mentions it — a
  # substring test, not an exact match, because Claude's allow-list syntax wraps
  # the command (`Bash(git commit:*)`). A blanket `Bash` grant covers everything.
  defp missing_operations(mode, tools) do
    joined = Enum.map_join(tools, " ", &to_string/1)

    if String.contains?(joined, "Bash(*)") or "Bash" in Enum.map(tools, &to_string/1) do
      []
    else
      @mode_operations
      |> Map.get(mode, [])
      |> Enum.reject(&String.contains?(joined, &1))
    end
  end

  # Absent `[harness]` resolves to the default profile, which IS claude — so a
  # missing block must read as claude here, or the warning silently never fires
  # on the most common goal-file shape.
  defp claude?(harness) do
    case Map.get(harness, "id") do
      nil -> true
      id -> to_string(id) == "claude"
    end
  end

  defp map_at(data, key) do
    case Map.get(data, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

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
