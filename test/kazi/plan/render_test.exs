defmodule Kazi.Plan.RenderTest do
  @moduledoc """
  T72.3 (ADR-0086 decision 3) acceptance: `Kazi.Plan.Render.node/3` renders the
  per-scope-root node from a fixture goal at two observe states, is
  byte-stable for identical inputs regardless of map insertion order, and
  carries no compile-time dependency on the read-model.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.Goal.Roadmap.Render, as: RoadmapRender
  alias Kazi.Plan.Render
  alias Kazi.PredicateResult
  alias Kazi.PredicateVector

  @fixture "test/fixtures/plan_render/checkout_flow.goal.toml"
  @golden_a "test/fixtures/plan_render/checkout_flow.state_a.golden"
  @golden_b "test/fixtures/plan_render/checkout_flow.state_b.golden"
  @root "lib/checkout"

  setup do
    {:ok, goal} = Loader.load(@fixture)
    %{goal: goal}
  end

  # State A: only `unit_tests` failing. `gold_regression` is ALSO failing here
  # (deliberately) so the golden file proves it is excluded because it is
  # `held_out?`, not merely because it happens to be green.
  defp state_a do
    PredicateVector.new(%{
      "unit_tests" => PredicateResult.fail(%{output: "1 test, 1 failure", exit: 1}),
      "checkout_probe" => PredicateResult.pass(%{http_status: 200}),
      "coverage_floor" => PredicateResult.pass(%{score: 92.5}),
      "gold_regression" => PredicateResult.fail(%{output: "regression detected"})
    })
  end

  # State B: `checkout_probe` regresses to failing too, with different
  # evidence — exercises a second failing predicate and a distinct evidence
  # shape (http_status/body vs exit/output).
  defp state_b do
    PredicateVector.new(%{
      "unit_tests" => PredicateResult.fail(%{output: "1 test, 1 failure", exit: 1}),
      "checkout_probe" =>
        PredicateResult.fail(%{http_status: 500, body: "Internal Server Error"}),
      "coverage_floor" => PredicateResult.pass(%{score: 92.5}),
      "gold_regression" => PredicateResult.fail(%{output: "regression detected"})
    })
  end

  describe "golden-file rendering (ADR-0086 decision 3)" do
    test "state A (one predicate failing) matches the golden file", %{goal: goal} do
      assert Render.node(goal, @root, state_a()) == File.read!(@golden_a)
    end

    test "state B (two predicates failing, different evidence) matches the golden file", %{
      goal: goal
    } do
      assert Render.node(goal, @root, state_b()) == File.read!(@golden_b)
    end

    test "the held-out predicate never appears in the node, in either state", %{goal: goal} do
      refute Render.node(goal, @root, state_a()) =~ "gold_regression"
      refute Render.node(goal, @root, state_b()) =~ "gold_regression"
    end

    test "opens with the exact ADR-0082 banner, reused verbatim from the roadmap renderer", %{
      goal: goal
    } do
      rendered = Render.node(goal, @root, state_a())
      assert String.starts_with?(rendered, RoadmapRender.banner())
      assert rendered =~ RoadmapRender.banner_headline()
    end

    test "carries the goal id, brief, and scope root", %{goal: goal} do
      rendered = Render.node(goal, @root, state_a())
      assert rendered =~ "checkout-flow"
      assert rendered =~ "Guest checkout completes without a 500"
      assert rendered =~ "`lib/checkout`"
    end

    test "predicate definitions list every visible predicate with its provider", %{goal: goal} do
      rendered = Render.node(goal, @root, state_a())
      assert rendered =~ "`unit_tests`"
      assert rendered =~ "`checkout_probe`"
      assert rendered =~ "`coverage_floor` (guard)"
      assert rendered =~ "provider `custom_script`"
      assert rendered =~ "provider `http_probe`"
    end
  end

  describe "byte-stability (ADR-0086 decision 3, T72.3 acceptance)" do
    test "20 calls with identical inputs produce byte-identical output", %{goal: goal} do
      vector = state_b()
      renders = for _ <- 1..20, do: Render.node(goal, @root, vector)
      assert renders |> Enum.uniq() |> length() == 1
    end

    test "a PredicateVector/evidence map built with shuffled key order renders identically", %{
      goal: goal
    } do
      ordered =
        PredicateVector.new(%{
          "unit_tests" => PredicateResult.fail(%{output: "boom", exit: 1, host: "a"}),
          "checkout_probe" => PredicateResult.fail(%{http_status: 500, body: "err", url: "x"}),
          "coverage_floor" => PredicateResult.pass(%{}),
          "gold_regression" => PredicateResult.fail(%{})
        })

      shuffled =
        PredicateVector.new(%{
          "gold_regression" => PredicateResult.fail(%{}),
          "coverage_floor" => PredicateResult.pass(%{}),
          "checkout_probe" => PredicateResult.fail(%{url: "x", body: "err", http_status: 500}),
          "unit_tests" => PredicateResult.fail(%{host: "a", exit: 1, output: "boom"})
        })

      assert Render.node(goal, @root, ordered) == Render.node(goal, @root, shuffled)
    end
  end

  describe "purity (ADR-0086 decision 3): no compile-time read-model dependency" do
    # Same technique `test/kazi/scenario/pin_test.exs` uses to pin
    # `Kazi.Scenario.Pin`'s I/O-freedom: inspect the COMPILED module's
    # `:imports` chunk rather than trust convention, so a future edit that
    # reaches for the read-model fails this test on compiled reality.
    test "the compiled module imports nothing from the read-model registry or its repo" do
      {_mod, binary, _filename} = :code.get_object_code(Render)
      {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])

      offenders =
        Enum.filter(imports, fn {mod, _fun, _arity} ->
          mod in [Kazi.ReadModel.RunRegistry, Kazi.Repo, Ecto.Repo, Kazi.RunRegistry]
        end)

      assert offenders == [],
             "Kazi.Plan.Render must have zero compile-time dependency on the read-model " <>
               "(ADR-0086 decision 3), found: #{inspect(offenders)}"
    end

    # NOTE: unlike `Kazi.Scenario.Pin` (whose source never even mentions
    # File/IO in prose), this module's moduledoc DELIBERATELY names
    # `Kazi.ReadModel.RunRegistry`/`Kazi.Repo` to explain why it avoids them —
    # so a naive source-text grep for those names would false-positive on the
    # documentation itself. The `:imports`-chunk check above is the real,
    # acceptance-critical assertion (it inspects compiled call sites, not
    # prose) and is unaffected by what the moduledoc says.
    test "a real Kazi.RunRegistry/Kazi.Repo call in the module would fail the imports check" do
      [{_module, bytecode}] =
        Code.compile_string("""
        defmodule Kazi.Plan.RenderTest.TamperedRenderProbe do
          @moduledoc false
          def touches_read_model, do: Kazi.ReadModel.RunRegistry.list()
        end
        """)

      {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(bytecode, [:imports])

      assert Enum.any?(imports, fn {mod, _fun, _arity} -> mod == Kazi.ReadModel.RunRegistry end),
             "sanity check: the imports-chunk mechanism must actually detect a real call, " <>
               "found: #{inspect(imports)}"
    end
  end
end
