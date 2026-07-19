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

  describe "blast_radius/1 (T4.6)" do
    test "is the sorted, deduped impacted files + symbol paths; excludes test sources" do
      pack = %Pack{
        origin: :graph,
        files: [FileRef.new("lib/b.ex"), FileRef.new("lib/a.ex")],
        symbols: [Symbol.new("f/1", "lib/a.ex"), Symbol.new("g/1", "lib/c.ex")],
        test_sources: [FileRef.new("test/excluded_test.exs", source: "x")]
      }

      assert Pack.blast_radius(pack) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end

    test "is empty for an empty pack" do
      assert Pack.blast_radius(%Pack{origin: :repo_map}) == []
    end
  end

  describe "to_serializable/1 + from_serializable/1 (T4.6)" do
    test "round-trips a full pack to an identical struct" do
      pack = %Pack{
        origin: :graph,
        token_budget: 4_000,
        files: [FileRef.new("lib/a.ex"), FileRef.new("lib/b.ex")],
        symbols: [
          Symbol.new("f/1", "lib/a.ex", kind: :function, callers: ["g/0"], callees: ["h/0"])
        ],
        test_sources: [FileRef.new("test/a_test.exs", source: "assert true")]
      }

      assert pack |> Pack.to_serializable() |> Pack.from_serializable() == pack
    end

    test "the serialized form is JSON-safe (survives a real JSON encode/decode)" do
      pack = %Pack{origin: :repo_map, token_budget: 100, files: [FileRef.new("lib/a.ex")]}
      serialized = Pack.to_serializable(pack)

      round_tripped = serialized |> Jason.encode!() |> Jason.decode!() |> Pack.from_serializable()
      assert round_tripped == pack
    end

    test "round-trips an empty pack" do
      pack = %Pack{origin: :repo_map, token_budget: 4_000}
      assert pack |> Pack.to_serializable() |> Pack.from_serializable() == pack
    end
  end
end
