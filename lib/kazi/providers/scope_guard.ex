defmodule Kazi.Providers.ScopeGuard do
  @moduledoc """
  The `:scope_guard` predicate provider: a diff-based check that a declared
  set of protected paths stayed untouched. Backs TWO distinct `[scope]` fields
  that share the same detection mechanism:

    * `deny` (issue #860) — soft enforcement only: a violation fails this
      predicate, and that's the whole guarantee.
    * `forbidden_paths` (ADR-0085, kazi-org/kazi#1695/#1704) — the SAME
      violation detection, but this is only HALF of `forbidden_paths`'s
      enforcement: `Kazi.Actions.Integrate` separately refuses to LAND a
      touched path (excluded from staging / the whole landing refused),
      structurally, not just detected here after the fact.

  `Kazi.Scope.guard_predicates/1` synthesizes the matching predicate
  automatically whenever a goal declares either field, independent of the
  `[enforcement]` profile (ADR-0042) — both are SCOPE contracts, not
  anti-gaming ones.

  A violation FAILS the predicate with the offending paths named in evidence,
  which the loop feeds back to the inner agent through the SAME
  failing-evidence path every other predicate uses — no bespoke prompt wiring
  needed. It also shows up in the terminal `predicates[]` vector like any
  other predicate (T15.3), so the violation is "named in --json output" for
  free.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{PredicateResult, ScopeDiff}

  @impl true
  def evaluate(%Kazi.Predicate{config: config}, context) do
    {key, paths} = target(config || %{})
    workspace = Map.get(context, :workspace)

    case violations(workspace, paths) do
      [] ->
        PredicateResult.pass(%{key => paths})

      changed ->
        PredicateResult.fail(
          %{key => paths}
          |> Map.put(:reason, violation_reason(key))
          |> Map.put(:changed, changed)
        )
    end
  end

  # ADR-0085: a `forbidden_paths` config wins when present (a predicate carries
  # exactly one of the two — `Kazi.Scope.guard_predicates/1` never sets both on
  # the same predicate); otherwise this is the original `deny` check. The
  # evidence key names match the config key verbatim (`deny_paths`/
  # `forbidden_paths`), preserving the original `deny_paths` evidence shape.
  defp target(%{forbidden_paths: forbidden_paths}), do: {:forbidden_paths, forbidden_paths}
  defp target(config), do: {:deny_paths, Map.get(config, :deny, [])}

  defp violation_reason(:forbidden_paths), do: :forbidden_path_violation
  defp violation_reason(:deny_paths), do: :deny_path_violation

  defp violations(workspace, paths) when is_binary(workspace) and paths != [] do
    base_ref = ScopeDiff.base_ref(workspace)

    workspace
    |> ScopeDiff.changed_paths(base_ref)
    |> Enum.filter(&ScopeDiff.under_any?(&1, paths))
  end

  defp violations(_workspace, _paths), do: []
end
