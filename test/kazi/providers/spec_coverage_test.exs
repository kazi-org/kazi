defmodule Kazi.Providers.SpecCoverageTest do
  @moduledoc """
  The `:spec_coverage` provider — the goal-file-runnable form of the
  manifest-coverage meta-predicate (T41.3, ADR-0050/ADR-0054). Tier 2, hermetic:
  a real temp workspace with `.ex` source (so the scanner finds real surface) and
  `.feature` specs, so the provider runs its real scan → check → contract-map path.

  The pure check itself is pinned in `Kazi.Reconcile.SpecCoverageTest`; this pins
  the PROVIDER: it locates the features, scans the surface, and maps the verdict —
  including the state `kazi init --discover` (T41.4) starts from, a repo with no
  `.feature` files where the whole surface is uncovered.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.SpecCoverage

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_spec_cov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "docs/specs"))
    on_exit(fn -> File.rm_rf!(dir) end)

    # One exported function: `Calc.add/2` is the surface element under test.
    File.write!(Path.join(dir, "lib/calc.ex"), """
    defmodule Calc do
      def add(a, b), do: a + b
    end
    """)

    {:ok, workspace: dir}
  end

  defp feature(ws, name, text), do: File.write!(Path.join([ws, "docs/specs", name]), text)

  defp evaluate(ws, config \\ %{}) do
    SpecCoverage.evaluate(Predicate.new(:cov, :spec_coverage, config: config), %{workspace: ws})
  end

  test "a surface element referenced by a Scenario passes", %{workspace: ws} do
    feature(ws, "calc.feature", """
    Feature: Arithmetic
      Scenario: A caller adds two numbers via Calc.add
        Given two numbers
        Then Calc.add returns their sum
    """)

    result = evaluate(ws)

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.uncovered == []
    assert result.evidence.covered_count >= 1
    assert Enum.any?(result.evidence.feature_files, &(&1 =~ "calc.feature"))
  end

  test "an undocumented surface element fails and is NAMED", %{workspace: ws} do
    # A Scenario that references nothing on the surface — Calc.add stays uncovered.
    feature(ws, "unrelated.feature", """
    Feature: Something else
      Scenario: A user does an unrelated thing
        Given a page
        Then something happens
    """)

    result = evaluate(ws)

    assert %PredicateResult{status: :fail} = result
    assert Enum.any?(result.evidence.uncovered, &(&1 =~ "Calc.add"))
    # The evidence names the element, not just a count.
    assert result.evidence.message =~ "Calc.add"
    # score is the uncovered count, lower_better (the loop reads it as progress).
    assert result.score >= 1.0
    assert result.direction == :lower_better
  end

  test "a repo with NO matching .feature files fails with the whole surface uncovered",
       %{workspace: ws} do
    # This is exactly the state `kazi init --discover` (T41.4) writes a goal to drive
    # down: no specs yet, so every element is undocumented.
    result = evaluate(ws)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.feature_files == []
    assert Enum.any?(result.evidence.uncovered, &(&1 =~ "Calc.add"))
  end

  test "an allow-listed element is not counted as uncovered", %{workspace: ws} do
    # No feature covers Calc.add, but the allow-list exempts it as intentional
    # internal surface — so the check passes. `Calc.add*` is a prefix wildcard
    # (allow-list the function regardless of arity); a bare `Calc.add` would be an
    # EXACT-match pattern and miss the `Calc.add/2` identifier.
    result = evaluate(ws, %{allow_list: ["Calc.add*"]})

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.allowed_count >= 1
    assert result.evidence.uncovered == []
  end

  test "the :features glob selects which specs count", %{workspace: ws} do
    # A covering feature exists, but under a path the glob excludes → still uncovered.
    File.mkdir_p!(Path.join(ws, "other"))

    File.write!(Path.join(ws, "other/calc.feature"), """
    Feature: Arithmetic
      Scenario: adds via Calc.add
        Then Calc.add works
    """)

    # Default glob (docs/specs/**) does not see other/ → fail.
    assert %PredicateResult{status: :fail} = evaluate(ws)

    # Point the glob at other/ → the covering feature now counts → pass.
    assert %PredicateResult{status: :pass} = evaluate(ws, %{features: "other/**/*.feature"})
  end

  test "a non-existent workspace is an :error, never a false :pass" do
    result =
      SpecCoverage.evaluate(
        Predicate.new(:cov, :spec_coverage, config: %{}),
        %{workspace: "/kazi/nonexistent/#{System.unique_integer([:positive])}"}
      )

    assert %PredicateResult{status: :error} = result
  end

  test "an unsupported kind is an :error" do
    result = SpecCoverage.evaluate(Predicate.new(:x, :custom_script, config: %{}), %{})
    assert %PredicateResult{status: :error} = result
  end
end
