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
  """

  alias Kazi.Predicate

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          repo: String.t() | nil,
          paths: [String.t()],
          write_paths: [String.t()],
          deny: [String.t()]
        }

  defstruct workspace: nil,
            repo: nil,
            paths: [],
            write_paths: [],
            deny: []

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
      deny: Keyword.get(opts, :deny, [])
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
  def guard_predicates(%__MODULE__{deny: []}), do: []

  def guard_predicates(%__MODULE__{deny: deny}) do
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
end
