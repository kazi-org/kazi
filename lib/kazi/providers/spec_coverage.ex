defmodule Kazi.Providers.SpecCoverage do
  @moduledoc """
  The `:spec_coverage` predicate provider: the goal-file-runnable form of the
  manifest-coverage meta-predicate (`Kazi.Reconcile.SpecCoverage`, T41.3,
  ADR-0050/ADR-0054).

  `Kazi.Reconcile.SpecCoverage.check/3` is the pure check — "is every scanned
  surface element referenced by >=1 Scenario across the product's `.feature`
  files?" — but it is a library function with no way to declare it in a goal-file.
  This provider is that wiring: it scans the workspace surface
  (`Kazi.Reconcile.SurfaceScanner`), reads the product's behavior specs, runs the
  check, and maps its verdict onto a `Kazi.PredicateResult`, so a goal can gate on
  documentation coverage the same objective way it gates on tests. It is what makes
  `kazi init --discover` (T41.4) able to write a goal whose sole predicate is this
  check.

  ## What it does

  1. Scans the workspace for public surface elements (exported functions, Mix
     tasks, CLI commands) via `Kazi.Reconcile.SurfaceScanner.scan/2`.
  2. Reads the product's `.feature` behavior specs (the `:features` glob).
  3. Runs `Kazi.Reconcile.SpecCoverage.check_features/3`: an element referenced by
     no Scenario (and not allow-listed) is UNCOVERED — undocumented surface.

  Nothing uncovered is a `:pass`; any uncovered element is a `:fail` whose evidence
  NAMES each undocumented element (never merely counts it), so the reconcile loop
  surfaces "write a Scenario for `GET /secret`" as ordinary failing work. The
  provider never edits anything.

  A repo with NO matching `.feature` files yields every non-allow-listed element as
  uncovered — a real, honest `:fail` ("the whole surface is undocumented"), which
  is exactly the starting state a discovery goal drives down.

  ## Config

    * `:features` — a glob (or list of globs), workspace-relative, selecting the
      product's `.feature` specs. Default `docs/specs/**/*.feature` (the product
      convention, ADR-0054 / T41.2). A glob that matches nothing is not an error —
      it means zero Scenarios, so the whole surface is uncovered.
    * `:allow_list` — patterns (plain strings or `prefix*` wildcards) for
      intentional un-documented surface (internal/debug entry points), passed
      through to `Kazi.Reconcile.SpecCoverage.check/3`. Default `[]`.
    * `:source_dirs` — the source directories the surface scan walks, passed to
      `Kazi.Reconcile.SurfaceScanner.scan/2`. Default the scanner's own default.

  ## Context

  `context[:workspace]` is the repo to scan (surface + `.feature` files resolve
  against it). Defaults to the current directory. A non-existent workspace is an
  `:error` (the scan could not run), never a false `:pass`.

  ## Evidence & score

  On a completed check the evidence carries the resolved `:workspace`, the
  `:feature_files` read, the `:surface_count`, the `:covered_count`/`:allowed_count`,
  the `:uncovered` identifiers (a bounded sample), and the human `:message`. The
  `score` is the uncovered count (`direction: :lower_better`), so the loop reads
  progress as the undocumented surface shrinks.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Reconcile.{SpecCoverage, SurfaceScanner}

  @default_features ["docs/specs/**/*.feature"]
  # Enough uncovered identifiers to orient a fixer, not the whole surface.
  @uncovered_sample_limit 50

  @doc "The default `.feature` glob(s) the provider reads when `:features` is absent."
  @spec default_features() :: [String.t()]
  def default_features, do: @default_features

  @impl true
  def evaluate(%Predicate{kind: :spec_coverage, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    cond do
      not is_binary(workspace) ->
        PredicateResult.error(%{reason: :no_workspace})

      not File.dir?(workspace) ->
        PredicateResult.error(%{reason: :workspace_not_a_directory, workspace: workspace})

      true ->
        run(workspace, config)
    end
  end

  @impl true
  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  defp run(workspace, config) do
    surface = SurfaceScanner.scan(workspace, scan_opts(config))
    feature_files = feature_files(workspace, config)
    feature_texts = Enum.map(feature_files, &File.read!/1)
    allow_list = List.wrap(Map.get(config, :allow_list, []))

    result = SpecCoverage.check_features(surface, feature_texts, allow_list: allow_list)

    evidence = %{
      workspace: workspace,
      feature_files: Enum.map(feature_files, &Path.relative_to(&1, workspace)),
      surface_count: length(surface),
      covered_count: length(result.covered),
      allowed_count: length(result.allowed),
      uncovered_count: length(result.uncovered),
      uncovered:
        result
        |> SpecCoverage.Result.uncovered_identifiers()
        |> Enum.take(@uncovered_sample_limit),
      message: SpecCoverage.Result.failure_message(result)
    }

    case result.status do
      :pass ->
        PredicateResult.pass(evidence)

      :fail ->
        PredicateResult.new(:fail, evidence,
          score: length(result.uncovered) * 1.0,
          direction: :lower_better
        )
    end
  end

  # Only pass surface-scan opts the goal actually declared, so the scanner's own
  # defaults apply otherwise.
  defp scan_opts(config) do
    case Map.get(config, :source_dirs) do
      dirs when is_list(dirs) and dirs != [] -> [source_dirs: dirs]
      _ -> []
    end
  end

  # Resolve the `:features` glob(s) against the workspace into absolute, existing
  # file paths, de-duplicated and sorted for a deterministic evidence list. Absent
  # `:features`, the product-convention default is used; a glob that matches
  # nothing yields `[]` (zero Scenarios → the whole surface is uncovered).
  defp feature_files(workspace, config) do
    config
    |> Map.get(:features, @default_features)
    |> List.wrap()
    |> Enum.flat_map(fn glob ->
      workspace |> Path.join(glob) |> Path.wildcard(match_dot: false)
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
