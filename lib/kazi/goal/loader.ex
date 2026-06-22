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
  | *(any other)* | any       | no       | `Predicate.config` (atom-keyed, verbatim) |

  Every key on a `[[predicate]]` table other than the five reserved keys above is
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

  # provider string -> Predicate.kind atom. Adding a provider kind here is the
  # only change needed to author goals against a new provider (ADR-0002).
  @provider_kinds %{
    "test_runner" => :tests,
    "http_probe" => :http_probe,
    "prod_log" => :prod_log,
    "browser" => :browser
  }

  # Reserved keys on a [[predicate]] table; everything else falls through to
  # the predicate's `config`.
  @predicate_reserved_keys ~w(id provider description guard acceptance)

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
         {:ok, all} <- build_predicates(Map.get(data, "predicate", [])) do
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
         :ok <- reject_guard_acceptance(guard?, acceptance?, id) do
      {:ok,
       Predicate.new(id, kind,
         description: Map.get(raw, "description"),
         guard?: guard?,
         acceptance?: acceptance?,
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

  defp known_modes do
    @goal_modes |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end
end
