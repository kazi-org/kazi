defmodule Kazi.Scope do
  @moduledoc """
  The repo and paths a goal's agents may touch (ADR-0002, concept §4).

  Scope bounds *where* fixer agents may edit. In Slice 0 it identifies the target
  workspace (a local repo path / the `--workspace` arg of `kazi run`, T0.10) and
  optionally narrows the editable paths. Later slices use the path set to seed
  blast-radius leases (ADR-0006).

  ## `write_paths` and `deny` (issue #860)

  `paths` is a coarse READ allow-list; it cannot express "the agent may read
  anything under `ios/` but should only *write* these areas." Two additional,
  optional fields close that gap:

    * `write_paths` — the editable subset of `paths` (absent/empty means no
      narrower write scope is declared; today's `paths`-only behavior is
      unchanged). `Kazi.CollateralReport` uses it to flag changes outside the
      intended write scope (proposal 3 of the issue).
    * `deny` — paths that must NEVER be modified by this goal (entitlements, auth
      config, CI workflows), enforced at least softly: `guard_predicates/1`
      synthesizes a `:scope_guard` GUARD predicate that fails (with the offending
      paths as evidence) if any changed file falls under a `deny` path (proposal 2).

  Both are additive — a goal-file with neither declared parses and behaves
  byte-identically to before this feature.

  ## `forbidden_paths`, `forbidden_commands`, `no_integration` (ADR-0085)

  Closes kazi-org/kazi#1695 and #1704: a prose exclusion list in a dispatch
  brief, or an orchestrating session's own never-seen strategy, is not a channel
  the grind model reads (`kazi/AUTHORING.md`: the dispatch prompt IS the goal
  name + failing predicates + evidence). These three fields make the same
  constraint DECLARED goal-file data instead:

    * `forbidden_paths` — like `deny`, but enforced TWICE: `guard_predicates/1`
      synthesizes a `:scope_forbidden_paths` GUARD predicate (same diff-based
      detection `deny` uses), AND `Kazi.Actions.Integrate` refuses to LAND a
      touched path (excluded from staging on the legacy commit path; the whole
      landing is refused on the `[integration]` verify-then-ship path) rather
      than merely reporting the violation after the fact. `deny` has only the
      first half of this; `forbidden_paths` is the ADR-0085 strengthening for
      paths the grind loop must structurally never land (`docs/plan.md`,
      `docs/roadmap.md` in the motivating incident).
    * `no_integration` — when `true`, forces this goal's `[integration]` block
      to the existing `mode: :none` default (`Kazi.Goal.default_integration/0`)
      REGARDLESS of what `[integration]` declares, and `Kazi.Actions.Integrate`
      refuses to run at all for this goal (no commit, no push, no PR, no merge —
      not even the legacy bulk-commit path a bare `mode: :none` goal otherwise
      still takes). Reuses the `[integration]` `none`-mode DATA shape as its
      enforcement primitive rather than inventing a second landing-mode surface.
    * `forbidden_commands` — a list of command name/pattern strings kazi
      best-effort scans the dispatch transcript for (`Kazi.Providers.ForbiddenCommands`).
      **This is a tripwire, not a sandbox**: a dispatched harness run under
      `bypassPermissions` has real shell access this ADR does not attempt to
      revoke, so a determined or confused model can still run a forbidden
      command directly — the scan only makes that VISIBLE (a failing guard
      predicate naming the matched line), it cannot prevent it. `forbidden_paths`
      and `no_integration` are structural (the controller's own tooling refuses);
      `forbidden_commands` is advisory detection only.

  All three are additive and default to the empty/off value, so a goal-file
  declaring none of them is byte-identical to before ADR-0085.
  """

  alias Kazi.Predicate

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          repo: String.t() | nil,
          paths: [String.t()],
          write_paths: [String.t()],
          deny: [String.t()],
          forbidden_paths: [String.t()],
          forbidden_commands: [String.t()],
          no_integration: boolean()
        }

  defstruct workspace: nil,
            repo: nil,
            paths: [],
            write_paths: [],
            deny: [],
            # ADR-0085 (#1695/#1704): additive fields, appended last so the
            # existing field order is untouched. See moduledoc.
            forbidden_paths: [],
            forbidden_commands: [],
            no_integration: false

  @doc """
  Builds a scope.

  ## Examples

      iex> Kazi.Scope.new(workspace: "/tmp/repo", paths: ["lib/"]).paths
      ["lib/"]
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      workspace: Keyword.get(opts, :workspace),
      repo: Keyword.get(opts, :repo),
      paths: Keyword.get(opts, :paths, []),
      write_paths: Keyword.get(opts, :write_paths, []),
      deny: Keyword.get(opts, :deny, []),
      forbidden_paths: Keyword.get(opts, :forbidden_paths, []),
      forbidden_commands: Keyword.get(opts, :forbidden_commands, []),
      no_integration: Keyword.get(opts, :no_integration, false)
    }
  end

  @doc """
  Synthesizes the `deny`-path GUARD predicate (issue #860 proposal 2), so a goal
  declaring `[scope].deny` gets a `:scope_guard` predicate appended to its guards
  independent of the `[enforcement]` profile (ADR-0042) — a deny-path is a SCOPE
  contract, not an anti-gaming one. Returns `[]` when `deny` is empty, so a goal
  with nothing declared gains no surprise guard.

  ## Examples

      iex> Kazi.Scope.guard_predicates(Kazi.Scope.new()) |> length()
      0

      iex> [p] = Kazi.Scope.guard_predicates(Kazi.Scope.new(deny: ["ios/Auth.plist"]))
      iex> {p.kind, p.guard?}
      {:scope_guard, true}
  """
  @spec guard_predicates(t()) :: [Predicate.t()]
  def guard_predicates(%__MODULE__{} = scope) do
    []
    |> maybe_deny_guard(scope.deny)
    |> maybe_forbidden_paths_guard(scope.forbidden_paths)
    |> maybe_forbidden_commands_guard(scope.forbidden_commands)
  end

  defp maybe_deny_guard(guards, []), do: guards

  defp maybe_deny_guard(guards, deny) do
    guards ++
      [
        Predicate.new(:scope_deny_paths, :scope_guard,
          guard?: true,
          description:
            "no change under a declared [scope].deny path (issue #860): " <>
              Enum.join(deny, ", "),
          config: %{deny: deny}
        )
      ]
  end

  # ADR-0085 (#1695/#1704): the STRUCTURAL half of `forbidden_paths` — the
  # automatic guard predicate. The other half (landing refuses to include a
  # touched path) lives in `Kazi.Actions.Integrate`, not here.
  defp maybe_forbidden_paths_guard(guards, []), do: guards

  defp maybe_forbidden_paths_guard(guards, forbidden_paths) do
    guards ++
      [
        Predicate.new(:scope_forbidden_paths, :scope_guard,
          guard?: true,
          description:
            "no change under a declared [scope].forbidden_paths path (ADR-0085): " <>
              Enum.join(forbidden_paths, ", "),
          config: %{forbidden_paths: forbidden_paths}
        )
      ]
  end

  # ADR-0085: the ADVISORY (never a hard sandbox) tripwire — see moduledoc and
  # `Kazi.Providers.ForbiddenCommands`.
  defp maybe_forbidden_commands_guard(guards, []), do: guards

  defp maybe_forbidden_commands_guard(guards, forbidden_commands) do
    guards ++
      [
        Predicate.new(:scope_forbidden_commands, :forbidden_commands,
          guard?: true,
          description:
            "best-effort transcript scan for a declared [scope].forbidden_commands " <>
              "pattern (ADR-0085, tripwire not a sandbox): " <>
              Enum.join(forbidden_commands, ", "),
          config: %{forbidden_commands: forbidden_commands}
        )
      ]
  end

  @doc """
  The path roots that bound this scope: `write_paths` when declared (the sharper
  signal, issue #860), else the coarser `paths` read allow-list. Callers that need
  "the set of paths this goal may touch" (T72.1, e.g. `Kazi.Fleet`'s inferred
  scope-overlap edges) should use this instead of reaching into the struct
  directly, so the write_paths-over-paths preference lives in one place.

  ## Examples

      iex> Kazi.Scope.roots(Kazi.Scope.new(write_paths: ["a/**"], paths: ["b/"]))
      ["a/**"]

      iex> Kazi.Scope.roots(Kazi.Scope.new(paths: ["b/"]))
      ["b/"]

      iex> Kazi.Scope.roots(Kazi.Scope.new())
      []
  """
  @spec roots(t()) :: [String.t()]
  def roots(%__MODULE__{write_paths: []} = scope), do: scope.paths
  def roots(%__MODULE__{write_paths: write_paths}), do: write_paths

  @doc """
  Whether any path in `paths_a` overlaps any path in `paths_b` (T72.1): two
  goals whose scopes overlap have the same blast radius and must never run
  concurrently (`Kazi.Fleet`'s inferred-edge rule).

  A path is either a plain directory/file prefix (`"pkg/foo"`) or a directory
  glob (`"pkg/foo/**"` or `"pkg/foo/*"`); a glob's `/**`/`/*` suffix is stripped
  before comparison so `"pkg/foo/**"` overlaps `"pkg/foo/bar/x.ex"` but NOT
  `"pkg/foobar/**"` — comparison is by path SEGMENT, never a raw string prefix
  (which would wrongly match `"pkg/foo"` against `"pkg/foobar"`).

  ## Examples

      iex> Kazi.Scope.overlap?(["pkg/foo/**"], ["pkg/foobar/**"])
      false

      iex> Kazi.Scope.overlap?(["pkg/foo/**"], ["pkg/foo/bar/x.ex"])
      true

      iex> Kazi.Scope.overlap?(["pkg/foo"], ["pkg/foo/bar/x.ex"])
      true

      iex> Kazi.Scope.overlap?(["lib/a"], ["lib/b"])
      false
  """
  @spec overlap?([String.t()], [String.t()]) :: boolean()
  def overlap?(paths_a, paths_b) do
    Enum.any?(paths_a, fn a -> Enum.any?(paths_b, &path_overlap?(a, &1)) end)
  end

  defp path_overlap?(a, b) do
    na = normalize_path(a)
    nb = normalize_path(b)
    String.starts_with?(na, nb) or String.starts_with?(nb, na)
  end

  defp normalize_path(path) do
    path
    |> String.trim_trailing("/**")
    |> String.trim_trailing("/*")
    |> String.trim_trailing("/")
    |> Kernel.<>("/")
  end
end
