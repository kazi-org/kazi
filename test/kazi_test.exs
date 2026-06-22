defmodule KaziTest do
  use ExUnit.Case
  doctest Kazi

  test "greets the world" do
    assert Kazi.hello() == :world
  end
end
