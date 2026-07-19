defmodule Kazi.AdoptDiscoverTest do
  # T41.4 (UC-053, ADR-0054): the end-to-end proof for `kazi init --discover`.
  # Unlike Kazi.AdoptE2ETest (the default adopt path), this pins the OPT-IN
  # discovery path: with `--discover`, `kazi init` writes a starter goal-file
  # whose SOLE predicate is the manifest-coverage check (`spec_coverage`, T41.3),
  # scoped to the target repo. It only AUTHORS the goal — no harness is dispatched.
  #
  # The load-bearing assertion is the honest RED starting state: on a repo with a
  # stack marker + public surface but NO `.feature` files, the written predicate
  # loads AND evaluates to `:fail`, its evidence NAMING the undocumented surface —
  # exactly the state a discovery run drives down.
  #
  # Hermetic: builds a throwaway fixture repo in the test's tmp_dir (mix.exs
  # marker + one public function, no specs), writes only into tmp_dir, no network,
  # no harness (discovery authors deterministically; enrichment is off).
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.PredicateResult
  alias Kazi.Providers.SpecCoverage

  @moduletag :tmp_dir

  # A minimal Elixir repo: a mix.exs stack marker (init refuses a repo with no
  # marker), one exported function as public surface, and NO `.feature` files.
  defp fixture_repo(tmp_dir) do
    repo = Path.join(tmp_dir, "undocumented-app")
    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: [app: :demo, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repo, "lib/demo.ex"), """
    defmodule Demo do
      @doc "the sole public surface element"
      def hello(name), do: "hi \#{name}"
    end
    """)

    repo
  end

  # Count REAL (non-commented) `[[predicate]]` blocks — the writer appends a
  # COMMENTED live-predicate scaffold that must not be counted as a predicate.
  defp real_predicate_blocks(toml) do
    toml
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) == "[[predicate]]"))
  end

  test "writes a goal whose SOLE predicate is spec_coverage, RED on an undocumented repo",
       %{tmp_dir: tmp_dir} do
    repo = fixture_repo(tmp_dir)
    out = Path.join(tmp_dir, "discover.goal.toml")

    {code, output} =
      ExUnit.CaptureIO.with_io(fn ->
        Kazi.CLI.run(["init", repo, "--discover", "--out", out])
      end)

    assert code == 0
    assert output =~ "WROTE  #{out}"

    # (acceptance 1) exactly one real predicate block, provider = spec_coverage.
    toml = File.read!(out)
    assert real_predicate_blocks(toml) == 1
    assert toml =~ ~s(provider = "spec_coverage")

    # (b + c) the generated goal loads via the validated Loader, carrying exactly
    # one predicate whose kind is :spec_coverage and no guards.
    assert {:ok, goal} = Loader.load(out)
    assert goal.guards == []
    assert [predicate] = goal.predicates
    assert predicate.kind == :spec_coverage

    # (d) evaluated against the fixture as workspace, it FAILS — the honest RED
    # start — and its evidence NAMES the undocumented surface element.
    result = SpecCoverage.evaluate(predicate, %{workspace: repo})
    assert %PredicateResult{status: :fail} = result

    assert Enum.any?(result.evidence.uncovered, &(&1 =~ "Demo.hello")),
           "expected the uncovered evidence to NAME Demo.hello, got: " <>
             inspect(result.evidence.uncovered)
  end

  test "absent --discover, the default adopt goal carries no spec_coverage predicate",
       %{tmp_dir: tmp_dir} do
    repo = fixture_repo(tmp_dir)
    out = Path.join(tmp_dir, "default.goal.toml")

    {0, _output} =
      ExUnit.CaptureIO.with_io(fn ->
        Kazi.CLI.run(["init", repo, "--out", out])
      end)

    assert {:ok, goal} = Loader.load(out)
    all = goal.predicates ++ goal.guards

    refute Enum.any?(all, &(&1.kind == :spec_coverage)),
           "the default (no --discover) goal must not contain a spec_coverage predicate"
  end
end
