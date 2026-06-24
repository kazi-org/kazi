defmodule Kazi.Reconcile.SurfaceScanner do
  @moduledoc """
  Inventories a project's **public surface** for Elixir (ADR-0021, decision 3):
  the exported functions, Mix tasks, and CLI commands a project exposes to the
  outside world. The output is a sorted list of `Kazi.Reconcile.SurfaceElement`s
  (kind + identifier + source location) — the `actual` set `A` that the
  surface-coverage meta-predicate (T13.5) will own against the intended set `I`.

  Elixir is the first (and cleanest) target: kazi's own language. The scanner
  reuses the repo-introspection seam of ADR-0010 — it walks the same workspace
  source tree that `Kazi.Context.RepoMapSource` walks, skipping the same VCS /
  build / dependency directories — rather than introducing a second scanner.

  ## What it sees

    * **Exported functions** — every top-level `def` (never `defp`) inside a
      `defmodule`, emitted as `Module.Name.fun/arity` with the line of the `def`.
      Nested modules compose their names (`Outer.Inner.fun/arity`).
    * **Mix tasks** — a module that `use`s `Mix.Task` becomes `mix <task>`, where
      `<task>` is derived from the conventional `Mix.Tasks.*` module name
      (`Mix.Tasks.Surface.Scan` → `mix surface.scan`).
    * **CLI commands** — reserved. The hook is in place (`:cli_command` kind) but
      command discovery is dispatch-specific and lands with the language pass that
      needs it; this module does not guess at a CLI shape.

  ## Approximate by design

  A static scan cannot see surface reached by **reflection or string dispatch**
  — `apply/3` with a runtime-computed function, a route table keyed by strings, a
  `Module.concat/1` lookup. Those entry points are invisible here and will look
  "dead" to the meta-predicate unless an allow-list covers them (ADR-0021 keeps a
  "warn, don't auto-delete" posture for exactly this reason). See `docs/lore.md`
  (#surface #reconcile) for the full caveat.

  ## Determinism & hermeticity

  Pure over the filesystem: it reads source files, never the network or a clock,
  and sorts its output by `SurfaceElement.sort_key/1`, so the same tree yields a
  byte-identical inventory. A file that does not parse is skipped (its surface is
  simply not reported) rather than crashing the scan.

  ## Options

    * `:source_dirs` — top-level directories to scan (default `["lib"]`).
      `mix.exs` is always included so a project's own Mix tasks defined there are
      not missed.
    * `:max_files` — cap on scanned files (default `2000`) so a pathological tree
      cannot blow up a scan.
  """

  alias Kazi.Reconcile.SurfaceElement

  @default_source_dirs ["lib"]
  @default_max_files 2000
  @ignored_segments ~w(.git _build deps node_modules .elixir_ls cover)

  @doc """
  Scans `workspace` and returns its public-surface inventory, sorted and
  deterministic.

  Returns a list of `Kazi.Reconcile.SurfaceElement`. An unreadable or
  unparseable file contributes nothing rather than raising.

  ## Examples

      iex> {:ok, dir} = {:ok, System.tmp_dir!() |> Path.join("kazi_surface_doc")}
      iex> File.mkdir_p!(Path.join(dir, "lib"))
      iex> File.write!(Path.join(dir, "lib/calc.ex"), "defmodule Calc do\\n  def add(a, b), do: a + b\\n  defp h(x), do: x\\nend\\n")
      iex> [el] = Kazi.Reconcile.SurfaceScanner.scan(dir)
      iex> File.rm_rf!(dir)
      iex> {el.kind, el.identifier}
      {:exported_function, "Calc.add/2"}
  """
  @spec scan(String.t(), keyword()) :: [SurfaceElement.t()]
  def scan(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    source_dirs = Keyword.get(opts, :source_dirs, @default_source_dirs)
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    workspace
    |> source_files(source_dirs)
    |> Enum.sort()
    |> Enum.take(max_files)
    |> Enum.flat_map(&scan_file(workspace, &1))
    |> Enum.uniq()
    |> Enum.sort_by(&SurfaceElement.sort_key/1)
  end

  # Workspace-relative `.ex`/`.exs` paths under the requested source dirs, plus
  # `mix.exs`, skipping VCS/build/dependency dirs (same exclusions as
  # RepoMapSource so the two introspection passes agree on what "source" is).
  defp source_files(workspace, source_dirs) do
    dir_paths =
      Enum.flat_map(source_dirs, fn dir ->
        workspace
        |> Path.join(dir)
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard(match_dot: false)
      end)

    mix_exs = workspace |> Path.join("mix.exs") |> List.wrap() |> Enum.filter(&File.regular?/1)

    (dir_paths ++ mix_exs)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.reject(&ignored?/1)
    |> Enum.uniq()
  end

  defp ignored?(rel) do
    Enum.any?(@ignored_segments, &(&1 in Path.split(rel)))
  end

  defp scan_file(workspace, rel) do
    with {:ok, contents} <- File.read(Path.join(workspace, rel)),
         {:ok, ast} <- Code.string_to_quoted(contents, columns: false) do
      ast
      |> collect(rel, [])
      |> List.flatten()
    else
      _ -> []
    end
  end

  # Walk the AST carrying the enclosing module name parts. We descend explicitly
  # (rather than Macro.prewalk) so a `def` is always attributed to its nearest
  # enclosing `defmodule` and nested modules compose names correctly.

  defp collect({:defmodule, _meta, [mod_alias, [do: body]]}, rel, mod_parts) do
    parts = mod_parts ++ module_parts(mod_alias)
    mod_name = Enum.join(parts, ".")

    task = mix_task_elements(body, mod_name, rel)
    children = collect(body, rel, parts)
    [task, children]
  end

  defp collect({:__block__, _meta, exprs}, rel, mod_parts) do
    Enum.map(exprs, &collect(&1, rel, mod_parts))
  end

  defp collect({:def, meta, [head | _]}, rel, mod_parts) when mod_parts != [] do
    case fun_name_arity(head) do
      {name, arity} ->
        mod_name = Enum.join(mod_parts, ".")
        line = meta[:line]
        [SurfaceElement.new(:exported_function, "#{mod_name}.#{name}/#{arity}", rel, line)]

      :skip ->
        []
    end
  end

  # Anything else (defp, attributes, use, alias, literals) contributes no surface
  # directly; we do not descend further into non-module, non-block forms.
  defp collect(_other, _rel, _mod_parts), do: []

  # A module that `use`s Mix.Task is a Mix task; name it from the Mix.Tasks.*
  # convention. Only the conventional namespace yields a stable `mix <task>` name.
  defp mix_task_elements(body, mod_name, rel) do
    if uses_mix_task?(body) and String.starts_with?(mod_name, "Mix.Tasks.") do
      task = mod_name |> String.replace_prefix("Mix.Tasks.", "") |> mix_task_name()
      [SurfaceElement.new(:mix_task, "mix #{task}", rel, nil)]
    else
      []
    end
  end

  defp uses_mix_task?(body) do
    body
    |> block_exprs()
    |> Enum.any?(fn
      {:use, _meta, [alias_ast | _]} -> module_parts(alias_ast) == [:Mix, :Task]
      _ -> false
    end)
  end

  defp block_exprs({:__block__, _meta, exprs}), do: exprs
  defp block_exprs(expr), do: [expr]

  # "Surface.Scan" -> "surface.scan" (each module segment lowercased & under_scored,
  # joined by dots) — the Mix task invocation convention.
  defp mix_task_name(rest) do
    rest
    |> String.split(".")
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join(".")
  end

  # Alias AST -> list of name parts. `Foo.Bar` is `{:__aliases__, _, [:Foo, :Bar]}`.
  defp module_parts({:__aliases__, _meta, parts}), do: parts
  defp module_parts(atom) when is_atom(atom), do: [atom]
  defp module_parts(_), do: []

  # Extract {name, arity} from a `def` head, unwrapping a `when` guard. Returns
  # `:skip` for forms we cannot resolve to a simple name/arity (e.g. an unquote).
  defp fun_name_arity({:when, _meta, [head | _guards]}), do: fun_name_arity(head)

  defp fun_name_arity({name, _meta, args}) when is_atom(name) do
    {name, args_arity(args)}
  end

  defp fun_name_arity(_), do: :skip

  # `def f` with no parens parses args as `nil` (arity 0); a list is the real arity.
  defp args_arity(args) when is_list(args), do: length(args)
  defp args_arity(_), do: 0
end
