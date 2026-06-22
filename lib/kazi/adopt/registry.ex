defmodule Kazi.Adopt.Registry do
  @moduledoc """
  Adapts a machine-readable **capability registry** (a JSON file) into a kazi
  goal *set* — one goal per capability (T7.1/T7.2, ADR-0015). This is the second
  deterministic `init` source alongside stack detection (`Kazi.Adopt.detect/1`):
  a registry is a structured, code-verified catalog of "what the product does",
  and turning it into goals lets the convergence loop COMPUTE each capability's
  status per goal instead of it being hand-stamped in prose.

  ## The registry contract (ADR-0015 §4)

  A minimal, product-agnostic JSON shape:

      {
        "version": 1,
        "capabilities": [
          {
            "id": "auth.password-reset",
            "name": "User can reset their password",
            "test": {"cmd": "go", "args": ["test", "./auth/...", "-run", "TestPasswordReset"]},
            "scope": "auth"
          }
        ]
      }

    * Required per capability: `id` (non-empty string) and `name` (string).
    * `test` (optional): a declared `{cmd, args}` binding -> a `test_runner`
      acceptance predicate. `tests` (optional array) carries several bindings.
    * `scope` (optional string): organises output into `--out/<scope>/`
      subdirectories; it never merges capabilities into one goal.
    * Unknown keys are ignored.

  ## Hard boundaries (ADR-0015 §3)

    * **Prose is not an input.** A `.md` path (`capabilities.md` / `usecases.md`)
      is a GENERATED VIEW of the JSON, not a registry input; `parse/2` rejects it
      with a clear error BEFORE reading. JSON is truth, `.md` is generated.
    * **No invented commands.** A capability with NO test binding is a *gap*: its
      acceptance predicate is scaffolded as a commented TODO (via the writer),
      never guessed. Source-code inference to fill gaps stays behind `--enrich`
      (off by default, ADR-0013 §4); it never overrides a declared binding.
    * **Live predicates are scaffolded**, never guessed — each goal carries the
      writer's commented `http_probe` scaffold.

  ## Hermeticity

  `parse/2` reads the registry through the SAME injectable `:file_reader` seam as
  `Kazi.Adopt.detect/1` — a bare `File`-contract module (`read/1`) or a
  `{module, state}` tuple (`read/2`) — and decodes with `Jason.decode/1`. Pure,
  deterministic, hermetic: no shelling out, no network. `to_goal_set/2` is a pure
  mapping over the parsed capabilities, deterministic by capability id.
  """

  alias Kazi.Adopt.Writer

  @typedoc """
  A normalized capability: its required `:id`/`:name`, the declared test
  `:bindings` (a list of `%{cmd: ..., args: [...]}`, possibly empty -> a gap),
  and an optional `:scope` string. Unknown registry keys are dropped here.
  """
  @type capability :: %{
          id: String.t(),
          name: String.t(),
          bindings: [%{cmd: String.t(), args: [String.t()]}],
          scope: String.t() | nil
        }

  @typedoc """
  A planned goal-file: the capability `:id`, its optional `:scope` (for output
  placement), and the `:goal_map` (the `Kazi.Goal.Loader.from_map/1` shape) the
  writer renders. Every `:goal_map` round-trips through the loader.
  """
  @type goal_plan :: %{id: String.t(), scope: String.t() | nil, goal_map: map()}

  # Predicate id suffixes kept stable so re-running init yields byte-identical
  # goal-files (deterministic, ADR-0015).
  @acceptance_id "acceptance"

  @doc """
  Parses the JSON capability registry at `path` into a normalized capability list.

  Returns `{:ok, [capability]}` (sorted by id, deterministic) or `{:error,
  reason}` with a human-readable reason for a prose path, a missing/unreadable
  file, malformed JSON, an empty catalog, or a capability missing a required
  field. Reads through the injectable `:file_reader` seam (default `File`).

  ## Options

    * `:file_reader` — the filesystem seam, as in `Kazi.Adopt.detect/2`: a bare
      module exposing `read/1` (the `File` contract — the default), or a
      `{module, state}` tuple whose module exposes `read/2`.

  ## Examples

      {:ok, [cap | _]} = Kazi.Adopt.Registry.parse("capabilities.json")
      cap.id   #=> "auth.password-reset"

  A prose path is rejected before any read:

      {:error, reason} = Kazi.Adopt.Registry.parse("capabilities.md")
      reason =~ "generated view"  #=> true
  """
  @spec parse(Path.t(), keyword()) :: {:ok, [capability()]} | {:error, String.t()}
  def parse(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with :ok <- reject_prose(path),
         {:ok, contents} <- read_registry(path, opts),
         {:ok, decoded} <- decode_json(path, contents),
         {:ok, raw_caps} <- fetch_capabilities(decoded),
         {:ok, caps} <- normalize_capabilities(raw_caps) do
      {:ok, Enum.sort_by(caps, & &1.id)}
    end
  end

  @doc """
  Maps parsed `capabilities` into a goal *set* — one `goal_plan` per capability
  (T7.2, ADR-0015 §2).

  Each capability becomes a `%{id, scope, goal_map}` where `goal_map` is the
  `Kazi.Goal.Loader.from_map/1` shape:

    * an `id`/`name` from the capability,
    * an ACCEPTANCE `test_runner` predicate per declared binding (`cmd`/`args`
      spread as sibling keys, like `Kazi.Adopt.detect/1`'s predicate map). A
      capability with NO binding is a *gap* — it carries NO real acceptance
      predicate (the writer's commented TODO scaffold marks it for a human or
      `--enrich`), never an invented command. A gap goal carries a single
      harmless `test_runner` placeholder predicate marked as a guard so the goal
      still loads while making the gap explicit.

  Every `goal_map` round-trips through `Kazi.Goal.Loader.from_map/1`. The result
  is ordered by capability id (deterministic). The writer
  (`Kazi.Adopt.Writer.to_toml/1`) renders each `goal_map`, appending the
  commented live-predicate scaffold.

  ## Options

    * `:enrich` — opt into harness gap-filling (default `false`). Off ⇒ gaps stay
      scaffolded TODOs (deterministic). When on, GAP capabilities are passed to
      `Kazi.Adopt.enrich/3` to propose acceptance bindings; a declared binding is
      never overridden.
    * `:harness` / `:adapter_opts` — forwarded to `Kazi.Adopt.enrich/3` when
      enriching (the injectable seam; tests pass a stub).
    * `:workspace` — the repo path enrichment inspects (default `"."`).
  """
  @spec to_goal_set([capability()], keyword()) :: [goal_plan()]
  def to_goal_set(capabilities, opts \\ []) when is_list(capabilities) and is_list(opts) do
    capabilities
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&goal_plan(&1, opts))
  end

  # ---------------------------------------------------------------------------
  # parse helpers
  # ---------------------------------------------------------------------------

  # Prose registries are GENERATED VIEWS, not inputs. Reject a `.md` path
  # (case-insensitive) before reading anything — JSON is truth (ADR-0015 §3).
  defp reject_prose(path) do
    if String.ends_with?(String.downcase(path), ".md") do
      {:error,
       "#{path} looks like a prose view (capabilities.md / usecases.md). Prose files are " <>
         "GENERATED VIEWS of the registry, not init inputs — point `init` at the JSON " <>
         "registry instead (e.g. capabilities.json)."}
    else
      :ok
    end
  end

  # Read the registry file through the injectable seam. Unlike detect/1 the path
  # IS the file (no marker join), so we dispatch read/1 (bare module) or read/2
  # ({module, state} tuple) on the path directly.
  defp read_registry(path, opts) do
    reader = Keyword.get(opts, :file_reader, File)

    case read(reader, path) do
      {:ok, contents} when is_binary(contents) ->
        {:ok, contents}

      {:error, reason} ->
        {:error, "cannot read registry #{path}: #{format_read_error(reason)}"}
    end
  end

  defp read({mod, state}, path), do: mod.read(state, path)
  defp read(mod, path), do: mod.read(path)

  defp format_read_error(reason) when is_atom(reason), do: :file.format_error(reason)
  defp format_read_error(reason), do: inspect(reason)

  defp decode_json(path, contents) do
    case Jason.decode(contents) do
      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, _other} ->
        {:error, "registry #{path} must be a JSON object with a \"capabilities\" array"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "malformed JSON in registry #{path}: #{Exception.message(error)}"}
    end
  end

  defp fetch_capabilities(%{"capabilities" => list}) when is_list(list) and list != [],
    do: {:ok, list}

  defp fetch_capabilities(%{"capabilities" => []}),
    do: {:error, "registry has an empty \"capabilities\" array — nothing to adopt"}

  defp fetch_capabilities(%{"capabilities" => _other}),
    do: {:error, "registry \"capabilities\" must be a JSON array"}

  defp fetch_capabilities(_decoded),
    do: {:error, "registry is missing the required \"capabilities\" array"}

  # Normalize each raw capability into the typed map; the first malformed one
  # halts with a clear, indexed error (deterministic — input order).
  defp normalize_capabilities(raw_caps) do
    raw_caps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case normalize_capability(raw, index) do
        {:ok, capability} -> {:cont, {:ok, [capability | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      {:error, _} = err -> err
    end
  end

  defp normalize_capability(%{} = raw, index) do
    with {:ok, id} <- fetch_capability_id(raw, index),
         {:ok, name} <- fetch_capability_name(raw, id),
         {:ok, bindings} <- collect_bindings(raw, id),
         {:ok, scope} <- fetch_capability_scope(raw, id) do
      {:ok, %{id: id, name: name, bindings: bindings, scope: scope}}
    end
  end

  defp normalize_capability(_raw, index),
    do: {:error, "capability ##{index} must be a JSON object"}

  defp fetch_capability_id(raw, index) do
    case Map.get(raw, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "capability ##{index} is missing required field \"id\""}
      _ -> {:error, "capability ##{index} \"id\" must be a non-empty string"}
    end
  end

  defp fetch_capability_name(raw, id) do
    case Map.get(raw, "name") do
      name when is_binary(name) -> {:ok, name}
      nil -> {:error, "capability #{inspect(id)} is missing required field \"name\""}
      _ -> {:error, "capability #{inspect(id)} \"name\" must be a string"}
    end
  end

  defp fetch_capability_scope(raw, id) do
    case Map.get(raw, "scope") do
      nil -> {:ok, nil}
      scope when is_binary(scope) and scope != "" -> {:ok, scope}
      "" -> {:ok, nil}
      _ -> {:error, "capability #{inspect(id)} \"scope\" must be a string"}
    end
  end

  # Collect the declared test bindings from `test` (single) and/or `tests`
  # (array). A capability with none is a gap (an empty binding list). Each
  # binding requires a non-empty string `cmd`; `args` defaults to [].
  defp collect_bindings(raw, id) do
    singles = raw |> Map.get("test") |> List.wrap()
    many = raw |> Map.get("tests") |> as_list()

    (singles ++ many)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {binding, index}, {:ok, acc} ->
      case normalize_binding(binding, id, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      {:error, _} = err -> err
    end
  end

  defp as_list(list) when is_list(list), do: list
  defp as_list(_other), do: []

  defp normalize_binding(%{"cmd" => cmd} = binding, _id, _index)
       when is_binary(cmd) and cmd != "" do
    {:ok, %{cmd: cmd, args: binding_args(Map.get(binding, "args"))}}
  end

  defp normalize_binding(%{} = _binding, id, index),
    do:
      {:error, "capability #{inspect(id)} test binding ##{index} is missing a non-empty \"cmd\""}

  defp normalize_binding(_binding, id, index),
    do: {:error, "capability #{inspect(id)} test binding ##{index} must be a JSON object"}

  defp binding_args(args) when is_list(args) do
    Enum.map(args, &to_string/1)
  end

  defp binding_args(_args), do: []

  # ---------------------------------------------------------------------------
  # goal-set mapping
  # ---------------------------------------------------------------------------

  defp goal_plan(%{id: id, name: name, scope: scope} = capability, opts) do
    predicates = acceptance_predicates(capability, opts)

    goal_map = %{
      "id" => id,
      "name" => name,
      "predicate" => predicates
    }

    %{id: id, scope: scope, goal_map: goal_map}
  end

  # Acceptance predicates from the declared bindings. With multiple bindings each
  # gets a stable, indexed id. A capability with NO binding is a gap: we never
  # invent a command. With enrichment off, a gap goal carries a single
  # gap-marker guard predicate (test_runner, guard=true) so the goal still loads
  # while the writer's commented TODO scaffold marks the missing acceptance for a
  # human. With enrichment on, the harness may propose live acceptance bindings.
  defp acceptance_predicates(%{bindings: [_ | _] = bindings}, _opts) do
    bindings
    |> Enum.with_index(1)
    |> Enum.map(fn {binding, index} ->
      binding_predicate(binding, predicate_id(bindings, index))
    end)
  end

  defp acceptance_predicates(%{bindings: []} = capability, opts) do
    case enriched_predicates(capability, opts) do
      [] -> [gap_predicate(capability)]
      proposed -> proposed
    end
  end

  # A single binding -> "acceptance"; multiple -> "acceptance-1", "acceptance-2".
  defp predicate_id([_single], _index), do: @acceptance_id
  defp predicate_id(_many, index), do: "#{@acceptance_id}-#{index}"

  defp binding_predicate(%{cmd: cmd, args: args}, predicate_id) do
    %{
      "id" => predicate_id,
      "provider" => "test_runner",
      "description" => "capability's declared test binding passes",
      "acceptance" => true,
      "cmd" => cmd,
      "args" => args
    }
  end

  # A gap-marker predicate for a capability the catalog left unbound. It is a
  # GUARD (not an invented acceptance command) that runs a no-op `true`, so the
  # goal loads and is explicit about the gap; the writer's commented TODO
  # scaffold (and `--enrich`) is how the real binding gets filled. We never emit
  # a command that pretends to test the capability.
  defp gap_predicate(%{id: id}) do
    %{
      "id" => "acceptance-gap",
      "provider" => "test_runner",
      "description" =>
        "GAP: capability #{inspect(id)} has no declared test binding — fill in an " <>
          "acceptance predicate (or run init --enrich) before relying on this goal",
      "guard" => true,
      "cmd" => "true",
      "args" => []
    }
  end

  # Harness gap-filling (opt-in). Off by default ⇒ []. On ⇒ drive Kazi.Adopt.enrich/3
  # for the workspace; we accept any loadable-shaped predicate it proposes as the
  # gap's acceptance binding(s). A declared binding is never reached here (only
  # gaps call this), so enrichment can only ever FILL a gap, never override.
  defp enriched_predicates(_capability, opts) do
    if Keyword.get(opts, :enrich, false) do
      workspace = Keyword.get(opts, :workspace, ".")
      detection = %{stack: :unknown, predicate: %{}}

      enrich_opts =
        opts
        |> Keyword.take([:harness, :adapter_opts])
        |> Keyword.put(:enrich, true)

      Kazi.Adopt.enrich(workspace, detection, enrich_opts)
      |> Enum.map(&Map.put(&1, "acceptance", true))
    else
      []
    end
  end

  @doc """
  Renders a `goal_plan` to a TOML goal-file string via the writer
  (`Kazi.Adopt.Writer.to_toml/1`), including the commented live-predicate
  scaffold. Convenience for the CLI / tests so the rendering path is shared.
  """
  @spec render(goal_plan()) :: String.t()
  def render(%{goal_map: goal_map}), do: Writer.to_toml(goal_map)
end
