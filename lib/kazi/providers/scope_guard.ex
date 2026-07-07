defmodule Kazi.Providers.ScopeGuard do
  @moduledoc """
  The `:scope_guard` predicate provider (issue #860): a soft-enforcement check
  that a goal's `[scope].deny` paths — files that must never be touched by this
  goal (auth config, entitlements, CI workflows) — stayed untouched.

  `Kazi.Scope.guard_predicates/1` synthesizes this predicate automatically
  whenever a goal declares `deny`, independent of the `[enforcement]` profile
  (ADR-0042) — a deny-path guard is a SCOPE contract, not an anti-gaming one.

  A violation FAILS the predicate with the offending paths named in evidence,
  which the loop feeds back to the inner agent through the SAME
  failing-evidence path every other predicate uses — no bespoke prompt wiring
  needed, the "at least soft" enforcement issue #860 asked for. It also shows
  up in the terminal `predicates[]` vector like any other predicate (T15.3),
  so the violation is "named in --json output" for free.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{PredicateResult, ScopeDiff}

  @impl true
  def evaluate(%Kazi.Predicate{config: config}, context) do
    deny_paths = Map.get(config || %{}, :deny, [])
    workspace = Map.get(context, :workspace)

    case violations(workspace, deny_paths) do
      [] ->
        PredicateResult.pass(%{deny_paths: deny_paths})

      changed ->
        PredicateResult.fail(%{
          reason: :deny_path_violation,
          deny_paths: deny_paths,
          changed: changed
        })
    end
  end

  defp violations(workspace, deny_paths) when is_binary(workspace) and deny_paths != [] do
    base_ref = ScopeDiff.base_ref(workspace)

    workspace
    |> ScopeDiff.changed_paths(base_ref)
    |> Enum.filter(&ScopeDiff.under_any?(&1, deny_paths))
  end

  defp violations(_workspace, _deny_paths), do: []
end
