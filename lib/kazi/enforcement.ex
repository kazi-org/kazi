defmodule Kazi.Enforcement do
  @moduledoc """
  The anti-gaming ENFORCEMENT profile (T32.4, ADR-0042): the machinery that turns
  the goal contract's "truth lives in the controller, not the agent" (concept §2,
  Gap 1) from a declarative marker into a guarantee a capable agent cannot quietly
  defeat.

  An enforcement profile is **default-on for goals kazi authors in creation mode**
  (the highest gaming-risk surface — the agent writes the tests/features it is then
  graded on) and **opt-in for repair goals** (operator decision, 2026-06-24). When
  active it composes five guarantees onto the ordinary reconcile loop:

    1. **clean-tree + separate-process checker isolation** — the checker is resolved
       from a CLEAN git tree (not the agent's working copy) and run in a SEPARATE OS
       process the agent cannot introspect or monkey-patch. See
       `Kazi.Enforcement.Isolation`; the verified seam is `Kazi.Loop`'s
       `run_provider/3` (the only place a provider is invoked) — the checker cwd is
       swapped for a throwaway detached worktree at `clean_ref`. The separate-process
       rung is already held: command-runner providers shell out via `System.cmd`
       (`Kazi.Providers.CommandRunner`), a fresh subprocess distinct from the agent's
       own `claude -p` dispatch. Full container isolation is DEFERRED (ADR-0042 §1).

    2. **read-only lease of predicate + test paths** — the goal's `read_only_paths`
       are content-hashed before the agent is dispatched; a path that changed after
       the iteration is a FLAGGED gaming event (`detect_writes/3`), never a silent
       edit (ADR-0042 §2). The OS-level read-only mount is the stronger rung; here a
       write is surfaced as evidence.

    3. **skipped / errored / xfail sub-results map to `:fail`** — `enforce_result/2`
       scans a checker's structured output (JUnit `<skipped>`/`<error>`, an `xfail`
       marker, or a `skipped`/`errored` count in evidence) and downgrades a `:pass`
       to `:fail` when the suite passed only by skipping work (ADR-0042 §3). This
       closes the `pytest.skip` / `exit(0)` / catch-and-swallow class.

    4. **test-count + coverage ratchets as guards** — `guard_predicates/1`
       synthesizes `:ratchet` guard predicates (via the T32.3 `Kazi.Ratchet`
       machinery) from the profile's declared `guards`, each defaulting to
       `allowed_regression: 0` ("may only improve"). Deleting/weakening a test to
       make the suite green is then a guard regression, not progress (ADR-0042 §4,
       the concrete form of ADR-0002's "test-count must not drop").

    5. **the guarantees are reported, not silent** — `guarantee_atoms/1` enumerates
       the active guarantees, and the loop tracks any flagged gaming event, so
       `kazi status`/`run --json` shows that the bar was held (ADR-0042 §7). The
       REPORTED level is the ACTUAL level: when clean-tree isolation degrades (the
       workspace is not a git repo, or the ref can't be checked out) the loop records
       it and `:clean_tree` drops out of the reported guarantees — a partial
       guarantee is visible, never assumed (the precondition's honesty bar).

  ## Held-out acceptance subset

  The optional held-out acceptance subset (ADR-0042 §6) is realized by
  `Kazi.Predicate`'s `held_out?` flag and enforced in `Kazi.Loop`'s dispatch path
  (T32.6); it is orthogonal to this profile and needs no enforcement config.
  """

  alias Kazi.{Goal, Predicate, PredicateResult}

  @typedoc """
  An enforcement profile.

    * `enabled` — whether enforcement is active for the goal.
    * `clean_tree` — resolve + run the checker from a clean detached worktree at
      `clean_ref` (guarantee 1). `true` by default; degrades gracefully (and is
      dropped from the reported guarantees) when the workspace is not a git repo.
    * `clean_ref` — the git ref the clean tree is checked out from (default
      `"HEAD"` — the last committed state, which an in-iteration edit cannot reach).
    * `read_only_paths` — repo-relative paths leased read-only to fixer agents; a
      post-iteration change to one is a flagged gaming event (guarantee 2).
    * `fail_on_skip` — map skipped/errored/xfail sub-results to `:fail` (guarantee
      3). `true` by default.
    * `guards` — declared ratchet guard configs synthesized into `:ratchet` guard
      predicates (guarantee 4). Each is a map with `:id`, `:metric`, `:direction`,
      and optional `:baseline` (default `"stored"`) / `:allowed_regression`
      (default `0`).
    * `roles` — per-role path policy (ADR-0064 d3/d7): `%{fixer: %{read_only_paths:
      [...]}, demonstrator: %{allowed_write_paths: [...]}}`. The one mechanism
      extension ADR-0064 grants — the write-disjoint fixer/demonstrator surfaces.
      Empty (`%{}`) means "no role scoping" (byte-identical to a goal with no
      scenario predicate). See `for_role/2`, `detect_role_writes/5`, and
      `with_role_defaults/2`.
  """
  @type guard_config :: %{
          required(:id) => Predicate.id(),
          required(:metric) => map(),
          optional(:direction) => :higher_better | :lower_better | String.t(),
          optional(:baseline) => number() | String.t(),
          optional(:allowed_regression) => number()
        }

  @type role :: :fixer | :demonstrator

  @type role_policy :: %{
          optional(:read_only_paths) => [String.t()],
          optional(:allowed_write_paths) => [String.t()]
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          clean_tree: boolean(),
          clean_ref: String.t(),
          read_only_paths: [String.t()],
          fail_on_skip: boolean(),
          guards: [guard_config()],
          roles: %{optional(role()) => role_policy()}
        }

  defstruct enabled: false,
            clean_tree: true,
            clean_ref: "HEAD",
            read_only_paths: [],
            fail_on_skip: true,
            guards: [],
            roles: %{}

  @doc """
  Builds an enforcement profile from a keyword/map config. Every field is optional
  and defaults to the safe-by-default value (enforcement OFF unless `:enabled`).
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts), do: struct(__MODULE__, opts)

  def new(opts) when is_map(opts) do
    struct(__MODULE__, Enum.map(opts, fn {k, v} -> {atomize(k), v} end))
  end

  @doc """
  Resolves the enforcement profile that applies to `goal`.

  An EXPLICIT profile on the goal (`goal.enforcement`, authored in the goal-file's
  `[enforcement]` table) wins — including an explicit `enabled = false` that opts a
  creation-mode goal OUT. With nothing authored, the default policy applies:
  **default-on for creation-mode goals** (the agent writes what it is graded on),
  **off for repair goals** (opt-in). The returned profile always has `enabled` set
  to a concrete boolean.

  ## Examples

      iex> Kazi.Enforcement.resolve(Kazi.Goal.new("g", mode: :create)).enabled
      true

      iex> Kazi.Enforcement.resolve(Kazi.Goal.new("g", mode: :repair)).enabled
      false
  """
  @spec resolve(Goal.t()) :: t()
  def resolve(%Goal{enforcement: %__MODULE__{} = profile}), do: profile

  def resolve(%Goal{} = goal) do
    %__MODULE__{enabled: Goal.create?(goal)}
  end

  @doc "Whether enforcement is active (a convenience over the `enabled` field)."
  @spec active?(t() | nil) :: boolean()
  def active?(%__MODULE__{enabled: enabled}), do: enabled == true
  def active?(_), do: false

  @doc """
  Whether the clean-tree + separate-process checker isolation should run for this
  profile — active enforcement with `clean_tree` set.
  """
  @spec isolate?(t() | nil) :: boolean()
  def isolate?(%__MODULE__{enabled: true, clean_tree: true}), do: true
  def isolate?(_), do: false

  @doc """
  The CONFIGURED enforcement guarantees as a stable, sorted list of atoms — the
  bar this profile is meant to hold. The loop downgrades this to the ACTUAL active
  set (e.g. dropping `:clean_tree` if isolation degraded) before reporting, so a
  partial guarantee is visible (ADR-0042 §7, the precondition honesty bar).

  An inactive profile has no guarantees (`[]`).

  ## Examples

      iex> p = Kazi.Enforcement.new(enabled: true, read_only_paths: ["test/"], guards: [%{id: :c, metric: %{cmd: "x"}}])
      iex> Kazi.Enforcement.guarantee_atoms(p)
      [:clean_tree, :fail_on_skip, :ratchet_guards, :read_only_lease, :separate_process]
  """
  @spec guarantee_atoms(t() | nil) :: [atom()]
  def guarantee_atoms(%__MODULE__{enabled: true} = profile) do
    [:separate_process]
    |> prepend_if(profile.clean_tree, :clean_tree)
    |> prepend_if(profile.read_only_paths != [], :read_only_lease)
    |> prepend_if(profile.fail_on_skip, :fail_on_skip)
    |> prepend_if(profile.guards != [], :ratchet_guards)
    |> Enum.sort()
  end

  def guarantee_atoms(_), do: []

  defp prepend_if(list, true, atom), do: [atom | list]
  defp prepend_if(list, _false, _atom), do: list

  @doc """
  Synthesizes the profile's declared ratchet `guards` into `:ratchet` GUARD
  predicates (guarantee 4). Each guard config becomes a `Kazi.Predicate` of kind
  `:ratchet` marked `guard?: true`, defaulting `baseline` to `"stored"` and
  `allowed_regression` to `0` (the "may only improve" ADR-0042 substrate). The loop
  evaluates these alongside the goal's own guards, so deleting a test (a
  test-count metric dropping) trips the guard.

  Returns `[]` when enforcement is inactive or no guards are declared, so a
  default-on creation goal with nothing configured gains no surprise guards.
  """
  @spec guard_predicates(t() | nil) :: [Predicate.t()]
  def guard_predicates(%__MODULE__{enabled: true, guards: guards}) when is_list(guards) do
    Enum.map(guards, &guard_predicate/1)
  end

  def guard_predicates(_), do: []

  defp guard_predicate(%{id: id, metric: metric} = guard) do
    config =
      %{
        metric: metric,
        direction: Map.get(guard, :direction, :higher_better),
        baseline: Map.get(guard, :baseline, "stored"),
        allowed_regression: Map.get(guard, :allowed_regression, 0)
      }

    Predicate.new(id, :ratchet, config: config, guard?: true)
  end

  @doc """
  Applies the skipped/errored/xfail → `:fail` mapping (guarantee 3) to a result.

  When enforcement is inactive or `fail_on_skip` is off, the result is returned
  unchanged. Otherwise a `:pass` whose evidence shows a skipped, errored, or xfail
  sub-result is DOWNGRADED to `:fail` — the suite "passed" only by not running
  work, which the controller treats as not-passing (ADR-0042 §3). A genuinely
  failing/erroring/already-downgraded result is untouched, and a clean pass with no
  skips is untouched.

  Detection scans, in order: a structured `skipped` / `errored` / `xfail` count in
  the evidence map; JUnit `<skipped .../>` / `<error .../>` elements or an `xfail`
  marker in the retained `:output`.
  """
  @spec enforce_result(t() | nil, PredicateResult.t()) :: PredicateResult.t()
  def enforce_result(%__MODULE__{enabled: true, fail_on_skip: true}, %PredicateResult{
        status: :pass,
        evidence: evidence
      }) do
    case skip_reason(evidence) do
      nil ->
        PredicateResult.new(:pass, evidence)

      reason ->
        PredicateResult.new(:fail, Map.put(evidence, :enforcement_downgrade, reason))
    end
  end

  def enforce_result(_profile, %PredicateResult{} = result), do: result

  # The reason a passing result is downgraded, or nil if it is a clean pass. A
  # structured count in evidence is authoritative; otherwise the retained output is
  # scanned for the JUnit/xfail markers a test runner emits.
  defp skip_reason(evidence) when is_map(evidence) do
    cond do
      positive_count?(evidence, :skipped) -> :skipped
      positive_count?(evidence, :errored) -> :errored
      positive_count?(evidence, :xfail) -> :xfail
      true -> output_skip_reason(Map.get(evidence, :output))
    end
  end

  defp skip_reason(_evidence), do: nil

  defp positive_count?(evidence, key) do
    case Map.get(evidence, key) do
      n when is_integer(n) and n > 0 -> true
      _ -> false
    end
  end

  defp output_skip_reason(output) when is_binary(output) do
    cond do
      Regex.match?(~r/<skipped\b/, output) -> :skipped
      Regex.match?(~r/<error\b/, output) -> :errored
      Regex.match?(~r/\bxfail\b/, output) -> :xfail
      true -> nil
    end
  end

  defp output_skip_reason(_output), do: nil

  @doc """
  Content-hashes the profile's `read_only_paths`, resolved relative to `workspace`,
  into a `%{path => digest}` snapshot. A missing path hashes to `:absent`; a
  directory hashes its sorted file tree, so adding/removing a file under a leased
  directory is detected too. Pairs with `detect_writes/3`.
  """
  @spec digest_paths(String.t() | nil, [String.t()]) :: %{optional(String.t()) => term()}
  def digest_paths(workspace, paths) when is_binary(workspace) and is_list(paths) do
    Map.new(paths, fn rel -> {rel, digest(Path.join(workspace, rel))} end)
  end

  def digest_paths(_workspace, _paths), do: %{}

  @doc """
  Detects writes to read-only-leased paths by re-hashing them and comparing to the
  `before` snapshot from `digest_paths/2`. Returns a list of flagged gaming events
  (`%{type: :read_only_write, path: rel}`) for every path whose digest changed —
  the surfaced "a write attempt is a flagged event" of ADR-0042 §2. No change
  yields `[]`.
  """
  @spec detect_writes(String.t() | nil, [String.t()], %{optional(String.t()) => term()}) :: [
          map()
        ]
  def detect_writes(workspace, paths, before) when is_binary(workspace) and is_map(before) do
    after_snapshot = digest_paths(workspace, paths)

    for rel <- paths, Map.get(before, rel) != Map.get(after_snapshot, rel) do
      %{type: :read_only_write, path: rel}
    end
  end

  def detect_writes(_workspace, _paths, _before), do: []

  # ===========================================================================
  # Role-scoped enforcement (ADR-0064 d3/d7) — the write-disjoint fixer /
  # demonstrator surfaces. This is the ONE mechanism extension ADR-0064 grants:
  # `read_only_paths` made role-scoped, plus its inversion for the demonstrator.
  # ===========================================================================

  @doc """
  Resolves the path policy for `role` from the profile's `roles` map.

  Returns the role's policy map (`%{read_only_paths: [...]}` for `:fixer`,
  `%{allowed_write_paths: [...]}` for `:demonstrator`), or `%{}` when the role has
  no policy. The resolver for the role-scoped write detection.

  ## Examples

      iex> p = Kazi.Enforcement.new(roles: %{fixer: %{read_only_paths: ["a"]}})
      iex> Kazi.Enforcement.for_role(p, :fixer)
      %{read_only_paths: ["a"]}
      iex> Kazi.Enforcement.for_role(p, :demonstrator)
      %{}
  """
  @spec for_role(t(), role()) :: role_policy()
  def for_role(%__MODULE__{roles: roles}, role) when is_map(roles), do: Map.get(roles, role, %{})

  @doc """
  Detects role-scoped write violations over the SAME digest diff as
  `detect_writes/3`.

    * `:fixer` — writes to the role's `read_only_paths` are `:read_only_write`
      violations. Unchanged ADR-0042 §2 lease semantics, now nameable; `before` is
      the `digest_paths/2` snapshot of those paths and `changed_paths` is ignored.
    * `:demonstrator` — INVERTED: a write to any `changed_paths` entry that is NOT
      under the role's `allowed_write_paths` is a `:disallowed_write` violation
      (everything is read-only EXCEPT the pin the demonstrator mints). `before` is
      the snapshot of `changed_paths`; the same diff mechanism, the opposite
      direction.

  Falls back to the profile's top-level `read_only_paths` for a `:fixer` with no
  role policy, and to no allowed paths for a `:demonstrator` with none (so every
  write is disallowed).
  """
  @spec detect_role_writes(t(), role(), String.t() | nil, %{optional(String.t()) => term()}, [
          String.t()
        ]) :: [map()]
  def detect_role_writes(profile, role, workspace, before, changed_paths \\ [])

  def detect_role_writes(%__MODULE__{} = profile, :fixer, workspace, before, _changed_paths) do
    detect_writes(workspace, fixer_read_only_paths(profile), before)
  end

  def detect_role_writes(%__MODULE__{} = profile, :demonstrator, workspace, before, changed_paths)
      when is_list(changed_paths) do
    allowed = demonstrator_allowed_write_paths(profile)

    workspace
    |> detect_writes(changed_paths, before)
    |> Enum.reject(fn %{path: path} -> under_any?(path, allowed) end)
    |> Enum.map(fn violation -> %{violation | type: :disallowed_write} end)
  end

  @doc """
  Derives the per-role path policy from a goal's scenario predicates (ADR-0064
  d3/d7) when no `roles` were authored.

  `scenario_paths` is `%{specs: [...], pins: [...]}`. An explicit non-empty `roles`
  wins untouched (the author owns it). With no scenario paths the profile is
  returned unchanged, so a goal with no scenario predicate is byte-identical.
  Otherwise the fixer's `read_only_paths` gains every spec + pin (the pin is a
  grader artifact) and the demonstrator may write ONLY the pins.
  """
  @spec with_role_defaults(t(), %{specs: [String.t()], pins: [String.t()]}) :: t()
  def with_role_defaults(%__MODULE__{roles: roles} = profile, _paths) when roles != %{},
    do: profile

  def with_role_defaults(%__MODULE__{} = profile, %{specs: specs, pins: pins})
      when is_list(specs) and is_list(pins) do
    if specs == [] and pins == [] do
      profile
    else
      %{
        profile
        | roles: %{
            fixer: %{read_only_paths: Enum.uniq(profile.read_only_paths ++ specs ++ pins)},
            demonstrator: %{allowed_write_paths: Enum.uniq(pins)}
          }
      }
    end
  end

  defp fixer_read_only_paths(%__MODULE__{} = profile) do
    case for_role(profile, :fixer) do
      %{read_only_paths: paths} when is_list(paths) -> paths
      _ -> profile.read_only_paths
    end
  end

  defp demonstrator_allowed_write_paths(%__MODULE__{} = profile) do
    case for_role(profile, :demonstrator) do
      %{allowed_write_paths: paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  defp under_any?(path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  # Hash a path's contents: a file by its bytes, a directory by the sorted
  # {relative-path, file-hash} tree (so a new/deleted file under it changes the
  # digest), an absent path to the :absent sentinel.
  defp digest(path) do
    cond do
      File.regular?(path) -> file_hash(path)
      File.dir?(path) -> dir_hash(path)
      true -> :absent
    end
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> :absent
    end
  end

  defp dir_hash(path) do
    entries =
      path
      |> list_files_recursive()
      |> Enum.sort()
      |> Enum.map(fn file -> {Path.relative_to(file, path), file_hash(file)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(entries))
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)
      if File.dir?(full), do: list_files_recursive(full), else: [full]
    end)
  rescue
    File.Error -> []
  end

  defp atomize(k) when is_atom(k), do: k
  defp atomize(k) when is_binary(k), do: String.to_existing_atom(k)
end
