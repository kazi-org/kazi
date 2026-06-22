defmodule Kazi.ContextTest do
  use ExUnit.Case, async: true
  doctest Kazi.Context

  alias Kazi.Context
  alias Kazi.Context.{FileRef, StaticGraphSource, Symbol}
  alias Kazi.PredicateResult

  @workspace "/fixture/ws"

  defp failing(evidence_output) do
    [{:unit, PredicateResult.fail(%{output: evidence_output})}]
  end

  describe "orientation_pack/3 — graph-present path (injected source)" do
    test "builds a pack from the injected graph survey, tagging its origin" do
      source =
        StaticGraphSource.new(
          origin: :graph,
          files: ["lib/foo.ex", "lib/bar.ex"],
          symbols: [{"build/1", "lib/foo.ex", [callers: ["caller/0"], callees: ["dep/0"]]}],
          test_sources: [{"test/foo_test.exs", [source: "assert Foo.build(1)"]}]
        )

      pack =
        Context.orientation_pack(failing("boom in lib/foo.ex"), @workspace, graph_source: source)

      assert pack.origin == :graph
      assert Enum.map(pack.files, & &1.path) == ["lib/foo.ex", "lib/bar.ex"]
      assert [%Symbol{name: "build/1", callers: ["caller/0"], callees: ["dep/0"]}] = pack.symbols

      assert [%FileRef{path: "test/foo_test.exs", source: "assert Foo.build(1)"}] =
               pack.test_sources
    end

    test "is hermetic: never touches the filesystem or network for the graph path" do
      # @workspace does not exist; the injected source must satisfy the build with
      # no filesystem access (ADR-0010 hermetic acceptance).
      refute File.exists?(@workspace)
      source = StaticGraphSource.new(origin: :graph, files: ["lib/a.ex"])

      pack = Context.orientation_pack(failing("x"), @workspace, graph_source: source)
      assert Enum.map(pack.files, & &1.path) == ["lib/a.ex"]
    end
  end

  describe "orientation_pack/3 — ranking" do
    test "files named in the failing evidence rank above the rest" do
      source =
        StaticGraphSource.new(
          origin: :graph,
          files: ["lib/zeta.ex", "lib/target.ex", "lib/alpha.ex"]
        )

      pack =
        Context.orientation_pack(failing("error at lib/target.ex:42"), @workspace,
          graph_source: source
        )

      # target (evidence-named) first; remaining files in stable path order.
      assert Enum.map(pack.files, & &1.path) == ["lib/target.ex", "lib/alpha.ex", "lib/zeta.ex"]
    end

    test "symbols named in the evidence rank above the rest" do
      source =
        StaticGraphSource.new(
          origin: :graph,
          symbols: [
            {"unrelated/0", "lib/other.ex"},
            {"render_widget/1", "lib/widget.ex"}
          ]
        )

      pack =
        Context.orientation_pack(failing("undefined function render_widget/1"), @workspace,
          graph_source: source
        )

      assert Enum.map(pack.symbols, & &1.name) == ["render_widget/1", "unrelated/0"]
    end
  end

  describe "orientation_pack/3 — determinism" do
    test "two calls with identical inputs render byte-identically" do
      source =
        StaticGraphSource.new(
          origin: :graph,
          files: ["lib/b.ex", "lib/a.ex", "lib/c.ex"],
          symbols: [{"z/0", "lib/b.ex"}, {"a/0", "lib/a.ex"}]
        )

      f = failing("touch lib/a.ex and z/0")

      p1 = Context.orientation_pack(f, @workspace, graph_source: source)
      p2 = Context.orientation_pack(f, @workspace, graph_source: source)

      assert Context.render(p1) == Context.render(p2)
      assert p1 == p2
    end

    test "render order does not depend on input map/list ordering of evidence" do
      source = StaticGraphSource.new(origin: :graph, files: ["lib/a.ex", "lib/b.ex"])

      f1 = [{:unit, PredicateResult.fail(%{output: "x", extra: "lib/a.ex"})}]
      f2 = [{:unit, PredicateResult.fail(%{extra: "lib/a.ex", output: "x"})}]

      r1 = Context.orientation_pack(f1, @workspace, graph_source: source) |> Context.render()
      r2 = Context.orientation_pack(f2, @workspace, graph_source: source) |> Context.render()

      assert r1 == r2
    end
  end

  describe "orientation_pack/3 — token budget" do
    test "the rendered pack respects the token budget" do
      many_files = for n <- 1..200, do: "lib/module_#{String.pad_leading("#{n}", 3, "0")}.ex"
      source = StaticGraphSource.new(origin: :graph, files: many_files)

      budget = 80

      pack =
        Context.orientation_pack(failing("x"), @workspace,
          graph_source: source,
          token_budget: budget
        )

      assert Context.Pack.estimated_tokens(pack) <= budget
      # It dropped lowest-ranked files but kept at least the top one.
      assert length(pack.files) >= 1
      assert length(pack.files) < length(many_files)
    end

    test "default budget is applied when none given" do
      source = StaticGraphSource.new(origin: :graph, files: ["lib/a.ex"])
      pack = Context.orientation_pack(failing("x"), @workspace, graph_source: source)
      assert pack.token_budget == 4_000
    end
  end

  describe "cache_key/3" do
    test "is stable for equal inputs and independent of failing-set order" do
      f = [{:b, PredicateResult.fail()}, {:a, PredicateResult.fail()}]
      k1 = Context.cache_key(@workspace, "sha123", f)
      k2 = Context.cache_key(@workspace, "sha123", Enum.reverse(f))
      assert k1 == k2
    end

    test "differs by workspace, sha, and failing-set" do
      f = [{:a, PredicateResult.fail()}]
      base = Context.cache_key(@workspace, "sha1", f)

      refute base == Context.cache_key("/other", "sha1", f)
      refute base == Context.cache_key(@workspace, "sha2", f)
      refute base == Context.cache_key(@workspace, "sha1", [{:b, PredicateResult.fail()}])
    end
  end

  describe "render/1" do
    test "an empty pack still renders a stable orientation header" do
      pack = %Context.Pack{origin: :repo_map}
      rendered = Context.render(pack)
      assert rendered =~ "# Orientation (repo_map)"
      refute rendered =~ "## Impacted files"
    end
  end
end
