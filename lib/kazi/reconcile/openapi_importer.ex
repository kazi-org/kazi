defmodule Kazi.Reconcile.OpenApiImporter do
  @moduledoc """
  Imports the *intended set* `I` from an OpenAPI document (ADR-0021, decision 1):
  one `http_probe` **acceptance** predicate per path/operation, GROUPED by the
  operation's first `tag` into the declared `[[group]]` taxonomy (ADR-0020). The
  output is a goal-file **map** in exactly the shape `Kazi.Goal.Loader.from_map/1`
  accepts, so the import round-trips through the same validated loader the CLI
  uses — no bespoke deserialiser.

  This is the deterministic, hermetic backbone of the general importer: a spec is
  pure data, so the same document always yields the same goal (and the same
  goal-file). It is NOT the prose-via-harness path (that is `Kazi.Authoring`,
  ADR-0021 decision 1 / T13.3); a machine spec is trusted directly.

  ## What it produces

  Given an OpenAPI document (a decoded JSON map, or a JSON string), `import_map/2`
  emits a goal map with:

    * a top-level `"id"` (caller-supplied or derived) and optional `"name"`,
    * `"mode" => "create"` — the predicates are acceptance criteria for the
      INTENDED API surface, authored to be driven to `:pass` (T2.1, ADR-0021),
    * a `"group"` array — one `[[group]]` per distinct operation `tag`, the group
      `id` being the NORMALIZED tag (`Kazi.Goal.Group.normalize_id/1`, so
      `"Identity & Access"` and `"identity-access"` collapse to one group and the
      tree cannot fragment on spelling, ADR-0020), the group `name` the verbatim
      tag. An operation with no tag falls into a single default group
      (`"ungrouped"`),
    * a `"predicate"` array — one `http_probe` acceptance predicate per
      path/operation, each carrying `method`, `path`, an `expect_status`, the
      group it belongs to (its `group` config key), and a `url` derived from the
      spec's `servers` (or a caller-supplied `:base_url`) joined with the path.

  ## Config shape per predicate

  Each predicate is the goal-file shape (string keys; the loader's RESERVED keys
  `id`/`provider`/`description`/`acceptance`/`group`, and every other key
  collected verbatim into the provider's `config`). The `http_probe` provider
  (`Kazi.Providers.HttpProbe`) reads `:url`, `:method`, and `:expect_status`:

    * `"method"` — the HTTP method, upper-cased (`"GET"`, `"POST"`, …),
    * `"path"` — the OpenAPI path template (`"/widgets/{id}"`), recorded so the
      predicate is self-describing and the surface-coverage meta-predicate (T13.5)
      can match it against a scanned route,
    * `"expect_status"` — the expected status: the operation's smallest declared
      2xx response code (integer), defaulting to `200` when none is declared,
    * `"url"` — the full URL the live probe requests: the resolved base URL joined
      with the path,
    * `"group"` — the normalized group id this operation belongs to (its first
      `tag`). A RESERVED predicate key (T12.2): the loader lands it on
      `Kazi.Predicate.group` and VALIDATES it references a declared `[[group]]`
      entry (so the importer always declares every group it references).

  ## Determinism, hermeticity & re-import (upsert)

  Pure over its input: no network, no clock, no filesystem. The same spec yields a
  byte-identical goal map — paths and operations are emitted in a STABLE sorted
  order (by path, then by a fixed HTTP-method order), and groups in sorted id
  order. Predicate ids are DERIVED from the method + path (`"get__widgets-id"`),
  so a re-import of the same spec produces the same ids: an upsert, not a
  duplicate. Two operations that would derive the same id (the same method+path,
  which OpenAPI forbids) are de-duplicated, keeping the first.

  ## JSON only (YAML deferred)

  OpenAPI documents are commonly authored in YAML, but kazi does not depend on a
  YAML parser and adding one is an ADR-gated decision (per the project's
  stack-conventions: "do not pull heavy deps without an ADR"). This importer
  therefore accepts **JSON** OpenAPI only — a decoded map or a JSON string parsed
  with `Jason` (already a dependency). YAML support is a deferred follow-up: a
  thin YAML→JSON front-end behind its own dependency ADR, after which this module
  is unchanged (it already takes a decoded map). Until then, convert a YAML spec
  to JSON out-of-band (`yq -o=json`, `swagger-cli`, …) before importing.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group

  # The group an operation with no `tag` falls into. A normalized slug so it never
  # collides with a real tag's normalized id by accident.
  @default_group_id "ungrouped"
  @default_group_name "Ungrouped"

  # The status expected when an operation declares no 2xx response. 200 is the
  # conventional success code; recording it keeps every predicate checkable.
  @default_status 200

  # A fixed HTTP-method order so operations under one path emit deterministically
  # regardless of the document's key order. Methods OpenAPI defines on a Path Item.
  @method_order ~w(get put post delete options head patch trace)

  @default_base_url "http://localhost"
  @default_goal_id "openapi-import"

  @typedoc """
  Options for `import_map/2` and `import_goal/2`:

    * `:id` — the goal id (string). Defaults to `"openapi-import"`.
    * `:name` — the goal display name. Defaults to the spec's `info.title` when
      present, else omitted.
    * `:base_url` — the base URL each predicate's `url` is built on. Defaults to
      the first entry in the spec's `servers` (its `url`), else
      `"http://localhost"`. A trailing slash is trimmed before joining.
  """
  @type opts :: keyword()

  @doc """
  Imports an OpenAPI document into a goal **map** (the `Kazi.Goal.Loader.from_map/1`
  shape).

  `doc` is either an already-decoded OpenAPI map (string-keyed JSON) or a JSON
  STRING (parsed with `Jason`). Returns `{:ok, goal_map}` or `{:error, reason}`
  with a human-readable reason for malformed JSON or a document missing `paths`.

  The returned map round-trips: `Kazi.Goal.Loader.from_map(goal_map)` loads it
  into a `Kazi.Goal` with the grouped acceptance predicates. See the moduledoc for
  options and the per-predicate config shape.

  ## Examples

      iex> doc = %{
      ...>   "info" => %{"title" => "Widgets API"},
      ...>   "paths" => %{
      ...>     "/widgets" => %{
      ...>       "get" => %{"tags" => ["Catalog"], "responses" => %{"200" => %{}}}
      ...>     }
      ...>   }
      ...> }
      iex> {:ok, map} = Kazi.Reconcile.OpenApiImporter.import_map(doc)
      iex> map["mode"]
      "create"
      iex> [predicate] = map["predicate"]
      iex> {predicate["provider"], predicate["method"], predicate["group"]}
      {"http_probe", "GET", "catalog"}
  """
  @spec import_map(map() | String.t(), opts()) :: {:ok, map()} | {:error, String.t()}
  def import_map(doc, opts \\ [])

  def import_map(json, opts) when is_binary(json) and is_list(opts) do
    case Jason.decode(json) do
      {:ok, %{} = doc} -> import_map(doc, opts)
      {:ok, _other} -> {:error, "OpenAPI document must decode to a JSON object"}
      {:error, error} -> {:error, "malformed OpenAPI JSON: #{Exception.message(error)}"}
    end
  end

  def import_map(%{} = doc, opts) when is_list(opts) do
    with {:ok, paths} <- fetch_paths(doc) do
      base_url = base_url(doc, opts)
      operations = operations(paths)

      goal = %{
        "id" => Keyword.get(opts, :id, @default_goal_id),
        "mode" => "create",
        "group" => build_groups(operations),
        "predicate" => build_predicates(operations, base_url)
      }

      {:ok, maybe_put_name(goal, doc, opts)}
    end
  end

  def import_map(_doc, _opts), do: {:error, "OpenAPI document must be a map or JSON string"}

  @doc """
  Imports an OpenAPI document directly into a `Kazi.Goal` (via the loader).

  Convenience over `import_map/2` + `Kazi.Goal.Loader.from_map/1`: returns
  `{:ok, %Kazi.Goal{}}` or `{:error, reason}`. The goal is in `:create` mode with
  the grouped `http_probe` acceptance predicates and the declared group taxonomy.
  """
  @spec import_goal(map() | String.t(), opts()) :: {:ok, Goal.t()} | {:error, String.t()}
  def import_goal(doc, opts \\ []) do
    with {:ok, map} <- import_map(doc, opts) do
      Goal.Loader.from_map(map)
    end
  end

  defp fetch_paths(doc) do
    case Map.get(doc, "paths") do
      %{} = paths -> {:ok, paths}
      nil -> {:error, "OpenAPI document is missing required key \"paths\""}
      _ -> {:error, "OpenAPI \"paths\" must be an object"}
    end
  end

  # Flatten the Paths Object into a stable, sorted list of operations: one entry
  # `{path, method, operation}` per (path, HTTP method) pair, sorted by path then
  # by the fixed @method_order. Non-method keys on a Path Item (parameters,
  # summary, $ref, …) and non-map operations are skipped.
  defp operations(paths) do
    paths
    |> Enum.filter(fn {_path, item} -> is_map(item) end)
    |> Enum.sort_by(fn {path, _item} -> path end)
    |> Enum.flat_map(fn {path, item} ->
      item
      |> Enum.filter(fn {method, op} -> method in @method_order and is_map(op) end)
      |> Enum.sort_by(fn {method, _op} -> method_index(method) end)
      |> Enum.map(fn {method, op} -> {path, method, op} end)
    end)
  end

  defp method_index(method), do: Enum.find_index(@method_order, &(&1 == method))

  # One `[[group]]` per distinct operation tag (its first tag), keyed by the
  # NORMALIZED id so spelling variants collapse to a single group (ADR-0020). The
  # group `name` is the verbatim first-seen tag. Sorted by id for determinism.
  defp build_groups(operations) do
    operations
    |> Enum.map(fn {_path, _method, op} -> group_for(op) end)
    |> Enum.uniq_by(fn {id, _name} -> id end)
    |> Enum.sort_by(fn {id, _name} -> id end)
    |> Enum.map(fn {id, name} -> %{"id" => id, "name" => name} end)
  end

  # One `http_probe` acceptance predicate per operation, in the stable operation
  # order. A derived id (method + normalized path) makes re-import an UPSERT: the
  # same spec yields the same ids, never duplicates. The rare same-method+path
  # collision (which OpenAPI forbids) is de-duplicated, keeping the first.
  defp build_predicates(operations, base_url) do
    operations
    |> Enum.map(fn {path, method, op} -> predicate(path, method, op, base_url) end)
    |> Enum.uniq_by(fn predicate -> predicate["id"] end)
  end

  defp predicate(path, method, op, base_url) do
    {group_id, _name} = group_for(op)

    base = %{
      "id" => predicate_id(method, path),
      "provider" => "http_probe",
      "acceptance" => true,
      "method" => String.upcase(method),
      "path" => path,
      "url" => join_url(base_url, path),
      "expect_status" => expect_status(op),
      "group" => group_id
    }

    maybe_put_description(base, op)
  end

  # The group an operation belongs to: its FIRST tag (ADR-0020 — "map each
  # operation's first tag"), normalized to a canonical slug. No (or empty) tags →
  # the default group. Returns `{normalized_id, display_name}`.
  defp group_for(op) do
    case op |> Map.get("tags", []) |> first_tag() do
      nil -> {@default_group_id, @default_group_name}
      tag -> {Group.normalize_id(tag), tag}
    end
  end

  defp first_tag(tags) when is_list(tags) do
    Enum.find(tags, fn tag -> is_binary(tag) and tag != "" end)
  end

  defp first_tag(_tags), do: nil

  # The smallest declared 2xx response status (integer), else the default. Response
  # codes are string keys in OpenAPI (`"200"`, `"201"`, …); pick the smallest 2xx
  # so the choice is deterministic regardless of map order.
  defp expect_status(op) do
    op
    |> Map.get("responses", %{})
    |> two_xx_codes()
    |> case do
      [] -> @default_status
      codes -> Enum.min(codes)
    end
  end

  defp two_xx_codes(responses) when is_map(responses) do
    responses
    |> Map.keys()
    |> Enum.flat_map(fn code ->
      case Integer.parse(to_string(code)) do
        {n, ""} when n in 200..299 -> [n]
        _ -> []
      end
    end)
  end

  defp two_xx_codes(_responses), do: []

  # A stable predicate id derived from method + path so re-import upserts: lower
  # method, then the path with non-alphanumerics collapsed to hyphens. E.g.
  # `GET /widgets/{id}` → `"get__widgets-id"`. Pure and total.
  defp predicate_id(method, path) do
    slug =
      path
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    "#{method}_#{slug}"
  end

  # Resolve the base URL each predicate's `url` is built on: an explicit
  # `:base_url` opt wins; else the spec's first server `url`; else the default.
  # A trailing slash is trimmed so joining with a leading-slash path is clean.
  defp base_url(doc, opts) do
    (Keyword.get(opts, :base_url) || first_server_url(doc) || @default_base_url)
    |> String.trim_trailing("/")
  end

  defp first_server_url(doc) do
    with [server | _rest] when is_map(server) <- Map.get(doc, "servers", []),
         url when is_binary(url) and url != "" <- Map.get(server, "url") do
      url
    else
      _ -> nil
    end
  end

  # Join a base URL with an OpenAPI path. The path is kept verbatim (template
  # braces and all) — the predicate records the intended surface; substituting
  # path parameters for a live probe is the caller's concern. A path missing its
  # leading slash gets one so the join is well-formed.
  defp join_url(base_url, path), do: base_url <> prefix_slash(path)

  defp prefix_slash("/" <> _rest = path), do: path
  defp prefix_slash(path), do: "/" <> path

  # Carry the operation's `summary` (else `description`) as the predicate's
  # human description when present, so the grouped view reads well.
  defp maybe_put_description(predicate, op) do
    case presence(Map.get(op, "summary")) || presence(Map.get(op, "description")) do
      nil -> predicate
      text -> Map.put(predicate, "description", text)
    end
  end

  # The goal name: an explicit `:name` opt wins; else the spec's `info.title`.
  defp maybe_put_name(goal, doc, opts) do
    case Keyword.get(opts, :name) || info_title(doc) do
      nil -> goal
      name -> Map.put(goal, "name", name)
    end
  end

  defp info_title(doc) do
    with %{} = info <- Map.get(doc, "info", %{}),
         title when is_binary(title) and title != "" <- Map.get(info, "title") do
      title
    else
      _ -> nil
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end
