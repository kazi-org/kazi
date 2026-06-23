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
    * one `[[predicate]]` block per predicate, reserved keys first in a stable
      order, then config keys sorted by name, and
    * a COMMENTED live-predicate scaffold — a `# [[predicate]]` `http_probe`
      block with `TODO` placeholders (url, expect_status, expect_body) for a
      human to fill in. It is a comment, so it does not parse: that is the
      intended product output, not a stub (ADR-0013 §3 — live predicates are
      scaffolded, never guessed).

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

  @doc """
  Renders the goal `map` to a TOML goal-file string.

  `map` is string-keyed in the `Kazi.Goal.Loader.from_map/1` shape: a required
  `"id"`, an optional `"name"`, an optional `"scope"` table, and a `"predicate"`
  array of predicate maps. The output ends with a commented live-predicate
  scaffold (an `http_probe` with `TODO` placeholders) for a human to complete.

  Pure, total, and deterministic — the same map always renders byte-identically.
  """
  @spec to_toml(map()) :: String.t()
  def to_toml(%{} = map) do
    [
      render_header(map),
      render_scope(Map.get(map, "scope")),
      render_predicates(Map.get(map, "predicate", [])),
      live_predicate_scaffold()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

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
