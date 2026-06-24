defmodule Kazi.Goal.Loader do
  @moduledoc """
  Loads a goal from a TOML *goal-file* on disk and parses it into a
  `Kazi.Goal` struct (with its `Kazi.Predicate` list), faithful to the T0.3
  domain types (ADR-0002, concept §4). This is the on-disk authoring format the
  Slice 0 dogfood (T0.12) and the CLI (`kazi run <goal-file>`, T0.10) load.

  A goal-file is *declarative*: it names a goal, its budget/scope, and the
  predicates whose conjunction defines "done". The loader is the only place the
  string authoring format is translated into the in-memory domain; everything
  downstream (loop T0.7, providers T0.5/T0.5b, read-model T0.9) builds against
  the structs, never the TOML.

  ## Goal-file TOML schema

  Top level (the goal itself):

  | Key      | TOML type | Required | Maps to             |
  |----------|-----------|----------|---------------------|
  | `id`     | string    | yes      | `Goal.id`           |
  | `name`   | string    | no       | `Goal.name`         |
  | `mode`   | string    | no       | `Goal.mode` — `"repair"` (default) or `"create"` |
  | `standing` | boolean | no       | `Goal.standing` — `true` for a standing/maintenance goal (default `false`) |
  | `metadata` | table   | no       | `Goal.metadata` (string-keyed map, verbatim) |

  `mode = "create"` declares a *creation-mode* goal whose predicates are
  acceptance criteria for NEW behavior, authored to fail at t0 (T2.1, concept
  §10 Slice 2). It records authoring intent; it does not change how the loop
  evaluates predicates. An unknown `mode` is a validation error.

  `standing = true` declares a STANDING (continuous/maintenance) reconciler
  (T3.4d, UC-016): the loop does NOT terminate at convergence but keeps
  re-observing on a bounded interval to hold the predicates true forever
  (concept §10 "standing reconcilers"). Omitted (or `false`) is the default
  one-shot converge-and-stop goal. The standing-mode loop behaviour itself is
  T3.4a; this key is how a goal *authors* it. The CLI `--standing` flag
  (`kazi run … --standing`) overrides whatever the goal-file declares. A
  non-boolean `standing` is a validation error.

  ### `[budget]` table (optional, → `Kazi.Budget`)

  | Key                 | TOML type        | Maps to                  |
  |---------------------|------------------|--------------------------|
  | `max_iterations`    | positive integer | `Budget.max_iterations`  |
  | `max_wall_clock_ms` | positive integer | `Budget.max_wall_clock_ms` |
  | `max_tokens`        | positive integer | `Budget.max_tokens`      |

  Omitted dimensions are unbounded (`nil`).

  ### `[scope]` table (optional, → `Kazi.Scope`)

  | Key         | TOML type        | Maps to          |
  |-------------|------------------|------------------|
  | `workspace` | string           | `Scope.workspace` |
  | `repo`      | string           | `Scope.repo`     |
  | `paths`     | array of strings | `Scope.paths`    |

  ### `[harness]` table (optional, → `Goal.harness`, T8.6/ADR-0016)

  Declares which coding harness this goal prefers to be driven by. Absent → the
  goal's `harness` stays `nil` (no goal-level preference; resolution falls
  through to config/default). Loaded as a `%{id:, model:, command:}` map.

  | Key       | TOML type | Maps to              |
  |-----------|-----------|----------------------|
  | `id`      | string    | `harness.id` — a KNOWN harness id atom (`"claude"`, `"opencode"`, …); an unknown id is a validation error (never `String.to_atom/1`, so a typo cannot leak an atom) |
  | `model`   | string    | `harness.model` — optional provider/model override |
  | `command` | string    | `harness.command` — optional binary override |

  `id` is required when a `[harness]` table is present. The loaded `id` threads
  into `Kazi.Harness.resolve/1` as `:goal_harness` (the wiring itself is T8.7).

  ### `[[group]]` array of tables (→ `Goal.groups`, T12.1/ADR-0020)

  Declares the goal's *group taxonomy* — the vocabulary by which a large goal
  organizes its predicates into a tree (pillar → domain → capability). Absent →
  `Goal.groups` stays `[]` (an ungrouped goal, loading exactly as before).

  | Key      | TOML type | Required | Maps to              |
  |----------|-----------|----------|----------------------|
  | `id`     | string    | yes      | `Group.id` — normalized to a canonical slug (case / whitespace / `&` collapse), so loosely-authored variants cannot fragment the tree |
  | `name`   | string    | no       | `Group.name` — the display label (defaults to the authored `id` when omitted) |
  | `parent` | string    | no       | `Group.parent` — a parent group id (normalized). Validated to reference a DECLARED group, and the parent chain to be acyclic (T12.2) |
  | `budget` | positive integer | no | `Group.budget` — an optional per-group cap (stored verbatim) |

  A DUPLICATE group id (after normalization) is a validation error, so the
  taxonomy is a set: declaring `"Identity & Access"` and `"identity-access"`
  twice fails loudly at load time rather than silently colliding.

  T12.2 adds the *drift guard* — three cross-references validated after the
  taxonomy and predicates are both parsed (ADR-0020 §Decision 3):

    * a predicate whose `group` is not a declared id is a load error (catches the
      typo immediately, rather than fragmenting the tree silently);
    * a group whose `parent` is not a declared id is a load error;
    * a cycle in the `parent` chain is a load error.

  ### `[[predicate]]` array of tables (→ `Kazi.Predicate` list)

  At least one is required. A predicate flagged `guard = true` is sorted into the
  goal's `guards` (an invariant that must not regress); all others become
  ordinary `predicates`.

  | Key           | TOML type | Required | Maps to                |
  |---------------|-----------|----------|------------------------|
  | `id`          | string    | yes      | `Predicate.id`         |
  | `provider`    | string    | yes      | `Predicate.kind` (see below) |
  | `description` | string    | no       | `Predicate.description` |
  | `guard`       | boolean   | no       | `Predicate.guard?` (default `false`) |
  | `acceptance`  | boolean   | no       | `Predicate.acceptance?` (default `false`) |
  | `group`       | string    | no       | `Predicate.group` — a declared `[[group]]` id (normalized); an unknown id is a load error (T12.2) |
  | *(any other)* | any       | no       | `Predicate.config` (atom-keyed, verbatim) |

  Every key on a `[[predicate]]` table other than the six reserved keys above is
  collected, verbatim, into the predicate's `config` map (with atom keys). That
  config is handed untouched to the provider that evaluates the predicate.

  `acceptance = true` marks a predicate as an acceptance criterion (creation
  mode, T2.1) — desired NEW behavior expected to fail at t0. It is a declarative
  marker only; evaluation is unchanged. A predicate may not be both a `guard` and
  an `acceptance` predicate (a guard is an invariant, not a goal to reach).

  #### Provider kinds

  The `provider` string is mapped to the registry `kind` atom the controller
  dispatches on:

  | `provider` string | `Predicate.kind` | Provider (task) |
  |-------------------|------------------|-----------------|
  | `"test_runner"`   | `:tests`         | test-runner (T0.5) |
  | `"http_probe"`    | `:http_probe`    | live probe (T0.5b) |
  | `"prod_log"`      | `:prod_log`      | prod-log query (T1.6) |
  | `"browser"`       | `:browser`       | Playwright UI check (T2.2) |

  An unknown `provider` is a validation error rather than a silently-accepted
  atom, so a typo fails loudly at load time instead of at dispatch time.

  ## Example

  See `priv/examples/deploy_target.toml` — the goal-file the Slice 0 dogfood
  (T0.12) drives, targeting the `fixtures/deploy-target/` Go service.

      {:ok, goal} = Kazi.Goal.Loader.load(path)

  Returns `{:ok, %Kazi.Goal{}}` or `{:error, reason}` with a human-readable,
  caller-facing reason string.
  """

  alias Kazi.{Budget, Goal, Predicate, Scope}
  alias Kazi.Goal.Group
  alias Kazi.Harness.Registry

  # provider string -> Predicate.kind atom. Adding a provider kind here is the
  # only change needed to author goals against a new provider (ADR-0002).
  @provider_kinds %{
    "test_runner" => :tests,
    "http_probe" => :http_probe,
    "prod_log" => :prod_log,
    "browser" => :browser
  }

  # Reserved keys on a [[predicate]] table; everything else falls through to
  # the predicate's `config`. `group` (T12.2) is reserved so a declared group
  # reference does not leak into the provider config.
  @predicate_reserved_keys ~w(id provider description guard acceptance group)

  # goal-file `mode` string -> Goal.mode atom (T2.1 creation mode).
  @goal_modes %{"repair" => :repair, "create" => :create}

  @doc """
  Reads the TOML goal-file at `path` and parses it into a `Kazi.Goal`.

  Returns `{:ok, goal}` on success, or `{:error, reason}` with a human-readable
  reason for a missing file, malformed TOML, or a schema violation.
  """
  @spec load(Path.t()) :: {:ok, Goal.t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, data} <- parse_toml(contents) do
      from_map(data)
    end
  end

  @doc """
  Parses an already-decoded TOML map (string-keyed) into a `Kazi.Goal`.

  Exposed so callers that obtain the map another way (e.g. an embedded goal)
  reuse the same validation as `load/1`.
  """
  @spec from_map(map()) :: {:ok, Goal.t()} | {:error, String.t()}
  def from_map(data) when is_map(data) do
    with {:ok, id} <- fetch_id(data),
         {:ok, mode} <- fetch_mode(data),
         # T3.4d standing wiring: optional top-level `standing` boolean (UC-016).
         {:ok, standing} <- fetch_standing(data),
         {:ok, budget} <- build_budget(Map.get(data, "budget", %{})),
         {:ok, scope} <- build_scope(Map.get(data, "scope", %{})),
         # T8.6 harness selection (ADR-0016): optional `[harness]` table.
         {:ok, harness} <- build_harness(Map.get(data, "harness")),
         # T12.1 group taxonomy (ADR-0020): optional `[[group]]` array.
         {:ok, groups} <- build_groups(Map.get(data, "group", [])),
         {:ok, all} <- build_predicates(Map.get(data, "predicate", [])),
         # T12.2 drift guard (ADR-0020 §Decision 3): cross-validate the taxonomy
         # once both groups and predicates are parsed — every predicate `group`
         # and every group `parent` must reference a DECLARED id, and the parent
         # chain must be acyclic.
         :ok <- validate_group_references(groups, all) do
      {predicates, guards} = Enum.split_with(all, &(not &1.guard?))

      {:ok,
       Goal.new(id,
         name: Map.get(data, "name"),
         mode: mode,
         predicates: predicates,
         guards: guards,
         budget: budget,
         scope: scope,
         standing: standing,
         harness: harness,
         groups: groups,
         metadata: Map.get(data, "metadata", %{})
       )}
    end
  end

  def from_map(_other), do: {:error, "goal-file must decode to a table (got a non-map value)"}

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read goal-file #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_toml(contents) do
    case Toml.decode(contents) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "malformed TOML: #{format_toml_error(reason)}"}
    end
  end

  defp format_toml_error({:invalid_toml, message}) when is_binary(message), do: message
  defp format_toml_error(reason) when is_binary(reason), do: reason
  defp format_toml_error(reason), do: inspect(reason)

  defp fetch_id(data) do
    case Map.get(data, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "goal-file is missing required key \"id\""}
      _ -> {:error, "goal \"id\" must be a non-empty string"}
    end
  end

  # T2.1: optional goal `mode` ("repair" default | "create"). An unknown mode is
  # a validation error so a typo fails loudly at load time.
  defp fetch_mode(data) do
    case Map.get(data, "mode") do
      nil ->
        {:ok, :repair}

      mode when is_binary(mode) ->
        case Map.fetch(@goal_modes, mode) do
          {:ok, atom} ->
            {:ok, atom}

          :error ->
            {:error, "goal \"mode\" must be one of #{known_modes()} (got #{inspect(mode)})"}
        end

      _ ->
        {:error, "goal \"mode\" must be a string"}
    end
  end

  # T3.4d standing wiring: optional top-level `standing` boolean (UC-016).
  # Default false (one-shot converge-and-stop); a non-boolean fails loudly at
  # load time rather than being silently coerced.
  defp fetch_standing(data) do
    case Map.get(data, "standing", false) do
      standing when is_boolean(standing) -> {:ok, standing}
      _ -> {:error, "goal \"standing\" must be a boolean"}
    end
  end

  defp build_budget(budget) when is_map(budget) do
    keys = [:max_iterations, :max_wall_clock_ms, :max_tokens]

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.get(budget, Atom.to_string(key)) do
        nil -> {:cont, {:ok, acc}}
        value when is_integer(value) and value > 0 -> {:cont, {:ok, [{key, value} | acc]}}
        _ -> {:halt, {:error, "budget.#{key} must be a positive integer"}}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, Budget.new(opts)}
      {:error, _} = err -> err
    end
  end

  defp build_budget(_), do: {:error, "[budget] must be a table"}

  defp build_scope(scope) when is_map(scope) do
    with {:ok, workspace} <- optional_string(scope, "workspace", "scope"),
         {:ok, repo} <- optional_string(scope, "repo", "scope"),
         {:ok, paths} <- optional_string_list(scope, "paths", "scope") do
      {:ok, Scope.new(workspace: workspace, repo: repo, paths: paths)}
    end
  end

  defp build_scope(_), do: {:error, "[scope] must be a table"}

  # T8.6 harness selection (ADR-0016): the optional `[harness]` table. Absent
  # (nil) → the goal carries no harness preference (`nil`), loading exactly as
  # before. Present → a `%{id:, model:, command:}` map. `id` is required and must
  # name a KNOWN harness (mapped via Registry.ids/0, never String.to_atom/1, so a
  # typo fails loudly at load time instead of leaking an atom). `model`/`command`
  # are optional strings. Modeled on the `[scope]` handling above.
  defp build_harness(nil), do: {:ok, nil}

  defp build_harness(harness) when is_map(harness) do
    with {:ok, id} <- fetch_harness_id(harness),
         {:ok, model} <- optional_string(harness, "model", "harness"),
         {:ok, command} <- optional_string(harness, "command", "harness") do
      {:ok, %{id: id, model: model, command: command}}
    end
  end

  defp build_harness(_), do: {:error, "[harness] must be a table"}

  defp fetch_harness_id(harness) do
    case Map.get(harness, "id") do
      nil ->
        {:error, "[harness] is missing required key \"id\""}

      id when is_binary(id) ->
        case Enum.find(Registry.ids(), &(Atom.to_string(&1) == id)) do
          nil ->
            {:error,
             "harness.id has unknown harness #{inspect(id)} (known: #{known_harnesses()})"}

          known ->
            {:ok, known}
        end

      _ ->
        {:error, "harness.id must be a string"}
    end
  end

  # T12.1 group taxonomy (ADR-0020): the optional `[[group]]` array. Absent (the
  # default []) → the goal carries no taxonomy (`groups: []`), loading exactly as
  # before. Present → each entry parses into a `Kazi.Goal.Group` with a NORMALIZED
  # id (case / whitespace / `&` collapse, so loosely-authored variants resolve to
  # one canonical slug). A duplicate id (after normalization) is a load error, so
  # the taxonomy is a set. `parent` is parsed and stored only; its reference /
  # cycle validation is T12.2. Modeled on the `[[predicate]]` handling above.
  defp build_groups([]), do: {:ok, []}

  defp build_groups(groups) when is_list(groups) do
    groups
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case build_group(raw, index, acc) do
        {:ok, group} -> {:cont, {:ok, [group | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, _} = err -> err
    end
  end

  defp build_groups(_), do: {:error, "[[group]] must be an array of tables"}

  # `acc` is the groups parsed so far (newest-first); a normalized id already in
  # `acc` is a duplicate and a load error.
  defp build_group(raw, index, acc) when is_map(raw) do
    with {:ok, id} <- fetch_group_id(raw, index),
         :ok <- reject_duplicate_group(id, acc, raw),
         {:ok, name} <- fetch_group_name(raw, id),
         {:ok, parent} <- fetch_group_parent(raw, id),
         {:ok, budget} <- fetch_group_budget(raw, id) do
      {:ok, Group.new(id, name, parent: parent, budget: budget)}
    end
  end

  defp build_group(_raw, index, _acc),
    do: {:error, "[[group]] ##{index} must be a table"}

  # The authored id string (required, non-empty). Group.new/3 normalizes it; the
  # raw string is returned here so error messages and the duplicate check report
  # the canonical id the author's value maps to.
  defp fetch_group_id(raw, index) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" ->
        case Group.normalize_id(id) do
          "" ->
            {:error, "[[group]] ##{index} \"id\" #{inspect(id)} normalizes to an empty id"}

          normalized ->
            {:ok, normalized}
        end

      nil ->
        {:error, "[[group]] ##{index} is missing required key \"id\""}

      _ ->
        {:error, "[[group]] ##{index} \"id\" must be a non-empty string"}
    end
  end

  defp reject_duplicate_group(id, acc, raw) do
    if Enum.any?(acc, &(&1.id == id)) do
      {:error,
       "duplicate group id #{inspect(id)}" <>
         duplicate_group_hint(Map.get(raw, "id"), id)}
    else
      :ok
    end
  end

  # If the authored value differed from the normalized id, name both so the
  # author sees WHY two distinct-looking ids collided (the drift guard's point).
  defp duplicate_group_hint(authored, id) when is_binary(authored) and authored != id,
    do: " (authored #{inspect(authored)} normalizes to #{inspect(id)})"

  defp duplicate_group_hint(_authored, _id), do: ""

  # Display label. Optional: defaults to the authored id string so a group always
  # has a name. A non-string name is a validation error.
  defp fetch_group_name(raw, id) do
    case Map.get(raw, "name") do
      nil -> {:ok, Map.get(raw, "id", id)}
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, "group #{inspect(id)} \"name\" must be a non-empty string"}
    end
  end

  # Optional parent group id (normalized via Group.new/3). Parsed and stored
  # only; T12.2 validates that it references a declared group and is acyclic.
  defp fetch_group_parent(raw, id) do
    case Map.get(raw, "parent") do
      nil -> {:ok, nil}
      parent when is_binary(parent) and parent != "" -> {:ok, parent}
      _ -> {:error, "group #{inspect(id)} \"parent\" must be a non-empty string"}
    end
  end

  # Optional per-group budget cap. Stored verbatim; a non-positive value fails
  # loudly, matching the goal `[budget]` table's rule.
  defp fetch_group_budget(raw, id) do
    case Map.get(raw, "budget") do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "group #{inspect(id)} \"budget\" must be a positive integer"}
    end
  end

  # T12.2 the drift guard (ADR-0020 §Decision 3). Run after the taxonomy AND the
  # predicates are both parsed, so every cross-reference can be checked against
  # the declared id set. Three checks, short-circuiting on the first failure:
  #
  #   1. every predicate `group` references a DECLARED id (the typo guard — a
  #      misspelled group would otherwise silently fragment the tree);
  #   2. every group `parent` references a DECLARED id;
  #   3. the `parent` chain is acyclic.
  #
  # Ids are already normalized at parse time (predicate group and group parent
  # both via Group.normalize_id/1), so set membership is an exact compare.
  defp validate_group_references(groups, predicates) do
    declared = MapSet.new(groups, & &1.id)

    with :ok <- validate_predicate_groups(predicates, declared),
         :ok <- validate_group_parents(groups, declared) do
      validate_no_group_cycle(groups)
    end
  end

  defp validate_predicate_groups(predicates, declared) do
    Enum.reduce_while(predicates, :ok, fn predicate, :ok ->
      case predicate.group do
        nil ->
          {:cont, :ok}

        group ->
          if MapSet.member?(declared, group) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "predicate #{inspect(predicate.id)} references unknown group " <>
                "#{inspect(group)} (declared: #{known_groups(declared)})"}}
          end
      end
    end)
  end

  defp validate_group_parents(groups, declared) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case group.parent do
        nil ->
          {:cont, :ok}

        parent ->
          if MapSet.member?(declared, parent) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              "group #{inspect(group.id)} references unknown parent " <>
                "#{inspect(parent)} (declared: #{known_groups(declared)})"}}
          end
      end
    end)
  end

  # Walk each group's parent chain; a node revisited within one walk is a cycle.
  # `parents` maps a group id to its (already-declared) parent id, so the walk is
  # a simple pointer-chase. Reported with the offending group so the author can
  # find the loop. Parent existence is guaranteed by validate_group_parents/2,
  # which runs first.
  defp validate_no_group_cycle(groups) do
    parents = Map.new(groups, &{&1.id, &1.parent})

    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case walk_parent_chain(group.id, parents, MapSet.new()) do
        :ok -> {:cont, :ok}
        {:cycle, id} -> {:halt, {:error, "group #{inspect(id)} has a cyclic parent chain"}}
      end
    end)
  end

  defp walk_parent_chain(nil, _parents, _seen), do: :ok

  defp walk_parent_chain(id, parents, seen) do
    if MapSet.member?(seen, id) do
      {:cycle, id}
    else
      walk_parent_chain(Map.get(parents, id), parents, MapSet.put(seen, id))
    end
  end

  defp build_predicates([]), do: {:error, "goal-file must declare at least one [[predicate]]"}

  defp build_predicates(predicates) when is_list(predicates) do
    predicates
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case build_predicate(raw, index) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, _} = err -> err
    end
  end

  defp build_predicates(_), do: {:error, "[[predicate]] must be an array of tables"}

  defp build_predicate(raw, index) when is_map(raw) do
    with {:ok, id} <- fetch_predicate_id(raw, index),
         {:ok, kind} <- fetch_provider_kind(raw, id),
         {:ok, guard?} <- fetch_guard(raw, id),
         {:ok, acceptance?} <- fetch_acceptance(raw, id),
         :ok <- reject_guard_acceptance(guard?, acceptance?, id),
         {:ok, group} <- fetch_predicate_group(raw, id) do
      {:ok,
       Predicate.new(id, kind,
         description: Map.get(raw, "description"),
         guard?: guard?,
         acceptance?: acceptance?,
         group: group,
         config: predicate_config(raw)
       )}
    end
  end

  defp build_predicate(_raw, index),
    do: {:error, "[[predicate]] ##{index} must be a table"}

  defp fetch_predicate_id(raw, index) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "[[predicate]] ##{index} is missing required key \"id\""}
      _ -> {:error, "[[predicate]] ##{index} \"id\" must be a non-empty string"}
    end
  end

  defp fetch_provider_kind(raw, id) do
    case Map.get(raw, "provider") do
      nil ->
        {:error, "predicate #{inspect(id)} is missing required key \"provider\""}

      provider when is_binary(provider) ->
        case Map.fetch(@provider_kinds, provider) do
          {:ok, kind} ->
            {:ok, kind}

          :error ->
            {:error,
             "predicate #{inspect(id)} has unknown provider #{inspect(provider)} " <>
               "(known: #{known_providers()})"}
        end

      _ ->
        {:error, "predicate #{inspect(id)} \"provider\" must be a string"}
    end
  end

  defp fetch_guard(raw, id) do
    case Map.get(raw, "guard", false) do
      guard? when is_boolean(guard?) -> {:ok, guard?}
      _ -> {:error, "predicate #{inspect(id)} \"guard\" must be a boolean"}
    end
  end

  # T2.1: optional `acceptance` boolean marking an acceptance criterion.
  defp fetch_acceptance(raw, id) do
    case Map.get(raw, "acceptance", false) do
      acceptance? when is_boolean(acceptance?) -> {:ok, acceptance?}
      _ -> {:error, "predicate #{inspect(id)} \"acceptance\" must be a boolean"}
    end
  end

  # A guard is an invariant that must not regress, not a goal to reach; an
  # acceptance criterion is a goal to reach. They are mutually exclusive.
  defp reject_guard_acceptance(true, true, id),
    do: {:error, "predicate #{inspect(id)} may not be both a guard and an acceptance predicate"}

  defp reject_guard_acceptance(_guard?, _acceptance?, _id), do: :ok

  # T12.2 (ADR-0020 §Decision 2): optional `group` — a declared group id this
  # predicate belongs to. Absent → nil (ungrouped, unchanged). Present → the
  # value is NORMALIZED the same way group ids are (Group.normalize_id/1) so a
  # loosely-authored reference resolves to the canonical slug. Whether the
  # normalized id is actually DECLARED is checked once the taxonomy is known
  # (validate_group_references/2); here we only parse and normalize the field.
  defp fetch_predicate_group(raw, id) do
    case Map.get(raw, "group") do
      nil -> {:ok, nil}
      group when is_binary(group) and group != "" -> {:ok, Group.normalize_id(group)}
      _ -> {:error, "predicate #{inspect(id)} \"group\" must be a non-empty string"}
    end
  end

  # Every non-reserved key on the predicate table becomes config, atom-keyed,
  # handed verbatim to the provider.
  defp predicate_config(raw) do
    raw
    |> Map.drop(@predicate_reserved_keys)
    |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp optional_string(map, key, table) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{table}.#{key} must be a string"}
    end
  end

  defp optional_string_list(map, key, table) do
    case Map.get(map, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "#{table}.#{key} must be an array of strings"}
        end

      _ ->
        {:error, "#{table}.#{key} must be an array of strings"}
    end
  end

  defp known_providers do
    @provider_kinds |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end

  # The declared group ids, sorted, for an unknown-reference error message. Empty
  # when no `[[group]]` was declared (so a stray `group =` on a predicate names
  # exactly that).
  defp known_groups(declared) do
    case Enum.sort(declared) do
      [] -> "none"
      ids -> Enum.map_join(ids, ", ", &inspect/1)
    end
  end

  defp known_modes do
    @goal_modes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end

  defp known_harnesses do
    Registry.ids()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.map_join(", ", &inspect/1)
  end
end
