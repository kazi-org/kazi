defmodule Kazi.Adopt.Writer do
  @moduledoc """
  Renders an adopted goal **map** (the `Kazi.Goal.Loader.from_map/1` shape) to a
  TOML *goal-file* STRING (T5.3, ADR-0013): the final, deterministic step of
  `kazi init`. Detection (`Kazi.Adopt.detect/1`) and guards
  (`Kazi.Adopt.guards/1`) produce goal *maps*; this module is the one place those
  maps become the on-disk authoring format the loader reads back.

  ## What it emits

  Given a goal map with a top-level `"id"` (required), optional `"name"`, and a
  `"predicate"` ARRAY (each predicate a string-keyed map carrying `id`,
  `provider`, optional `description`/`guard`/`acceptance`, and any other key as
  config), `to_toml/1` renders:

    * the top-level `id`/`name` (when present),
    * an optional `[scope]` table when the map carries `"scope"`,
    * an optional `[harness]` table when the map carries `"harness"` (T8.6,
      ADR-0016) — only the recognized keys (`id`, `model`, `command`), in that
      stable order; a nil/empty harness emits nothing,
    * one `[[predicate]]` block per predicate, reserved keys first in a stable
      order, then config keys sorted by name, and
    * a COMMENTED live-predicate scaffold — a `# [[predicate]]` `http_probe`
      block with `TODO` placeholders (url, expect_status, expect_body) for a
      human to fill in. It is a comment, so it does not parse: that is the
      intended product output, not a stub (ADR-0013 §3 — live predicates are
      scaffolded, never guessed).
    * an optional COMMENTED `[budget]` suggestion (T48.9, ADR-0058 decision
      2) when `to_toml/2`'s second argument is a
      `Kazi.Economy.BudgetSuggestion.t()` — learned ceilings with an explicit
      provenance line, uncommented by a human to opt in. `nil` (the `to_toml/1`
      default, and the honest outcome when local run history has nothing to
      learn from) renders nothing extra.

  ## Invariants

    * **Deterministic.** The same input map renders to a byte-identical string.
      Predicates keep their input order; keys within a predicate follow a fixed
      reserved-key order then alphabetical config keys.
    * **Round-trips.** Decoding the emitted TOML (the uncommented part) through
      `Kazi.Goal.Loader.from_map/1` loads cleanly — the writer only emits the
      goal-file subset the loader accepts, and strings are TOML-escaped.

  The writer hand-renders TOML (there is no TOML *encoder* dependency, only
  `Toml.decode`). It is intentionally small: it covers exactly the goal-file
  subset `init` emits (strings, integers, booleans, and arrays of strings).
  """

  # Reserved predicate keys emitted (in this order) before config keys, so a
  # rendered predicate is stable and reads top-down: identity, then provider,
  # then human description, then the guard/acceptance markers.
  @reserved_order ~w(id provider description guard acceptance)

  # Budget keys rendered (in this order) inside the T48.9 suggestion comment,
  # when present -- mirrors the `[budget]` table's own key order (T48.6).
  @suggested_budget_order ~w(max_tokens max_dispatches max_wall_clock_ms)a

  @doc """
  Renders the goal `map` to a TOML goal-file string, with an optional T48.9
  learned-`[budget]`-suggestion comment block (ADR-0058 decision 2).

  `map` is string-keyed in the `Kazi.Goal.Loader.from_map/1` shape: a required
  `"id"`, an optional `"name"`, an optional `"scope"` table, and a `"predicate"`
  array of predicate maps. `suggested_budget` (default `nil`) is a
  `Kazi.Economy.BudgetSuggestion.t()` -- when present it is rendered as a
  COMMENTED `[budget]` block (never a live one; kazi never silently applies a
  learned budget) with an explicit provenance line, ahead of the live-predicate
  scaffold. `nil` renders nothing extra, so `to_toml/1` (no suggestion) is
  byte-identical to `to_toml/2` called with `nil` -- the honest behavior when
  local run history has nothing to learn from for this goal's shape.

  Pure, total, and deterministic — the same inputs always render byte-identically.
  """
  @spec to_toml(map(), Kazi.Economy.BudgetSuggestion.t() | nil) :: String.t()
  def to_toml(map, suggested_budget \\ nil)

  def to_toml(%{} = map, suggested_budget) do
    [
      render_header(map),
      render_scope(Map.get(map, "scope")),
      render_harness(Map.get(map, "harness")),
      render_predicates(Map.get(map, "predicate", [])),
      render_suggested_budget(suggested_budget),
      live_predicate_scaffold()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  @doc """
  Renders an ALREADY-AUTHORED goal map to a faithful, loadable goal-file string
  (T39.3, ADR-0049): the `approve <ref> --write <path>` path materializes an
  approved proposal's goal to disk so a file-based / version-controlled workflow
  can `apply <path>` and get the SAME goal `apply <ref>` runs.

  Unlike `to_toml/2` (the `init`/adopt starter), this renders the FULL
  `Kazi.Authoring.serialize_goal/1` map — `mode`, `standing`, `[metadata]`, and
  `[[group]]` blocks in addition to header/scope/harness/predicates — and emits
  NO live-predicate scaffold and NO budget suggestion: an approved goal is
  complete, not a starter, so a "TODO: fill in a live probe" comment would be
  misleading. Because the loader round-trips through the same `from_map/1`,
  `from_map(Toml.decode!(to_goal_file(m)))` equals `from_map(m)`.

  Deterministic and total, like `to_toml/2`.
  """
  @spec to_goal_file(map()) :: String.t()
  def to_goal_file(%{} = map) do
    [
      render_header(map),
      render_mode(Map.get(map, "mode")),
      render_standing(Map.get(map, "standing")),
      render_scope(Map.get(map, "scope")),
      render_harness(Map.get(map, "harness")),
      render_metadata(Map.get(map, "metadata")),
      render_groups(Map.get(map, "group", [])),
      render_predicates(Map.get(map, "predicate", []))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  # `mode` is emitted only when non-default: the loader defaults an absent mode
  # to "repair", so omitting it round-trips a repair goal byte-stably while a
  # "create" goal carries its declaration.
  defp render_mode(mode) when mode in [nil, "", "repair"], do: ""
  defp render_mode(mode), do: kv("mode", to_string(mode))

  # `standing` is emitted only when true (the loader defaults absent → false).
  defp render_standing(true), do: kv("standing", true)
  defp render_standing(_), do: ""

  # An optional `[metadata]` table (string-keyed, verbatim per the loader). The
  # authoring path's metadata is a flat map of scalars (source/proposed/
  # rationale); keys are sorted for determinism. Empty/absent emits nothing.
  defp render_metadata(metadata) when is_map(metadata) and map_size(metadata) > 0 do
    lines =
      metadata
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> kv(to_string(key), value) end)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> ""
      kvs -> "[metadata]\n" <> Enum.join(kvs, "\n")
    end
  end

  defp render_metadata(_other), do: ""

  # The `[[group]]` taxonomy (T12.1/ADR-0020), one block per group in input
  # order. Only the loader-recognised keys are emitted (id, name, parent,
  # budget); `serialize_goal/1` drops nil parent/budget so a re-load is stable.
  defp render_groups(groups) when is_list(groups) and groups != [] do
    groups
    |> Enum.map(&render_group/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_groups(_other), do: ""

  defp render_group(%{} = group) do
    lines =
      [
        optional_kv("id", Map.get(group, "id")),
        optional_kv("name", Map.get(group, "name")),
        optional_kv("parent", Map.get(group, "parent")),
        optional_kv("budget", Map.get(group, "budget"))
      ]
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> ""
      kvs -> "[[group]]\n" <> Enum.join(kvs, "\n")
    end
  end

  defp render_group(_other), do: ""

  @doc """
  The commented live-predicate scaffold appended to every generated goal-file: a
  `# [[predicate]]` `http_probe` block with `TODO` placeholders for a human to
  fill in (URL, expected status, expected body). It is a COMMENT, so it does not
  parse — the intended product output (ADR-0013 §3): live predicates are
  scaffolded, never guessed.

  Exposed so tests can reference the exact scaffold.
  """
  @spec live_predicate_scaffold() :: String.t()
  def live_predicate_scaffold do
    """
    # TODO: scaffold a LIVE predicate so convergence is proven against the real,
    # deployed service — not just green tests. Uncomment, fill the placeholders,
    # and (for a browser flow) switch provider to "browser".
    # [[predicate]]
    # id = "live-probe"
    # provider = "http_probe"
    # description = "TODO: what must be true of the deployed service"
    # url = "TODO: https://your-service.example.com/healthz"
    # expect_status = 200
    # expect_body = "TODO: expected response body (or remove this line)"
    """
    |> String.trim_trailing("\n")
  end

  # The top-level `id` (always) and `name` (when present). `id` is required by
  # the loader; a missing/blank id would fail to load, so we always emit it from
  # the map (the caller guarantees it).
  defp render_header(map) do
    [
      kv("id", Map.get(map, "id")),
      optional_kv("name", Map.get(map, "name"))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # An optional `[scope]` table. Only the loader-recognised string/string-list
  # keys are emitted (workspace, repo, paths); anything else is ignored so the
  # output round-trips. A nil/empty scope emits nothing.
  defp render_scope(nil), do: ""
  defp render_scope(scope) when map_size(scope) == 0, do: ""

  defp render_scope(%{} = scope) do
    lines =
      [
        optional_kv("workspace", Map.get(scope, "workspace")),
        optional_kv("repo", Map.get(scope, "repo")),
        optional_kv("paths", Map.get(scope, "paths"))
      ]
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> ""
      kvs -> "[scope]\n" <> Enum.join(kvs, "\n")
    end
  end

  defp render_scope(_other), do: ""

  # An optional `[harness]` table (T8.6, ADR-0016). Only the loader-recognised
  # keys are emitted, in a deterministic order (id, model, command); anything
  # else is ignored so the output round-trips. A nil/empty harness emits nothing.
  # The harness `id` may be an atom (from a loaded Goal) or a string; either
  # renders to the same TOML string the loader maps back to a known id.
  defp render_harness(nil), do: ""
  defp render_harness(harness) when map_size(harness) == 0, do: ""

  defp render_harness(%{} = harness) do
    lines =
      [
        optional_kv("id", Map.get(harness, "id")),
        optional_kv("model", Map.get(harness, "model")),
        optional_kv("command", Map.get(harness, "command"))
      ]
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] -> ""
      kvs -> "[harness]\n" <> Enum.join(kvs, "\n")
    end
  end

  defp render_harness(_other), do: ""

  # The T48.9 learned-`[budget]`-suggestion comment block (ADR-0058 decision 2):
  # a COMMENTED `[budget]` table (so it never parses -- a human uncomments it to
  # opt in) preceded by the required provenance line. `nil` (no usable local
  # history) renders nothing, keeping `to_toml/1` byte-identical to `to_toml/2`
  # called with `nil`.
  defp render_suggested_budget(nil), do: ""

  defp render_suggested_budget(%{provenance: provenance} = suggestion) do
    lines =
      @suggested_budget_order
      |> Enum.map(&commented_kv(&1, Map.get(suggestion, &1)))
      |> Enum.reject(&(&1 == ""))

    [
      "# suggested by kazi economy: #{provenance}",
      "# kazi NEVER applies a learned budget silently -- uncomment to opt in.",
      "# [budget]" | lines
    ]
    |> Enum.join("\n")
  end

  # A commented key/value line for the suggested-budget block; `nil` (that
  # metric had no reported history) emits nothing (honest-unknown, ADR-0046).
  defp commented_kv(_key, nil), do: ""
  defp commented_kv(key, value), do: "# #{key} = #{render_value(value)}"

  # Render each predicate as its own `[[predicate]]` block, in input order
  # (deterministic). A non-list or empty predicate list renders nothing here —
  # the loader rejects an empty goal, which is the caller's concern, not the
  # writer's (the writer is total over any map).
  defp render_predicates(predicates) when is_list(predicates) do
    predicates
    |> Enum.map(&render_predicate/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_predicates(_other), do: ""

  defp render_predicate(%{} = predicate) do
    reserved =
      @reserved_order
      |> Enum.map(fn key -> optional_kv(key, Map.get(predicate, key)) end)
      |> Enum.reject(&(&1 == ""))

    config =
      predicate
      |> Map.drop(@reserved_order)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> kv(to_string(key), value) end)
      |> Enum.reject(&(&1 == ""))

    case reserved ++ config do
      [] -> ""
      lines -> "[[predicate]]\n" <> Enum.join(lines, "\n")
    end
  end

  defp render_predicate(_other), do: ""

  # A required key/value line. A nil value renders an empty string (the caller
  # filters it); a non-nil value is TOML-rendered.
  defp kv(_key, nil), do: ""
  defp kv(key, value), do: "#{key} = #{render_value(value)}"

  # An optional key: nil renders nothing.
  defp optional_kv(_key, nil), do: ""
  defp optional_kv(key, value), do: kv(key, value)

  # TOML value rendering for the goal-file subset init emits: strings (escaped),
  # booleans, integers, and arrays of strings. Anything else is rendered as an
  # escaped string of its `to_string/1` so the output is always valid TOML.
  defp render_value(value) when is_binary(value), do: escape_string(value)
  defp render_value(value) when is_boolean(value), do: to_string(value)
  defp render_value(value) when is_integer(value), do: Integer.to_string(value)

  defp render_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &render_value/1) <> "]"
  end

  defp render_value(value), do: escape_string(to_string(value))

  # TOML basic-string escaping: wrap in double quotes and escape backslash,
  # double-quote, and the control characters TOML requires escaped, so any string
  # round-trips through `Toml.decode`.
  defp escape_string(string) do
    escaped =
      string
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\t", "\\t")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    "\"" <> escaped <> "\""
  end

  defp ensure_trailing_newline(string) do
    if String.ends_with?(string, "\n"), do: string, else: string <> "\n"
  end
end
