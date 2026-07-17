defmodule Kazi.Reconcile.SpecCoverage do
  @moduledoc """
  The **manifest-coverage meta-predicate** (T41.3, ADR-0050/ADR-0054): the
  behavior-spec half of surface coverage.

  Where `Kazi.Reconcile.Coverage` (T13.5) asks "is every scanned surface element
  owned by >=1 intended **predicate**?" (the dead-code invariant), this asks the
  documentation invariant:

  > **every scanned surface element is REFERENCED by >=1 Scenario** across the
  > product's `.feature` behavior specs.

  A surface element (`Kazi.Reconcile.SurfaceElement` from
  `Kazi.Reconcile.SurfaceScanner`) that no Scenario names is **uncovered** —
  undocumented surface. The meta-predicate FAILS and *names* every uncovered
  element; it never edits anything. Writing the missing Scenario (or allow-listing
  intentional internal surface) is reconciliation work surfaced like any other
  failing predicate.

  ADR-0054 is the reason there is no bespoke `usecase-manifest.json`: the tagged
  `.feature` files under `docs/specs/` (ADR-0050) ARE the use-case catalog, so
  "manifest coverage" is coverage against those Scenarios.

  ## How a Scenario "references" an element

  This reuses the SAME matching primitive as T13.5 —
  `Kazi.Reconcile.SurfaceMatch.covered?/2` — differing only in where the tokens
  come from. The tokens here are the **reference-like** words of each Scenario's
  name and step lines: a word that looks like a route/path or a symbol/task name,
  i.e. one containing `/` or `.` (`/healthz`, `Calc.add/2`, `surface.greet`).
  Plain English words are dropped so they cannot spuriously cover a short
  identifier; surrounding backticks/quotes and trailing punctuation are stripped
  first so a Scenario may write `` `GET /healthz` `` or "calls `/healthz`.". A
  token then covers an element when it equals the element's `identifier` or either
  contains the other (e.g. token `/healthz` covers the `:http_route` `GET
  /healthz`; token `Calc.add` covers `Surface.Calc.add/2`).

  The match is deliberately approximate — the surface scan itself is (`docs/lore.md`
  L-0006). A false *positive* (undocumented element read as covered) is the more
  harmful direction here, so keeping tokens reference-like (not every word) is what
  keeps it honest; the residual approximation is documented, not hidden.

  ## Allow-list

  Intentional un-documented surface (internal/debug entry points) is declared via
  `:allow_list` — the SAME plain-string / `prefix*` wildcard patterns as
  `Kazi.Reconcile.Coverage` — and reported separately as `allowed`.

  ## Result shape

  `check/3` returns a `Kazi.Reconcile.SpecCoverage.Result`:

    * `status` — `:pass` when nothing is uncovered, else `:fail`. An empty surface
      passes vacuously; an empty Scenario set yields every non-allow-listed element
      as `uncovered`.
    * `uncovered` — the named undocumented elements (empty on `:pass`).
    * `covered` — elements referenced by >=1 Scenario.
    * `allowed` — elements covered by the allow-list.

  Every input element lands in exactly one of `uncovered` / `covered` / `allowed`.
  The check is INDEPENDENT of `Kazi.Reconcile.Coverage`: both derive their own
  tokens and call the shared `SurfaceMatch`, so both can run over the same repo
  without interfering.
  """

  alias Kazi.Reconcile.{GherkinImporter, SurfaceElement, SurfaceMatch}

  defmodule Result do
    @moduledoc """
    The outcome of a manifest-coverage check (`Kazi.Reconcile.SpecCoverage.check/3`).

    `status` is `:pass` iff `uncovered` is empty. `covered`, `allowed`, and
    `uncovered` partition the de-duplicated input surface, each sorted by
    `Kazi.Reconcile.SurfaceElement.sort_key/1` for a deterministic report.
    """

    @type t :: %__MODULE__{
            status: :pass | :fail,
            covered: [SurfaceElement.t()],
            allowed: [SurfaceElement.t()],
            uncovered: [SurfaceElement.t()]
          }

    @enforce_keys [:status]
    defstruct status: :pass, covered: [], allowed: [], uncovered: []

    @doc "The identifiers of the uncovered (undocumented) elements, sorted."
    @spec uncovered_identifiers(t()) :: [String.t()]
    def uncovered_identifiers(%__MODULE__{uncovered: uncovered}) do
      Enum.map(uncovered, & &1.identifier)
    end

    @doc """
    A human-readable failure message naming each uncovered surface element, or
    `nil` on `:pass`. This is what a caller surfaces so the report *names the
    missing surface* rather than merely counting it.
    """
    @spec failure_message(t()) :: String.t() | nil
    def failure_message(%__MODULE__{status: :pass}), do: nil

    def failure_message(%__MODULE__{status: :fail, uncovered: uncovered}) do
      names = uncovered |> Enum.map(& &1.identifier) |> Enum.join(", ")

      "#{length(uncovered)} surface element(s) referenced by no Scenario: #{names}"
    end
  end

  @doc """
  Checks that every surface element is referenced by >=1 Scenario or covered by
  the allow-list.

    * `surface` — the scanned inventory (`[SurfaceElement.t()]`).
    * `scenarios` — the parsed Scenarios (`[GherkinImporter.scenario()]`), e.g.
      from `Kazi.Reconcile.GherkinImporter.scenarios/1` over the product's
      `.feature` files.
    * `opts`:
      * `:allow_list` — patterns for intentional un-documented surface. Defaults
        to `[]`.

  Returns a `SpecCoverage.Result`. Pure and total: an empty surface, an empty
  Scenario set, or malformed scenario maps are all handled without raising.

  ## Examples

      iex> alias Kazi.Reconcile.SurfaceElement
      iex> el = SurfaceElement.new(:http_route, "GET /healthz", "lib/web.ex", 3)
      iex> sc = %{feature: "Health", scenario: "The client polls GET /healthz", steps: [], tags: []}
      iex> Kazi.Reconcile.SpecCoverage.check([el], [sc]).status
      :pass

      iex> alias Kazi.Reconcile.SurfaceElement
      iex> el = SurfaceElement.new(:http_route, "GET /secret", "lib/web.ex", 9)
      iex> r = Kazi.Reconcile.SpecCoverage.check([el], [])
      iex> {r.status, Enum.map(r.uncovered, & &1.identifier)}
      {:fail, ["GET /secret"]}
  """
  @spec check([SurfaceElement.t()], [GherkinImporter.scenario()], keyword()) :: Result.t()
  def check(surface, scenarios, opts \\ [])
      when is_list(surface) and is_list(scenarios) and is_list(opts) do
    allow_patterns = Keyword.get(opts, :allow_list, [])

    tokens =
      scenarios |> Enum.flat_map(&scenario_tokens/1) |> SurfaceMatch.trim_tokens()

    {allowed, rest} =
      surface
      |> Enum.uniq()
      |> Enum.split_with(&SurfaceMatch.allowed?(&1, allow_patterns))

    {covered, uncovered} = Enum.split_with(rest, &SurfaceMatch.covered?(&1, tokens))

    %Result{
      status: if(uncovered == [], do: :pass, else: :fail),
      covered: SurfaceMatch.sort(covered),
      allowed: SurfaceMatch.sort(allowed),
      uncovered: SurfaceMatch.sort(uncovered)
    }
  end

  @doc """
  Convenience over `check/3`: parses the given `.feature` text(s) into Scenarios
  via `Kazi.Reconcile.GherkinImporter.scenarios/1`, then checks `surface` against
  them.
  """
  @spec check_features([SurfaceElement.t()], String.t() | [String.t()], keyword()) :: Result.t()
  def check_features(surface, feature_texts, opts \\ []) do
    check(surface, GherkinImporter.scenarios(feature_texts), opts)
  end

  # The reference-like tokens a Scenario contributes: the words of its name and
  # steps that look like a surface reference (contain `/` or `.`).
  defp scenario_tokens(scenario) do
    scenario
    |> reference_lines()
    |> Enum.flat_map(&reference_tokens/1)
  end

  defp reference_lines(%{scenario: name, steps: steps}) when is_binary(name) and is_list(steps),
    do: [name | steps]

  defp reference_lines(%{steps: steps}) when is_list(steps), do: steps
  defp reference_lines(%{scenario: name}) when is_binary(name), do: [name]
  defp reference_lines(_), do: []

  defp reference_tokens(line) when is_binary(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&clean/1)
    |> Enum.filter(&reference_like?/1)
  end

  defp reference_tokens(_), do: []

  # Strip leading/trailing non-identifier punctuation (backticks, quotes,
  # brackets, sentence punctuation) so a Scenario may write `` `GET /healthz` ``
  # or "…calls `Surface.Calc.add`.". Interior `.`/`/` (module dots, route slashes,
  # arities) are preserved; a trailing arity digit is an identifier char and kept.
  defp clean(word) do
    word
    |> String.replace(~r{^[^A-Za-z0-9_/]+}, "")
    |> String.replace(~r{[^A-Za-z0-9_/]+$}, "")
  end

  defp reference_like?(token) do
    token != "" and (String.contains?(token, "/") or String.contains?(token, "."))
  end
end
