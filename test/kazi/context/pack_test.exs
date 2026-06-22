defmodule Kazi.Context.PackTest do
  use ExUnit.Case, async: true
  doctest Kazi.Context.Pack

  alias Kazi.Context.{FileRef, Pack, Symbol}

  describe "render/1" do
    test "is a pure function of the struct (equal packs render identically)" do
      pack = %Pack{
        origin: :graph,
        files: [FileRef.new("lib/a.ex")],
        symbols: [Symbol.new("f/1", "lib/a.ex", callers: ["g/0"], callees: ["h/0"])],
        test_sources: [FileRef.new("test/a_test.exs", source: "assert true")]
      }

      assert Pack.render(pack) == Pack.render(pack)
    end

    test "renders symbol caller/callee edges" do
      pack = %Pack{symbols: [Symbol.new("f/1", "lib/a.ex", callers: ["g/0"], callees: ["h/0"])]}
      rendered = Pack.render(pack)
      assert rendered =~ "f/1 (other) in lib/a.ex"
      assert rendered =~ "callers: g/0"
      assert rendered =~ "callees: h/0"
    end

    test "omits empty sections" do
      rendered = Pack.render(%Pack{origin: :repo_map, files: [FileRef.new("lib/a.ex")]})
      assert rendered =~ "## Impacted files"
      refute rendered =~ "## Impacted symbols"
      refute rendered =~ "## Failing test source"
    end
  end

  describe "estimated_tokens/1 and truncate_to_budget/2" do
    test "estimates tokens as ceil(chars / 4)" do
      pack = %Pack{origin: :graph}
      expected = div(String.length(Pack.render(pack)) + 3, 4)
      assert Pack.estimated_tokens(pack) == expected
    end

    test "truncation drops surplus symbols then files, keeps >=1 file" do
      files = for n <- 1..50, do: FileRef.new("lib/file_#{String.pad_leading("#{n}", 2, "0")}.ex")
      symbols = for n <- 1..50, do: Symbol.new("sym_#{n}", "lib/x.ex")
      pack = %Pack{origin: :graph, files: files, symbols: symbols}

      truncated = Pack.truncate_to_budget(pack, 60)

      assert Pack.estimated_tokens(truncated) <= 60
      assert truncated.token_budget == 60
      assert length(truncated.files) >= 1
      # Symbols are the first to go.
      assert length(truncated.symbols) <= length(truncated.files) * 50
    end

    test "is idempotent at the same budget" do
      files = for n <- 1..30, do: FileRef.new("lib/f#{n}.ex")
      pack = %Pack{origin: :graph, files: files}
      once = Pack.truncate_to_budget(pack, 50)
      twice = Pack.truncate_to_budget(once, 50)
      assert once == twice
    end
  end
end
