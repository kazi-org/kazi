defmodule Kazi.Context.SymbolTest do
  use ExUnit.Case, async: true
  doctest Kazi.Context.Symbol

  alias Kazi.Context.Symbol

  test "new/3 sorts callers and callees for determinism" do
    s = Symbol.new("f/1", "lib/a.ex", callers: ["z/0", "a/0"], callees: ["n/0", "b/0"])
    assert s.callers == ["a/0", "z/0"]
    assert s.callees == ["b/0", "n/0"]
  end

  test "defaults kind to :other and edges to empty" do
    s = Symbol.new("f/1", "lib/a.ex")
    assert s.kind == :other
    assert s.callers == []
    assert s.callees == []
  end
end
