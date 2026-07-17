defmodule Kazi.Authoring.Discover do
  @moduledoc """
  The opt-in `kazi plan --discover` on-ramp (T45.6, UC-059): one best-effort pass
  that folds stack detection, `.feature` use-case discovery, and a public-surface
  codebase scan into a single findings map ATTACHED to the drafted proposal as
  reviewer evidence. It is never a hard dependency — every mechanism is
  individually fail-soft, so a missing marker, an absent `.feature` file, or a
  scan error degrades to a warning and a plain draft, never a crash. Caller-drafts
  bypass discovery entirely (see `Kazi.Authoring.propose/2`).
  """

  alias Kazi.Adopt
  alias Kazi.Reconcile.GherkinImporter
  alias Kazi.Reconcile.SurfaceElement
  alias Kazi.Reconcile.SurfaceScanner

  @surface_cap 50

  @doc """
  Runs the three discovery mechanisms against `workspace` and returns a
  string-keyed findings map: `"stack"`, `"use_cases"`, `"surface"` (capped at
  #{@surface_cap} entries), and one `"warnings"` line per mechanism that could not
  produce findings. Total — never raises, regardless of the workspace state.
  """
  @spec run(String.t(), keyword()) :: map()
  def run(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    {stack, stack_warn} = safe(nil, "stack detection", fn -> detect_stack(workspace, opts) end)
    {use_cases, uc_warn} = safe([], "use-case discovery", fn -> discover_use_cases(workspace) end)
    {surface, surface_warn} = safe([], "codebase scan", fn -> scan_surface(workspace, opts) end)

    %{
      "stack" => stack,
      "use_cases" => use_cases,
      "surface" => surface,
      "warnings" => Enum.reject([stack_warn, uc_warn, surface_warn], &is_nil/1)
    }
  end

  # Each mechanism runs inside this seam so an exception (rescue) or an exit/throw
  # (catch) degrades to the fallback value plus a warning, never escaping `run/2`.
  defp safe(fallback, label, fun) do
    fun.()
  rescue
    e -> {fallback, "#{label}: #{Exception.message(e)}"}
  catch
    kind, reason -> {fallback, "#{label}: #{inspect({kind, reason})}"}
  end

  defp detect_stack(workspace, opts) do
    case Adopt.detect(workspace, opts) do
      {:ok, %{stack: :unknown}} -> {nil, no_stack_warning()}
      {:ok, %{stack: stack}} -> {to_string(stack), nil}
      {:error, :no_stack_detected} -> {nil, no_stack_warning()}
    end
  end

  defp no_stack_warning, do: "stack detection: no recognized stack marker found"

  defp discover_use_cases(workspace) do
    case feature_sources(workspace) do
      [] ->
        {[], "use-case discovery: no .feature files found"}

      sources ->
        case GherkinImporter.import_map(sources) do
          {:ok, goal_map} -> use_cases_from(goal_map)
          {:error, reason} -> {[], "use-case discovery: #{reason}"}
        end
    end
  end

  defp use_cases_from(goal_map) do
    use_cases =
      goal_map
      |> Map.get("predicate", [])
      |> Enum.map(&Map.get(&1, "scenario"))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    case use_cases do
      [] -> {[], "use-case discovery: no .feature files found"}
      names -> {names, nil}
    end
  end

  defp feature_sources(workspace) do
    workspace
    |> Path.join("**/*.feature")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, contents} -> [contents]
        {:error, _} -> []
      end
    end)
  end

  defp scan_surface(workspace, opts) do
    elements = SurfaceScanner.scan(workspace, opts)
    count = length(elements)

    entries =
      elements
      |> Enum.take(@surface_cap)
      |> Enum.map(&surface_entry/1)

    warning =
      if count > @surface_cap do
        "codebase scan: surface capped at #{@surface_cap} of #{count} elements"
      end

    {entries, warning}
  end

  defp surface_entry(%SurfaceElement{kind: kind, identifier: identifier, path: path}) do
    %{"kind" => to_string(kind), "identifier" => identifier, "path" => path}
  end
end
