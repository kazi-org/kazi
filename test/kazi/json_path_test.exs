defmodule Kazi.JSONPathTest do
  @moduledoc """
  The shared `$`/`.key`/`[index]` subset + numeric coercion the `:custom_script`
  verdict and the `:ratchet` metric both extract through (T32.3, ADR-0040/0041).
  """
  use ExUnit.Case, async: true

  doctest Kazi.JSONPath

  describe "get/2" do
    test "walks object keys and array indices" do
      data = %{"runs" => [%{"results" => [%{}, %{}]}]}
      assert {:ok, [%{}, %{}]} = Kazi.JSONPath.get(data, "$.runs[0].results")
    end

    test "a missing key is a tagged error, never a silent nil" do
      assert {:error, {:path_missing, "totals", "$.totals.percent"}} =
               Kazi.JSONPath.get(%{"other" => 1}, "$.totals.percent")
    end

    test "an out-of-range index is a tagged error" do
      assert {:error, {:path_index_out_of_range, 3, _}} =
               Kazi.JSONPath.get(%{"xs" => [1, 2]}, "$.xs[3]")
    end

    test "a type mismatch (indexing a map) is a tagged error" do
      assert {:error, {:path_type_mismatch, {:index, 0}, _}} =
               Kazi.JSONPath.get(%{"xs" => %{"a" => 1}}, "$.xs[0]")
    end

    test "a path not starting with $ is invalid" do
      assert {:error, {:invalid_path, "totals.percent"}} =
               Kazi.JSONPath.get(%{}, "totals.percent")
    end
  end

  describe "to_number/1" do
    test "a number is verbatim" do
      assert {:ok, 81.5} = Kazi.JSONPath.to_number(81.5)
      assert {:ok, 7} = Kazi.JSONPath.to_number(7)
    end

    test "a list yields its length (a findings array compares its COUNT)" do
      assert {:ok, 3} = Kazi.JSONPath.to_number([%{}, %{}, %{}])
    end

    test "anything else is not a number" do
      assert {:error, {:not_a_number, "x"}} = Kazi.JSONPath.to_number("x")
    end
  end
end
