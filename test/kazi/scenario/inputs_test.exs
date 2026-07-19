defmodule Kazi.Scenario.InputsTest do
  use ExUnit.Case, async: true

  alias Kazi.Scenario.Inputs

  # A deterministic rand fun for the substitution assertions: all-zero bytes, so
  # hex is "00..." and every random_string char is the alphabet's first ("a").
  defp zeros, do: fn n -> :binary.copy(<<0>>, n) end

  describe "substitute/3 — placeholder coverage" do
    test "substitutes {{name}} across BOTH steps and assertions, recording the value" do
      trace = %{
        "url" => "/settings/tokens",
        "steps" => [%{"action" => "type", "selector" => "#name", "text" => "{{pat_name}}"}],
        "assertions" => [
          %{"type" => "text", "selector" => "#token-name", "equals" => "{{pat_name}}"}
        ]
      }

      {substituted, generated} = Inputs.substitute(trace, %{"pat_name" => "unique_slug"}, zeros())

      value = generated["pat_name"]
      assert value == "pat_name-00000000"

      # The same fresh value lands in BOTH the step and the assertion.
      assert hd(substituted["steps"])["text"] == value
      assert hd(substituted["assertions"])["equals"] == value

      # No literal placeholder survives anywhere.
      refute inspect(substituted) =~ "{{"
    end

    test "substitutes a placeholder in a deeply nested list position" do
      trace = %{"steps" => [%{"args" => ["create", "{{slug}}", %{"note" => "{{slug}}"}]}]}

      {substituted, generated} = Inputs.substitute(trace, %{"slug" => "unique_slug"}, zeros())

      [%{"args" => [_, one, %{"note" => two}]}] = substituted["steps"]
      assert one == generated["slug"]
      assert two == generated["slug"]
    end

    test "records every distinct placeholder it substitutes" do
      trace = %{"steps" => ["{{a}}"], "assertions" => ["{{b}}"]}

      {_substituted, generated} =
        Inputs.substitute(trace, %{"a" => "unique_slug", "b" => "random_email"}, zeros())

      assert Map.keys(generated) |> Enum.sort() == ["a", "b"]
    end
  end

  describe "substitute/3 — no-op safety" do
    test "a trace with no placeholders is returned unchanged with empty generated" do
      trace = %{
        "url" => "/settings/tokens",
        "steps" => [%{"action" => "click", "selector" => "#new-token"}],
        "assertions" => [%{"type" => "visible", "selector" => "#token-value"}],
        "timeout_ms" => 30_000
      }

      assert {^trace, generated} = Inputs.substitute(trace, %{}, zeros())
      assert generated == %{}
    end
  end

  describe "substitute/3 — freshness (ADR-0064 d2)" do
    test "two runs with the real rand fun generate DIFFERENT slugs" do
      trace = %{"steps" => ["{{pat_name}}"]}
      inputs = %{"pat_name" => "unique_slug"}

      {sub1, gen1} = Inputs.substitute(trace, inputs)
      {sub2, gen2} = Inputs.substitute(trace, inputs)

      assert gen1["pat_name"] != gen2["pat_name"]
      assert sub1 != sub2
      # Both are still well-formed unique_slug values.
      assert gen1["pat_name"] =~ ~r/^pat_name-[0-9a-f]{8}$/
      assert gen2["pat_name"] =~ ~r/^pat_name-[0-9a-f]{8}$/
    end
  end

  describe "substitute/3 — generator kinds" do
    test "unique_slug is the placeholder name + 8 hex" do
      {_t, generated} =
        Inputs.substitute(%{"steps" => ["{{x}}"]}, %{"x" => "unique_slug"}, zeros())

      assert generated["x"] == "x-00000000"
    end

    test "random_email is a reserved-domain address" do
      {_t, generated} =
        Inputs.substitute(%{"steps" => ["{{e}}"]}, %{"e" => "random_email"}, zeros())

      assert generated["e"] == "000000000000@example.com"
    end

    test "random_string:<n> is n lowercase-alphanumeric chars" do
      {_t, generated} =
        Inputs.substitute(%{"steps" => ["{{s}}"]}, %{"s" => "random_string:5"}, zeros())

      assert generated["s"] == "aaaaa"
      assert String.length(generated["s"]) == 5
    end
  end

  describe "substitute/3 — unknown generator" do
    test "an unknown generator kind fails loudly, naming the placeholder" do
      assert {:error, {:unknown_generator, "pat_name"}} =
               Inputs.substitute(
                 %{"steps" => ["{{pat_name}}"]},
                 %{"pat_name" => "bogus"},
                 zeros()
               )
    end

    test "a malformed random_string length is an unknown generator" do
      assert {:error, {:unknown_generator, "s"}} =
               Inputs.substitute(%{"steps" => ["{{s}}"]}, %{"s" => "random_string:0"}, zeros())

      assert {:error, {:unknown_generator, "s"}} =
               Inputs.substitute(%{"steps" => ["{{s}}"]}, %{"s" => "random_string:x"}, zeros())
    end

    test "a placeholder with no inputs entry is an unknown generator (never a silent literal)" do
      assert {:error, {:unknown_generator, "orphan"}} =
               Inputs.substitute(%{"steps" => ["{{orphan}}"]}, %{}, zeros())
    end
  end
end
